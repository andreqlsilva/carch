#!/bin/bash
# ==========================================
# AUTOMATED ARCH LINUX DEPLOYMENT SCRIPT (LUKS + BTRFS)
# ==========================================
set -euo pipefail

# 1. Variables — loaded from a secrets file that gets shredded after use.
#    Create secrets.env alongside this script before running:
#
#    DISK="/dev/nvme0n1"
#    HOSTNAME="cartorio-ws01"
#    USER_NAME="usuario-cartorio"
#    USER_PASS="senha_temporaria123"
#    ROOT_PASS="senha_root123"
#    LUKS_PASS="senha_criptografia123"
#    HEADSCALE_URL="https://hs.your-domain.com"
#    HEADSCALE_AUTHKEY="hskey-xxxxxxxxxxxxxxxxxxx"
#    WIFI_SSID="nome-da-rede"        # optional
#    WIFI_PASS="senha-wifi"           # optional
#    DOTFILES_REPO="https://github.com/you/dotfiles.git"  # optional

SCRIPT_DIR="$(dirname "$0")"
SECRETS_FILE="$SCRIPT_DIR/secrets.env"
if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "ERROR: $SECRETS_FILE not found. Create it before running this script." >&2
    exit 1
fi
# shellcheck source=secrets.env
source "$SECRETS_FILE"
shred -u "$SECRETS_FILE"

# Validate that all required variables were provided
for var in DISK HOSTNAME USER_NAME USER_PASS ROOT_PASS LUKS_PASS HEADSCALE_URL HEADSCALE_AUTHKEY; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set in secrets file." >&2
        exit 1
    fi
done

DOTFILES_REPO="${DOTFILES_REPO:-}"

### FUNCTIONS ###

# Non-interactive progress box; falls back to plain printf when no TTY is available.
msg() { whiptail --title "carch" --infobox "$1" 7 70 || printf '\033[1;32m==>\033[0m %s\n' "$1"; }

# Reads progs.csv and prints the name of every blank-tagged (pacstrap) package.
build_pacstrap_pkgs() {
    grep -v '^#\|^[[:space:]]*$' "$SCRIPT_DIR/progs.csv" \
        | awk -F',' '$1 == "" { print $2 }'
}

# Copies progs.csv into the new root so it can be read inside the chroot.
stage_progs() {
    cp "$SCRIPT_DIR/progs.csv" /mnt/tmp/progs.csv
}

# Connects the live environment to WiFi using iwd (iwctl).
# Only called when WIFI_SSID/WIFI_PASS are set and we are not already online.
connect_wifi() {
    local iface i=0
    iface=$(iw dev | awk '$1 == "Interface" { print $2; exit }')
    if [[ -z "$iface" ]]; then
        printf 'ERROR: WIFI_SSID set but no wireless interface found.\n' >&2
        exit 1
    fi
    msg "Connecting live environment to '${WIFI_SSID}' on ${iface}..."
    iwctl --passphrase "$WIFI_PASS" station "$iface" connect "$WIFI_SSID"
    until iw dev "$iface" link | grep -q "Connected to"; do
        sleep 1
        i=$((i + 1))
        if [[ $i -ge 15 ]]; then
            printf 'ERROR: WiFi connection to %s timed out after 15s.\n' "$WIFI_SSID" >&2
            exit 1
        fi
    done
}

# Verifies that the Arch mirror and AUR are reachable before touching the disk.
check_connectivity() {
    msg "Verifying connectivity to Arch and AUR servers..."
    for host in archlinux.org aur.archlinux.org; do
        if ! curl --silent --head --max-time 10 "https://${host}" &>/dev/null; then
            printf 'ERROR: Cannot reach %s — check your network and DNS.\n' "$host" >&2
            exit 1
        fi
    done
}

### THE ACTUAL SCRIPT ###

# 0. Network setup
# Connect to WiFi if credentials are present and we are not already online.
# The connectivity check always runs so the install never starts without network.
if [[ -n "${WIFI_SSID:-}" && -n "${WIFI_PASS:-}" ]]; then
    if ! curl --silent --head --max-time 5 "https://archlinux.org" &>/dev/null; then
        connect_wifi
    fi
fi
check_connectivity

# 2. Partitioning
msg "Partitioning $DISK..."
parted -s "$DISK" mktable gpt \
    mkpart "EFI" fat32 0% 1GiB set 1 esp on \
    mkpart "linux" btrfs 1GiB 100%
mkfs.fat -F 32 "${DISK}p1"

# 3. LUKS Encryption Setup
msg "Setting up LUKS encryption on ${DISK}p2..."
echo -n "$LUKS_PASS" | cryptsetup luksFormat --batch-mode "${DISK}p2" -
echo -n "$LUKS_PASS" | cryptsetup open "${DISK}p2" cryptroot -d -

# 4. Format and Create Subvolumes on the Decrypted Container
msg "Creating Btrfs filesystem and subvolumes..."
mkfs.btrfs -f /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots
umount /mnt

# 5. Mount Order (Root subvolume first, then directories)
BTRFS_OPTS="noatime,compress=zstd,space_cache=v2"
msg "Mounting subvolumes..."
mount -o "${BTRFS_OPTS},subvol=@"          /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot/efi}
mount -o "${BTRFS_OPTS},subvol=@home"      /dev/mapper/cryptroot /mnt/home
mount -o "${BTRFS_OPTS},subvol=@log"       /dev/mapper/cryptroot /mnt/var/log
mount -o "${BTRFS_OPTS},subvol=@pkg"       /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o "${BTRFS_OPTS},subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
mount "${DISK}p1" /mnt/boot/efi

# 6. Base System Installation
msg "Building package list from progs.csv..."
mapfile -t PACSTRAP_PKGS < <(build_pacstrap_pkgs)
msg "Installing ${#PACSTRAP_PKGS[@]} packages via pacstrap (this will take a while)..."
pacstrap -K /mnt "${PACSTRAP_PKGS[@]}"
stage_progs

# 7. Generate Fstab
msg "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Grab the UUID of the raw encrypted partition — this must expand HERE (outer
# shell) so it is baked into the heredoc before arch-chroot runs.
CRYPT_UUID=$(blkid -s UUID -o value "${DISK}p2")

# All remaining variables that the heredoc needs are also expanded here in the
# outer shell. The heredoc delimiter is therefore unquoted (<<EOF), and every
# former \$VAR escape is gone — they are now plain $VAR references that expand
# at heredoc-construction time, before arch-chroot ever sees the script.

# 8. Non-Interactive Chroot Operations
msg "Entering chroot for system configuration..."
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

# Progress helpers — whiptail works here because /dev/tty is bind-mounted by
# arch-chroot; falls back to printf if the terminal is unavailable.
msg()  { whiptail --title "carch" --infobox "\$1" 7 70 || printf '\033[1;32m==>\033[0m %s\n' "\$1"; }
warn() { printf '\033[1;33m==> WARN:\033[0m %s\n' "\$1" >&2; }

# Installs a single AUR package via yay; non-fatal so one failure doesn't abort.
aurinstall() {
    local pkg="\$1" comment="\$2"
    msg "AUR (\$pkg): \$comment"
    sudo -u "$USER_NAME" yay -S --noconfirm "\$pkg" >/dev/null 2>&1 \
        || warn "\$pkg failed — install manually post-deploy"
}

# Reads /tmp/progs.csv and calls aurinstall() for every A-tagged entry.
installationloop() {
    local tag pkg comment
    while IFS=, read -r tag pkg comment; do
        comment=\$(printf '%s' "\$comment" | sed -E 's/(^\"|\"$)//g')
        [[ "\$tag" == "A" ]] && aurinstall "\$pkg" "\$comment"
    done < <(grep -v '^#\|^[[:space:]]*$' /tmp/progs.csv)
}

# Clones \$1 shallow into a temp dir and copies the result into \$2; leaves no
# .git dir behind so the home directory isn't a git repo.
putgitrepo() {
    local repo="\$1" dest="\$2" tmp
    msg "Deploying dotfiles from \$repo..."
    tmp=\$(mktemp -d)
    mkdir -p "\$dest"
    chown "$USER_NAME":wheel "\$tmp" "\$dest"
    sudo -u "$USER_NAME" git clone --depth 1 --single-branch --no-tags \
        -q --recurse-submodules "\$repo" "\$tmp"
    sudo -u "$USER_NAME" cp -rfT "\$tmp" "\$dest"
    rm -rf "\$tmp"
}

# --- Timezone & Locale ---
msg "Configuring locale and timezone..."
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
hwclock --systohc
sed -i 's/^#pt_BR.UTF-8 UTF-8/pt_BR.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=pt_BR.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

cat >> /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.local $HOSTNAME
HOSTS

# --- Users & Passwords ---
msg "Creating user $USER_NAME..."
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd

# Force password change on first login — deployment passwords are temporary.
chage -d 0 "$USER_NAME"
chage -d 0 root

# --- Sudo ---
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- Kernel hardening ---
cat > /etc/sysctl.d/99-hardening.conf <<SYSCTL
kernel.dmesg_restrict=1
kernel.kptr_restrict=2
net.core.bpf_jit_harden=2
kernel.unprivileged_userns_clone=0
fs.protected_hardlinks=1
fs.protected_symlinks=1
SYSCTL

# --- Disable timesyncd to avoid conflict with chrony ---
systemctl disable systemd-timesyncd || true

# --- Initramfs: inject 'encrypt' hook after 'block' ---
msg "Rebuilding initramfs with encrypt hook..."
sed -i 's/\bblock\b/block encrypt/' /etc/mkinitcpio.conf
mkinitcpio -P

# --- GRUB: LUKS + Btrfs snapshot boot support ---
msg "Installing GRUB bootloader..."
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"cryptdevice=UUID=$CRYPT_UUID:cryptroot root=/dev/mapper/cryptroot |" /etc/default/grub
echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Fallback EFI binary for BIOSes that ignore custom bootloader IDs
mkdir -p /boot/efi/EFI/BOOT
cp /boot/efi/EFI/GRUB/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI

# --- KWallet PAM auto-unlock on SDDM login ---
sed -i '/^auth\s\+include\s\+system-login/a auth\t\toptional\t\tpam_kwallet5.so' /etc/pam.d/sddm
sed -i '/^session\s\+include\s\+system-login/a session\t\toptional\t\tpam_kwallet5.so auto_start' /etc/pam.d/sddm

# --- SDDM Wayland configuration ---
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/10-wayland.conf <<SDDMCONF
[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
SDDMCONF

# --- Snapper: create root config BEFORE enabling timers ---
# Without this, snapper-timeline.timer fails silently on first boot.
msg "Configuring Snapper..."
umount /.snapshots
rm -rf /.snapshots
snapper -c root create-config /
# snapper re-creates /.snapshots as its own directory; re-mount our subvolume
# over it so snapshots land on @snapshots, not on @.
mount -o $BTRFS_OPTS,subvol=@snapshots /dev/mapper/cryptroot /.snapshots

# --- grub-btrfs: watch for new snapshots and rebuild GRUB menu automatically ---
systemctl enable grub-btrfs.path

# --- ICP-Brasil A3 token support ---
mkdir -p /etc/pkcs11/modules
cat > /etc/pkcs11/modules/opensc.module <<P11KIT
module: /usr/lib/opensc-pkcs11.so
critical: no
P11KIT

# --- Headscale join script ---
# tailscaled starts on first boot but does not auto-join; an authkey is
# required. We bake the credentials into a root-only helper so the admin
# just runs it once after the first login:
#   sudo /usr/local/sbin/tailscale-join.sh
cat > /usr/local/sbin/tailscale-join.sh <<TSJOIN
#!/bin/bash
tailscale up \
    --login-server="$HEADSCALE_URL" \
    --authkey="$HEADSCALE_AUTHKEY" \
    --hostname="$HOSTNAME" \
    --accept-dns=true \
    --accept-routes=true
TSJOIN
chmod 700 /usr/local/sbin/tailscale-join.sh

# --- Enable all system services ---
msg "Enabling system services..."
systemctl enable \
    NetworkManager \
    sshd \
    tailscaled \
    bluetooth \
    firewalld \
    smb nmb \
    avahi-daemon \
    wsdd \
    cups \
    chronyd \
    pcscd \
    power-profiles-daemon \
    auditd \
    fstrim.timer \
    snapper-timeline.timer \
    snapper-cleanup.timer \
    clamav-freshclam.timer \
    sddm

# --- Initial ClamAV DB fetch so the service doesn't error on first boot ---
freshclam || true

# --- Initial locate DB ---
updatedb || true

# --- yay (AUR helper) ---
# makepkg refuses to run as root, so everything here runs as the regular user.
# We temporarily grant passwordless sudo for the build, then lock it back down.
msg "Bootstrapping AUR helper (yay)..."

# Use all CPU cores for AUR compilation.
sed -i "s/-j2/-j\$(nproc)/;/^#MAKEFLAGS/s/^#//" /etc/makepkg.conf

# Trap ensures the temp passwordless-sudo file is removed on any exit, including
# abnormal ones, so it never survives a mid-install crash.
trap 'rm -f /etc/sudoers.d/aur-bootstrap' HUP INT QUIT TERM PWR EXIT
echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/aur-bootstrap

sudo -u "$USER_NAME" bash <<AUREOF
set -euo pipefail
git clone https://aur.archlinux.org/yay.git /tmp/yay
cd /tmp/yay
makepkg -si --noconfirm
rm -rf /tmp/yay
AUREOF

# --- AUR package installation (driven by progs.csv) ---
msg "Installing AUR packages from progs.csv..."
installationloop

# Revoke temporary passwordless sudo (trap also covers abnormal exits).
trap - HUP INT QUIT TERM PWR EXIT
rm -f /etc/sudoers.d/aur-bootstrap

# --- Dotfiles (optional — set DOTFILES_REPO in secrets.env) ---
[[ -n "$DOTFILES_REPO" ]] && putgitrepo "$DOTFILES_REPO" "/home/$USER_NAME"

# --- AIDE file integrity baseline ---
# Must run AFTER all packages and AUR installs are complete so the DB
# reflects the intended final system state. Any subsequent drift from
# this baseline is detectable via 'aide --check'.
msg "Initializing AIDE file integrity baseline..."
aide --init
mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db

EOF

# 9. WiFi pre-configuration (optional)
if [[ -n "${WIFI_SSID:-}" && -n "${WIFI_PASS:-}" ]]; then
    msg "Pre-configuring WiFi network '${WIFI_SSID}'..."
    mkdir -p /mnt/etc/NetworkManager/system-connections
    cat > "/mnt/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection" <<NMEOF
[connection]
id=${WIFI_SSID}
type=wifi

[wifi]
mode=infrastructure
ssid=${WIFI_SSID}

[wifi-security]
auth-alg=open
key-mgmt=wpa-psk
psk=${WIFI_PASS}

[ipv4]
method=auto

[ipv6]
addr-gen-mode=stable-privacy
method=auto
NMEOF
    chmod 600 "/mnt/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection"
fi

# 10. Unmount and reboot
msg "Installation complete — unmounting and rebooting."
umount -R /mnt
cryptsetup close cryptroot
reboot

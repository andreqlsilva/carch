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

SECRETS_FILE="$(dirname "$0")/deploy-secrets.env"
if [[ ! -f "$SECRETS_FILE" ]]; then
    echo "ERROR: $SECRETS_FILE not found. Create it before running this script." >&2
    exit 1
fi
# shellcheck source=deploy-secrets.env
source "$SECRETS_FILE"
shred -u "$SECRETS_FILE"

# Validate that all required variables were provided
for var in DISK HOSTNAME USER_NAME USER_PASS ROOT_PASS LUKS_PASS HEADSCALE_URL HEADSCALE_AUTHKEY; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set in secrets file." >&2
        exit 1
    fi
done

# 2. Partitioning
parted -s "$DISK" mktable gpt \
    mkpart "EFI" fat32 0% 1GiB set 1 esp on \
    mkpart "linux" btrfs 1GiB 100%
mkfs.fat -F 32 "${DISK}p1"

# 3. LUKS Encryption Setup
echo -n "$LUKS_PASS" | cryptsetup luksFormat --batch-mode "${DISK}p2" -
echo -n "$LUKS_PASS" | cryptsetup open "${DISK}p2" cryptroot -d -

# 4. Format and Create Subvolumes on the Decrypted Container
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
mount -o "${BTRFS_OPTS},subvol=@"          /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot/efi}
mount -o "${BTRFS_OPTS},subvol=@home"      /dev/mapper/cryptroot /mnt/home
mount -o "${BTRFS_OPTS},subvol=@log"       /dev/mapper/cryptroot /mnt/var/log
mount -o "${BTRFS_OPTS},subvol=@pkg"       /dev/mapper/cryptroot /mnt/var/cache/pacman/pkg
mount -o "${BTRFS_OPTS},subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
mount "${DISK}p1" /mnt/boot/efi

# 6. Base System Installation
# Notes:
#   - abiword/gnumeric replaced with libreoffice-fresh for .docx/.xlsx interop
#     with court systems and CNJ tooling.
#   - tailscale: installed from official repos; pointed at self-hosted Headscale
#     coordination server instead of Tailscale's control plane (see step 8).
#   - pcsc-lite + ccid + opensc: required for ICP-Brasil A3 USB/smartcard tokens.
#     pcscd must be running or no token will be enumerated by any application.
#   - aide: file integrity baseline — initialized at end of chroot after all
#     packages are installed so the DB reflects the final system state.
pacstrap -K /mnt \
    base linux linux-firmware sof-firmware base-devel \
    btrfs-progs grub efibootmgr \
    snapper snap-pac grub-btrfs btrfs-assistant \
    borg vorta udisks2 ntfs-3g kio-extras \
    git neovim less networkmanager \
    pipewire pipewire-pulse pipewire-alsa \
    bluez bluez-utils firewalld cups \
    nano sudo sane sane-airscan skanlite \
    plasma-desktop plasma-nm plasma-pa konsole tmux dolphin \
    xorg-xwayland \
    ttf-dejavu ttf-liberation noto-fonts noto-fonts-emoji ttf-cascadia-code \
    aspell-pt remmina freerdp \
    wine wine-mono wine-gecko \
    keepassxc kleopatra ksshaskpass tailscale \
    ark p7zip unrar zip unzip plasma-vault \
    kate ghostwriter okular pdfarranger \
    mpv vlc elisa \
    bluedevil plasma-systemmonitor kcalc kolourpaint pinta \
    firefox chromium \
    ffmpeg imagemagick handbrake soundconverter yt-dlp \
    thunderbird claws-mail \
    xdg-user-dirs power-profiles-daemon plasma-firewall \
    samba kdenetwork-filesharing avahi wsdd \
    baloo plocate \
    clamav audit chrony \
    cryptsetup libxml2 kscreen \
    sddm sddm-kcm kwalletmanager kwallet-pam \
    libreoffice-fresh libreoffice-fresh-pt-br mythes-pt-br \
    openssh spectacle wl-clipboard tree \
    pcsc-lite ccid opensc \
    aide

# 7. Generate Fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Grab the UUID of the raw encrypted partition — this must expand HERE (outer
# shell) so it is baked into the heredoc before arch-chroot runs.
CRYPT_UUID=$(blkid -s UUID -o value "${DISK}p2")

# All remaining variables that the heredoc needs are also expanded here in the
# outer shell. The heredoc delimiter is therefore unquoted (<<EOF), and every
# former \$VAR escape is gone — they are now plain $VAR references that expand
# at heredoc-construction time, before arch-chroot ever sees the script.

# 8. Non-Interactive Chroot Operations
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

# --- Timezone & Locale ---
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
sed -i 's/\bblock\b/block encrypt/' /etc/mkinitcpio.conf
mkinitcpio -P

# --- GRUB: LUKS + Btrfs snapshot boot support ---
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

# --- Snapper: create root config BEFORE enabling timers ---
# Without this, snapper-timeline.timer fails silently on first boot.
umount /.snapshots
rm -rf /.snapshots
snapper -c root create-config /
# snapper re-creates /.snapshots as its own directory; re-mount our subvolume
# over it so snapshots land on @snapshots, not on @.
mount -o $BTRFS_OPTS,subvol=@snapshots /dev/mapper/cryptroot /.snapshots

# --- grub-btrfs: watch for new snapshots and rebuild GRUB menu automatically ---
systemctl enable grub-btrfs.path

# --- ICP-Brasil A3 token support ---
# pcscd is the PC/SC daemon that brokers communication between applications
# (Lacuna Web PKI, Firefox NSS, OpenSC) and USB smartcard/token hardware.
# Without it running, no A3 token will be enumerated by anything regardless
# of what other software is installed.
#
# opensc provides PKCS#11 module at /usr/lib/opensc-pkcs11.so — this is the
# library that Firefox, Chromium and NSS-aware apps load to discover ICP-Brasil
# certificates on the token. We register it system-wide via p11-kit so that
# all applications pick it up automatically without per-app configuration.
mkdir -p /etc/pkcs11/modules
cat > /etc/pkcs11/modules/opensc.module <<P11KIT
module: /usr/lib/opensc-pkcs11.so
critical: no
P11KIT

# --- Headscale client configuration ---
# The Tailscale binary is used unchanged; only the coordination server URL
# differs. HEADSCALE_URL points to the self-hosted Headscale instance,
# keeping the control plane on Brazilian infrastructure and satisfying
# Provimento 213's logical segregation requirements.
#
# --accept-dns=true enables MagicDNS from the Headscale server so nodes
# resolve each other by hostname within the tailnet.
# --accept-routes allows the Headscale server to push subnet routes,
# useful if you later want to expose a serventia's LAN over the tailnet.
tailscale up \
    --login-server="$HEADSCALE_URL" \
    --authkey="$HEADSCALE_AUTHKEY" \
    --hostname="$HOSTNAME" \
    --accept-dns=true \
    --accept-routes=true || echo "WARN: tailscale up failed — run manually post-deploy"

# --- Enable all system services ---
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
echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/aur-bootstrap

sudo -u "$USER_NAME" bash <<AUREOF
set -euo pipefail

# Build and install yay from AUR
git clone https://aur.archlinux.org/yay.git /tmp/yay
cd /tmp/yay
makepkg -si --noconfirm
rm -rf /tmp/yay

# serpro-signer: wraps a Java app that activates against Serpro servers on
# first real user session — installation here is fine, activation is not.
yay -S --noconfirm hunspell-pt-br \
    || echo "WARN: hunspell-pt-br failed — install manually post-deploy"

yay -S --noconfirm serpro-signer \
    || echo "WARN: serpro-signer failed — install manually post-deploy"

# pjeoffice-pro: CNJ-maintained AUR package; can lag behind upstream releases.
# Failure here is non-fatal; the || echo ensures the deployment continues.
yay -S --noconfirm pjeoffice-pro \
    || echo "WARN: pjeoffice-pro failed — install manually post-deploy"

# lacuna-webpki: Lacuna Software's Web PKI bridge, required for ICP-Brasil A3
# token signing in web apps (PJe, e-Notariado, etc.).
# Note: the browser extension still needs to be enabled manually per user
# (Chrome Web Store / Firefox Add-ons) on first login.
yay -S --noconfirm lacuna-webpki \
    || echo "WARN: lacuna-webpki failed — install manually post-deploy"

AUREOF

# Revoke the temporary passwordless sudo now that AUR bootstrap is done
rm /etc/sudoers.d/aur-bootstrap

# --- AIDE file integrity baseline ---
# Must run AFTER all packages and AUR installs are complete so the DB
# reflects the intended final system state. Any subsequent drift from
# this baseline is detectable via 'aide --check'.
aide --init
mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
echo "AIDE baseline initialized."

EOF

# 9. WiFi pre-configuration (optional)
if [[ -n "${WIFI_SSID:-}" && -n "${WIFI_PASS:-}" ]]; then
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
umount -R /mnt
cryptsetup close cryptroot
reboot

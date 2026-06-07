#!/bin/bash
# ==========================================
# AUTOMATED ARCH LINUX DEPLOYMENT SCRIPT
# ==========================================

# 1. Variables (Adjust these per machine deployment)
DISK="/dev/nvme0n1"
HOSTNAME="cartorio-ws01"
USER_NAME="escrevente"
USER_PASS="senha_temporaria123"
ROOT_PASS="senha_root123"

# 2. Partitioning & Formatting
parted -s $DISK mktable gpt mkpart "EFI" fat32 0% 1GiB set 1 esp on mkpart "linux" btrfs 1GiB 100%
mkfs.fat -F 32 ${DISK}p1
mkfs.btrfs -f ${DISK}p2

# 3. Create Subvolumes
mount ${DISK}p2 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots
umount /mnt

# 4. Mount Order (Root subvolume first, then directories)
mount -o noatime,compress=zstd,space_cache=v2,subvol=@ ${DISK}p2 /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot/efi}
mount -o noatime,compress=zstd,space_cache=v2,subvol=@home ${DISK}p2 /mnt/home
mount -o noatime,compress=zstd,space_cache=v2,subvol=@log ${DISK}p2 /mnt/var/log
mount -o noatime,compress=zstd,space_cache=v2,subvol=@pkg ${DISK}p2 /mnt/var/cache/pacman/pkg
mount -o noatime,compress=zstd,space_cache=v2,subvol=@snapshots ${DISK}p2 /mnt/.snapshots
mount ${DISK}p1 /mnt/boot/efi

# 5. Base System Installation
pacstrap -K /mnt base linux linux-firmware base-devel btrfs-progs grub efibootmgr snapper snap-pac grub-btrfs btrfs-assistant borg vorta udisks2 ntfs-3g kio-extras git neovim networkmanager pipewire pipewire-pulse pipewire-alsa bluez bluez-utils firewalld cups nano sudo sane sane-airscan skanlite plasma-desktop plasma-nm plasma-pa konsole tmux dolphin xorg-xwayland ttf-dejavu ttf-liberation noto-fonts noto-fonts-emoji ttf-cascadia-code aspell-pt remmina freerdp wine wine-mono wine-gecko keepassxc kleopatra ksshaskpass tailscale ark p7zip unrar zip unzip plasma-vault kate ghostwriter okular pdfarranger mpv elisa bluedevil plasma-systemmonitor kcalc kolourpaint firefox chromium ffmpeg imagemagick handbrake soundconverter thunderbird claws-mail xdg-user-dirs power-profiles-daemon plasma-firewall samba kdenetwork-filesharing avahi wsdd baloo plocate clamav audit chrony cryptsetup libxml2 kscreen sddm sddm-kcm kwalletmanager kwallet-pam abiword gnumeric openssh spectacle wl-clipboard

# 6. Generate Fstab
genfstab -U /mnt >> /mnt/etc/fstab

# 7. Non-Interactive Chroot Operations
arch-chroot /mnt /bin/bash <<EOF
# Timezone & Locale Setup
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
hwclock --systohc
sed -i 's/^#pt_BR.UTF-8 UTF-8/pt_BR.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=pt_BR.UTF-8" > /etc/locale.conf
echo "\$HOSTNAME" > /etc/hostname

# User & Password Setup
echo "root:\$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash \$USER_NAME
echo "\$USER_NAME:\$USER_PASS" | chpasswd

# Enable Sudo Privileges for Wheel Group
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Bootloader Configuration
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
mkdir -p /boot/efi/EFI/BOOT
cp /boot/efi/EFI/GRUB/grubx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI

# Enable System Services
systemctl enable NetworkManager sshd tailscaled bluetooth firewalld smb nmb avahi-daemon wsdd cups chronyd power-profiles-daemon auditd fstrim.timer snapper-timeline.timer snapper-cleanup.timer clamav-freshclam.timer sddm
EOF

# 8. Unmount and Reboot
umount -R /mnt
reboot

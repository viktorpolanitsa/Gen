#!/bin/bash

set -e

# --- Initial Info ---
cd /

echo "---= AutoGentoo Installer =---"
echo "WARNING: This script will erase ALL DATA on the selected disk."
echo "Ensure you select the correct disk."
echo ""

# --- Gather info from the user ---
lsblk -dno NAME,SIZE,MODEL
echo ""
read -p "Enter disk name (e.g., sda or nvme0n1): " disk
disk="/dev/${disk}"

# Select Desktop Environment
echo "Select a desktop environment to install:"
options=("GNOME" "KDE Plasma" "XFCE" "LXQt" "Cinnamon" "MATE" "Exit")
select de_choice in "${options[@]}"; do
    case $de_choice in
        "GNOME"|"KDE Plasma"|"XFCE"|"LXQt"|"Cinnamon"|"MATE") break;;
        "Exit") exit;;
        *) echo "Invalid choice.";;
    esac
done

# Select init system
echo "Select init system:"
init_options=("OpenRC" "Systemd")
select init_choice in "${init_options[@]}"; do
    case $init_choice in
        "OpenRC"|"Systemd") break;;
        *) echo "Invalid choice.";;
    esac
done

# Select filesystem
echo "Select filesystem for root partition:"
fs_options=("ext4" "xfs" "btrfs")
select fs_choice in "${fs_options[@]}"; do
    case $fs_choice in
        "ext4"|"xfs"|"btrfs") break;;
        *) echo "Invalid choice.";;
    esac
done

read -p "Enter hostname: " hostname
read -p "Enter username: " username

# Root password
while true; do
    read -sp "Enter root password: " root_password; echo
    read -sp "Confirm root password: " root_password2; echo
    [ "$root_password" = "$root_password2" ] && break
    echo "Passwords do not match."
done

# User password
while true; do
    read -sp "Enter password for $username: " user_password; echo
    read -sp "Confirm password: " user_password2; echo
    [ "$user_password" = "$user_password2" ] && break
    echo "Passwords do not match."
done

echo ""
echo "--- Installation Configuration ---"
echo "Disk: $disk"
echo "Desktop Environment: $de_choice"
echo "Init System: $init_choice"
echo "Filesystem: $fs_choice"
echo "Hostname: $hostname"
echo "User: $username"
echo "Press Enter to begin..."
read

# --- System Preparation ---
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R ${disk}* || true
blockdev --flushbufs "$disk" || true
sleep 3

echo "--> Partitioning disk $disk..."
sfdisk --force --wipe always --wipe-partitions always "$disk" <<DISKEOF
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
DISKEOF

partprobe "$disk"
sleep 1

# Wipe old FS
wipefs -a "${disk}1"
wipefs -a "${disk}2"

# Format partitions
mkfs.vfat -F32 "${disk}1"
case "$fs_choice" in
    ext4) mkfs.ext4 -F "${disk}2";;
    xfs) mkfs.xfs -f "${disk}2";;
    btrfs) mkfs.btrfs -f "${disk}2";;
esac

# Mount
mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi

cd /mnt/gentoo

# --- Stage3 Download ---
echo "--> Fetching the latest Stage3..."
STAGE3_LIST_URL="https://builds.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt"
STAGE3_PATH=$(wget -qO- "$STAGE3_LIST_URL" | grep -v "^#" | grep 'stage3' | tail -n1 | awk '{print $1}')
STAGE3_URL="https://builds.gentoo.org/releases/amd64/autobuilds/${STAGE3_PATH}"
wget "$STAGE3_URL" -O stage3-amd64-openrc.tar.xz

# Unpack Stage3
tar xpvf stage3-amd64-openrc.tar.xz --xattrs-include='*.*' --numeric-owner

# Generate make.conf
case $de_choice in
    "GNOME") DE_USE_FLAGS="gtk gnome -qt5 -kde";;
    "KDE Plasma") DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
    "XFCE") DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
    "LXQt") DE_USE_FLAGS="qt5 lxqt -gtk -gnome";;
    "Cinnamon") DE_USE_FLAGS="gtk cinnamon -qt5 -kde -gnome";;
    "MATE") DE_USE_FLAGS="gtk mate -qt5 -kde -gnome";;
esac

cat > /mnt/gentoo/etc/portage/make.conf <<MAKECONF
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C target-cpu=native"
MAKEOPTS="-j$(nproc)"
USE="${DE_USE_FLAGS} dbus elogind pulseaudio"
ACCEPT_LICENSE="@FREE"
VIDEO_CARDS="amdgpu intel nouveau"
INPUT_DEVICES="libinput"
GRUB_PLATFORMS="efi-64"
MAKECONF

# Prepare chroot
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# Chroot script
cat > /mnt/gentoo/tmp/chroot.sh <<CHROOTEOF
set -e
source /etc/profile

healing_emerge() {
    local emerge_args=("\$@")
    local max_retries=5
    local attempt=1
    while [ \$attempt -le \$max_retries ]; do
        echo "--> Healing Emerge Attempt \$attempt for: emerge \${emerge_args[@]}"
        emerge --verbose "\${emerge_args[@]}" &> /tmp/emerge.log && { cat /tmp/emerge.log; return 0; }
        cat /tmp/emerge.log
        if grep -q "circular dependencies" /tmp/emerge.log; then
            local fix=\$(grep "Change USE:" /tmp/emerge.log | head -n1)
            if [ -n "\$fix" ]; then
                local full_package=\$(echo "\$fix" | awk '{print \$2}')
                local clean_package=\$(echo "\$full_package" | sed 's/-[0-9].*//')
                local use_change=\$(echo "\$fix" | awk -F 'Change USE: ' '{print \$2}' | sed 's/)//')
                mkdir -p /etc/portage/package.use
                echo "\$clean_package \$use_change" >> /etc/portage/package.use/99_autofix
                attempt=\$((attempt + 1))
                continue
            fi
        fi
        return 1
    done
    return 1
}

emerge-webrsync

# Profile selection
echo "--> Selecting profile for ${de_choice} and ${init_choice}..."
case "${de_choice}" in
    "GNOME") DE_PROFILE_PATTERN="gnome";;
    "KDE Plasma") DE_PROFILE_PATTERN="plasma";;
    "XFCE") DE_PROFILE_PATTERN="xfce";;
    "LXQt") DE_PROFILE_PATTERN="lxqt";;
    "Cinnamon") DE_PROFILE_PATTERN="cinnamon";;
    "MATE") DE_PROFILE_PATTERN="mate";;
esac

if [ "$init_choice" = "Systemd" ]; then
    INIT_PROFILE="systemd"
else
    INIT_PROFILE="openrc"
fi

DE_PROFILE=\$(eselect profile list | grep "desktop/${DE_PROFILE_PATTERN}" | grep "${INIT_PROFILE}" | grep 'merged-usr' | awk '{print \$2}' | tail -n1)
eselect profile set "\${DE_PROFILE}"

# Stage1: System
healing_emerge --update --deep --newuse @system

# Stage2: Desktop
case "${de_choice}" in
    "GNOME") healing_emerge gnome-shell/gnome;;
    "KDE Plasma") healing_emerge kde-plasma/plasma-meta;;
    "XFCE") healing_emerge xfce-base/xfce4-meta;;
    "LXQt") healing_emerge lxqt-meta/lxqt-meta;;
    "Cinnamon") healing_emerge cinnamon-meta/cinnamon-meta;;
    "MATE") healing_emerge mate-meta/mate-meta;;
esac

rm -f /etc/portage/package.use/99_autofix

# Stage3: World
healing_emerge --update --deep --newuse @world --keep-going=y

# CPU flags
emerge -q app-portage/cpuid2cpuflags
echo "*/* \$(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

# Locales
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8
env-update && source /etc/profile

# Kernel
echo "sys-kernel/installkernel grub dracut" > /etc/portage/package.use/installkernel
emerge -q sys-kernel/gentoo-kernel-bin

# fstab
emerge -q sys-fs/genfstab
genfstab -U / > /etc/fstab

# Hostname and users
echo "${hostname}" > /etc/hostname
echo "root:${root_password}" | chpasswd
useradd -m -G users,wheel,audio,video -s /bin/bash ${username}
echo "${username}:${user_password}" | chpasswd

# Utilities
emerge -q app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate
rc-update add sysklogd default
rc-update add chronyd default
rc-update add cronie default

# Networking
emerge -q net-misc/networkmanager
rc-update add NetworkManager default

# SSH
rc-update add sshd default

# Graphical system
emerge -q x11-base/xorg-server
case "${de_choice}" in
    "GNOME") rc-update add gdm default;;
    "KDE Plasma") emerge -q sys-boot/sddm; rc-update add sddm default;;
    "XFCE"|"LXQt"|"Cinnamon"|"MATE") emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
esac

# GRUB
emerge -q sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

echo "--> Chroot installation complete."
exit
CHROOTEOF

chmod +x /mnt/gentoo/tmp/chroot.sh

echo "--- Entering chroot ---"
chroot /mnt/gentoo /tmp/chroot.sh
rm /mnt/gentoo/tmp/chroot.sh

echo "--- Installation Complete! ---"
cd /
umount -l /mnt/gentoo/dev{/shm,/pts,}
umount -R /mnt/gentoo

echo "System ready to reboot. Type 'reboot' or Ctrl+C to remain in LiveCD."

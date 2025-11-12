#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

cd /

echo "---= Autotoo: The Ultimate Gentoo Installer =---"
echo "This script will erase ALL DATA on the selected disk."
echo "Please ensure you have selected the correct one."
echo ""

# --- Gather information from the user ---

# Select disk
lsblk -dno NAME,SIZE,MODEL
echo ""
read -p "Enter the name of the disk for installation (e.g., sda or nvme0n1): " disk
disk="/dev/${disk}"

# Select init system
echo "Select an init system to install:"
options=("OpenRC" "Systemd" "Exit")
select init_choice in "${options[@]}"; do
    case $init_choice in
        "OpenRC") break;;
        "Systemd") break;;
        "Exit") exit;;
        *) echo "Invalid choice. Please try again.";;
    esac
done

# Select Desktop Environment
echo "Select a desktop environment to install:"
options=("GNOME" "KDE Plasma" "XFCE" "LXQt" "MATE" "Cinnamon" "Exit")
select de_choice in "${options[@]}"; do
    case $de_choice in
        "GNOME") break;;
        "KDE Plasma") break;;
        "XFCE") break;;
        "LXQt") break;;
        "MATE") break;;
        "Cinnamon") break;;
        "Exit") exit;;
        *) echo "Invalid choice. Please try again.";;
    esac
done

read -p "Enter the hostname (computer name): " hostname
read -p "Enter a username for the new user: " username

# Get passwords (hidden input)
while true; do
    read -sp "Enter the root password: " root_password
    echo
    read -sp "Confirm the root password: " root_password2
    echo
    [ "$root_password" = "$root_password2" ] && break
    echo "Passwords do not match. Please try again."
done

while true; do
    read -sp "Enter the password for user $username: " user_password
    echo
    read -sp "Confirm the password for user $username: " user_password2
    echo
    [ "$user_password" = "$user_password2" ] && break
    echo "Passwords do not match. Please try again."
done

# Select filesystem type
echo "Select filesystem for root partition:"
options=("ext4" "xfs" "btrfs")
select fs_choice in "${options[@]}"; do
    case $fs_choice in
        "ext4") break;;
        "xfs") break;;
        "btrfs") break;;
        *) echo "Invalid choice. Please try again.";;
    esac
done

echo ""
echo "---= Installation Configuration =---"
echo "Disk: $disk"
echo "Init System: $init_choice"
echo "Desktop Environment: $de_choice"
echo "Filesystem: $fs_choice"
echo "Hostname: $hostname"
echo "User: $username"
echo "------------------------------------"
echo "Press Enter to begin the installation or Ctrl+C to cancel."
read

# --- Phase 1: System Preparation ---
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R ${disk}* || true
blockdev --flushbufs "$disk" || true
sleep 3

echo "--> Partitioning disk $disk..."
sfdisk --force --wipe always --wipe-partitions always "$disk" << DISKEOF
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
DISKEOF

partprobe "$disk"
sleep 1

wipefs -a "${disk}1"
wipefs -a "${disk}2"

echo "--> Formatting partitions..."
mkfs.vfat -F 32 "${disk}1"
case "$fs_choice" in
    ext4) mkfs.ext4 "${disk}2";;
    xfs) mkfs.xfs -f "${disk}2";;
    btrfs) mkfs.btrfs -f "${disk}2";;
esac

echo "--> Mounting filesystems..."
mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi

cd /mnt/gentoo

# --- Stage3 Download with mirror check ---
echo "--> Fetching the latest Stage3..."
STAGE3_LIST_PATH="autobuilds/latest-stage3-amd64-openrc.txt"
MIRRORS=(
    "https://distfiles.gentoo.org/releases/amd64/${STAGE3_LIST_PATH}"
    "https://mirror.leaseweb.com/gentoo/releases/amd64/${STAGE3_LIST_PATH}"
    "https://mirror.yandex.ru/gentoo/distfiles/releases/amd64/${STAGE3_LIST_PATH}"
    "https://ftp.osuosl.org/pub/gentoo/releases/amd64/${STAGE3_LIST_PATH}"
)

STAGE3_URL=""
for mirror in "${MIRRORS[@]}"; do
    if curl -s --head --fail "$mirror" >/dev/null; then
        STAGE3_URL="$mirror"
        echo "--> Using Stage3 mirror: $STAGE3_URL"
        break
    fi
done

if [ -z "$STAGE3_URL" ]; then
    echo "ERROR: No working Stage3 mirrors found."
    exit 1
fi

STAGE3_PATH=$(curl -s "$STAGE3_URL" | grep -v "^#" | grep 'stage3' | tail -n1 | awk '{print $1}')
FULL_STAGE3_URL=$(dirname "$STAGE3_URL")/"$STAGE3_PATH"

echo "--> Downloading Stage3 tarball from $FULL_STAGE3_URL..."
wget "$FULL_STAGE3_URL" -O stage3-amd64-openrc.tar.xz

echo "--> Unpacking Stage3..."
tar xpvf stage3-amd64-openrc.tar.xz --xattrs-include='*.*' --numeric-owner

# --- Generating make.conf ---
case $de_choice in
    "GNOME") DE_USE_FLAGS="gtk gnome -qt5 -kde";;
    "KDE Plasma") DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
    "XFCE") DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
    "LXQt") DE_USE_FLAGS="qt5 lxqt -gtk -gnome";;
    "MATE") DE_USE_FLAGS="gtk mate -qt5 -kde -gnome";;
    "Cinnamon") DE_USE_FLAGS="gtk cinnamon -qt5 -kde -gnome";;
esac

cat > /mnt/gentoo/etc/portage/make.conf << MAKECONF
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

# --- Preparing chroot environment ---
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# --- Chroot Script ---
cat > /mnt/gentoo/tmp/chroot.sh << CHROOTEOF
set -e
source /etc/profile

# Healing emerge function
healing_emerge() {
    local emerge_args=("\$@")
    local max_retries=5
    local attempt=1

    while [ \$attempt -le \$max_retries ]; do
        echo "--> Healing Emerge: Attempt \$attempt/\$max_retries for: emerge \${emerge_args[@]}"
        emerge --verbose "\${emerge_args[@]}" &> /tmp/emerge.log && {
            echo "--> Emerge successful."
            cat /tmp/emerge.log
            return 0
        }

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
        echo "--> Emerge failed with an unrecoverable error."
        return 1
    done
    echo "--> Failed to resolve dependencies after \$max_retries attempts."
    return 1
}

# Sync Portage
emerge-webrsync

# Set profile
eselect profile set default/linux/amd64/17.1/desktop/openrc

# Stage 1: System base
healing_emerge --update --deep --newuse @system

# Stage 2: Desktop environment
case "${de_choice}" in
    "GNOME") healing_emerge gnome-base/gnome;;
    "KDE Plasma") healing_emerge kde-plasma/plasma-meta;;
    "XFCE") healing_emerge xfce-base/xfce4-meta;;
    "LXQt") healing_emerge lxqt-base/lxqt-meta;;
    "MATE") healing_emerge mate-base/mate-meta;;
    "Cinnamon") healing_emerge cinnamon-base/cinnamon-meta;;
esac

rm -f /etc/portage/package.use/99_autofix

# Stage 3: World update
healing_emerge --update --deep --newuse @world --keep-going=y

# Kernel install
emerge -q sys-kernel/gentoo-kernel-bin

# Locales and environment
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8
env-update && source /etc/profile

# Install base utilities
emerge -q app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate
rc-update add sysklogd default
rc-update add chronyd default
rc-update add cronie default

# Networking and SSH
emerge -q net-misc/networkmanager
rc-update add NetworkManager default
rc-update add sshd default

# Display manager
emerge -q x11-base/xorg-server
case "${de_choice}" in
    "GNOME") rc-update add gdm default;;
    "KDE Plasma") emerge -q sys-boot/sddm; rc-update add sddm default;;
    "XFCE") emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
esac

# Create user
useradd -m -G users,wheel,audio,video -s /bin/bash ${username}
echo "${username}:${user_password}" | chpasswd

# GRUB
emerge -q sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

# Hostname and root password
echo "${hostname}" > /etc/hostname
echo "root:${root_password}" | chpasswd

exit
CHROOTEOF

chmod +x /mnt/gentoo/tmp/chroot.sh

echo "--- Phase 2: Entering chroot and installing the system ---"
chroot /mnt/gentoo /tmp/chroot.sh
rm /mnt/gentoo/tmp/chroot.sh

echo "--- Installation Complete! ---"
echo "--> Unmounting filesystems..."
cd /
umount -l /mnt/gentoo/dev{/shm,/pts,}
umount -R /mnt/gentoo

echo "The system is ready to reboot. Type 'reboot' to enter your new Gentoo system."
echo "Press Ctrl+C if you wish to remain in the LiveCD environment."

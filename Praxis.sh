#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Изгнание ---
cd /

echo "---= Autotoo: The Wise Gentoo Installer =---"
echo "This script will erase ALL DATA on the selected disk."
echo "Please ensure you have selected the correct one."
echo ""

# --- Gather information from the user ---

# Select disk
lsblk -dno NAME,SIZE,MODEL
echo ""
read -p "Enter the name of the disk for installation (e.g., sda or nvme0n1): " disk
disk="/dev/${disk}"

# Select Desktop Environment (DE)
echo "Select a desktop environment to install:"
options=("GNOME" "KDE Plasma" "XFCE" "Exit")
select de_choice in "${options[@]}"; do
    case $de_choice in
        "GNOME") break;;
        "KDE Plasma") break;;
        "XFCE") break;;
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

echo ""
echo "---= Installation Configuration =---"
echo "Disk: $disk"
echo "Environment: $de_choice"
echo "Hostname: $hostname"
echo "User: $username"
echo "------------------------------------"
echo "Press Enter to begin the installation or Ctrl+C to cancel."
read

# --- Phase 1: System Preparation ---

echo "--> Performing exorcism on ${disk} to release all holds..."
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R ${disk}* || true
blockdev --flushbufs "$disk" || true
echo "--> Giving the kernel a moment to release the device..."
sleep 3

echo "--> Partitioning disk $disk..."
sfdisk --force --wipe always --wipe-partitions always "$disk" << DISKEOF
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
DISKEOF

echo "--> Forcing kernel to re-read partition table..."
partprobe "$disk"
sleep 1

echo "--> Wiping old filesystem signatures..."
wipefs -a "${disk}1"
wipefs -a "${disk}2"

echo "--> Formatting partitions..."
mkfs.vfat -F 32 "${disk}1"
mkfs.xfs -f "${disk}2"

echo "--> Mounting filesystems..."
mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi

cd /mnt/gentoo

echo "--> Downloading the latest Stage3 tarball..."
STAGE3_PATH=$(wget -q -O - https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | grep -v "^#" | grep 'stage3' | head -n 1 | cut -d' ' -f1)
wget "https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_PATH}"

echo "--> Unpacking Stage3..."
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

echo "--> Generating make.conf..."
case $de_choice in
    "GNOME") DE_USE_FLAGS="gtk gnome -qt5 -kde";;
    "KDE Plasma") DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
    "XFCE") DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
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

echo "--> Preparing the chroot environment..."
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

echo "--> Generating the chroot script..."
cat > /mnt/gentoo/tmp/chroot.sh << CHROOTEOF
set -e
source /etc/profile

echo "--> Syncing Portage..."
emerge-webrsync

echo "--> Dynamically selecting the best profile for ${de_choice}..."
case "${de_choice}" in
    "GNOME") DE_PROFILE=\$(eselect profile list | grep 'desktop/gnome' | grep -v 'systemd' | awk '{print \$2}' | tail -n 1);;
    "KDE Plasma") DE_PROFILE=\$(eselect profile list | grep 'desktop/plasma' | grep -v 'systemd' | awk '{print \$2}' | tail -n 1);;
    "XFCE") DE_PROFILE=\$(eselect profile list | grep 'desktop' | grep -v 'gnome' | grep -v 'plasma' | grep -v 'systemd' | awk '{print \$2}' | tail -n 1);;
esac

echo "--> Profile found: \${DE_PROFILE}"
eselect profile set "\${DE_PROFILE}"

# --- ФИНАЛЬНЫЙ УДАР: СТУПЕНЧАТАЯ СБОРКА ---
# Мы больше не обновляем @world сразу. Мы делаем это в три этапа,
# чтобы избежать циклических зависимостей и других сложных проблем.

echo "--> Stage 1/3: Building the system foundation..."
emerge --verbose --update --deep --newuse @system

echo "--> Stage 2/3: Building the desktop environment..."
case "${de_choice}" in
    "GNOME") emerge -q gnome-shell/gnome;;
    "KDE Plasma") emerge -q kde-plasma/plasma-meta;;
    "XFCE") emerge -q xfce-base/xfce4-meta;;
esac

echo "--> Stage 3/3: Final world update and cleanup..."
emerge --verbose --update --deep --newuse @world

echo "--> Configuring CPU flags..."
emerge -q app-portage/cpuid2cpuflags
echo "*/* \$(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

echo "--> Configuring locales..."
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8
env-update && source /etc/profile

echo "--> Installing the binary kernel..."
echo "sys-kernel/installkernel grub dracut" > /etc/portage/package.use/installkernel
emerge -q sys-kernel/gentoo-kernel-bin

echo "--> Generating fstab..."
emerge -q sys-fs/genfstab
genfstab -U / > /etc/fstab

echo "--> Configuring hostname..."
echo "${hostname}" > /etc/hostname

echo "--> Setting root password..."
echo "root:${root_password}" | chpasswd

echo "--> Installing base system utilities..."
emerge -q app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate
rc-update add sysklogd default
rc-update add chronyd default
rc-update add cronie default

echo "--> Installing and configuring networking..."
emerge -q net-misc/networkmanager
rc-update add NetworkManager default

echo "--> Installing and configuring SSH..."
rc-update add sshd default

echo "--> Installing the graphical subsystem and Display Manager..."
emerge -q x11-base/xorg-server
case "${de_choice}" in
    "GNOME") rc-update add gdm default;;
    "KDE Plasma") emerge -q sys-boot/sddm; rc-update add sddm default;;
    "XFCE") emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
esac

echo "--> Creating user ${username}..."
useradd -m -G users,wheel,audio,video -s /bin/bash ${username}
echo "${username}:${user_password}" | chpasswd

echo "--> Installing and configuring the GRUB bootloader..."
emerge -q sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

echo "--> Installation inside chroot is complete."
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

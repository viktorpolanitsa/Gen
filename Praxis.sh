#!/bin.bash

# Немедленно выходить, если команда завершается с ошибкой.
set -e

echo "---= Autotoo: The Wise Gentoo Installer =---"
echo "This script will erase ALL DATA on the selected disk."
echo "Please ensure you have selected the correct one."
echo ""

# --- Сбор информации от пользователя ---

# Выбор диска
lsblk -dno NAME,SIZE,MODEL
echo ""
read -p "Enter the name of the disk for installation (e.g., sda or nvme0n1): " disk
disk="/dev/${disk}"

# Выбор графического окружения (DE)
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

# Ввод паролей (скрытый)
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

# --- Фаза 1: Подготовка системы ---

echo "--> Partitioning disk $disk..."
sfdisk "$disk" << DISKEOF
label: gpt
unit: sectors
,1M,U
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
DISKEOF

echo "--> Formatting partitions..."
mkfs.vfat -F 32 "${disk}1"
mkfs.xfs "${disk}2"

echo "--> Mounting filesystems..."
mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi

cd /mnt/gentoo

echo "--> Downloading the latest Stage3 tarball..."
STAGE3_PATH=$(wget -q -O - https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | grep -v "^#" | cut -d' ' -f1)
wget "https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_PATH}"

echo "--> Unpacking Stage3..."
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

echo "--> Generating make.conf..."
# Установка переменных для DE
case $de_choice in
    "GNOME")
        DE_USE_FLAGS="gtk gnome -qt5 -kde"
        DE_PROFILE="default/linux/amd64/17.1/desktop/gnome"
        ;;
    "KDE Plasma")
        DE_USE_FLAGS="qt5 plasma kde -gtk -gnome"
        DE_PROFILE="default/linux/amd64/17.1/desktop/plasma"
        ;;
    "XFCE")
        DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome"
        DE_PROFILE="default/linux/amd64/17.1/desktop" # XFCE хорошо работает с базовым desktop профилем
        ;;
esac

cat > /mnt/gentoo/etc/portage/make.conf << MAKECONF
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C target-cpu=native"
MAKEOPTS="-j$(nproc)"

# Настройки для выбранного DE
USE="${DE_USE_FLAGS} dbus elogind pulseaudio"

# Лицензии
ACCEPT_LICENSE="@FREE"

# Настройки для видео и устройств ввода
VIDEO_CARDS="amdgpu intel nouveau" # Добавь nvidia, если нужно
INPUT_DEVICES="libinput"

# Включаем поддержку GRUB для EFI
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

echo "--> Selecting profile: ${DE_PROFILE}"
eselect profile set ${DE_PROFILE}

echo "--> Updating the world set with new USE flags..."
emerge --verbose --update --deep --newuse @world

echo "--> Configuring CPU flags..."
emerge -q app-portage/cpuid2cpuflags
echo "*/* \$(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

echo "--> Configuring locales..."
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
# Если хочешь русскую локаль в системе, раскомментируй следующую строку
# echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
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

echo "--> Installing the graphical subsystem..."
emerge -q x11-base/xorg-server

# Установка DE
case "${de_choice}" in
    "GNOME")
        echo "--> Installing GNOME..."
        emerge -q gnome-shell/gnome
        rc-update add gdm default
        ;;
    "KDE Plasma")
        echo "--> Installing KDE Plasma..."
        emerge -q kde-plasma/plasma-meta
        rc-update add sddm default
        ;;
    "XFCE")
        echo "--> Installing XFCE..."
        emerge -q xfce-base/xfce4-meta x11-terms/xfce4-terminal sys-boot/sddm
        rc-update add sddm default
        ;;
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
umount -l /mnt/gentoo/dev{/shm,/pts,}
umount -R /mnt/gentoo

echo "The system is ready to reboot. Type 'reboot' to enter your new Gentoo system."
echo "Press Ctrl+C if you wish to remain in the LiveCD environment."

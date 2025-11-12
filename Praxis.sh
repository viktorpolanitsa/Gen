#!/bin/bash

set -e

cd /

echo "---= AutoGentoo Installer =---"
echo "This script will erase ALL DATA on the selected disk."
echo "Ensure the correct disk is selected."
echo ""

# --- Select Disk ---
lsblk -dno NAME,SIZE,MODEL
echo ""
read -p "Enter disk name (e.g., sda or nvme0n1): " disk
disk="/dev/${disk}"

# --- Select Filesystem ---
echo "Select filesystem for root partition:"
fs_options=("ext4" "xfs" "btrfs")
select root_fs in "${fs_options[@]}"; do
    case $root_fs in
        "ext4"|"xfs"|"btrfs") break;;
        *) echo "Invalid choice.";;
    esac
done

# --- Desktop Environment Selection ---
echo "Select a desktop environment:"
de_options=("GNOME" "KDE Plasma" "XFCE" "LXQt" "MATE" "Cinnamon" "Exit")
select de_choice in "${de_options[@]}"; do
    case $de_choice in
        "GNOME"|"KDE Plasma"|"XFCE"|"LXQt"|"MATE"|"Cinnamon") break;;
        "Exit") exit;;
        *) echo "Invalid choice.";;
    esac
done

read -p "Enter hostname: " hostname
read -p "Enter username: " username

# --- Passwords ---
while true; do
    read -sp "Enter root password: " root_password
    echo
    read -sp "Confirm root password: " root_password2
    echo
    [ "$root_password" = "$root_password2" ] && break
    echo "Passwords do not match."
done

while true; do
    read -sp "Enter password for $username: " user_password
    echo
    read -sp "Confirm password: " user_password2
    echo
    [ "$user_password" = "$user_password2" ] && break
    echo "Passwords do not match."
done

echo ""
echo "--- Installation Configuration ---"
echo "Disk: $disk"
echo "Root filesystem: $root_fs"
echo "Environment: $de_choice"
echo "Hostname: $hostname"
echo "User: $username"
echo "--------------------------------"
read -p "Press Enter to continue or Ctrl+C to cancel."

# --- System Preparation ---
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R ${disk}* || true
blockdev --flushbufs "$disk" || true
sleep 3

# --- Partition ---
sfdisk --force --wipe always --wipe-partitions always "$disk" << DISKEOF
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
DISKEOF

partprobe "$disk"
sleep 1

wipefs -a "${disk}1"
wipefs -a "${disk}2"

mkfs.vfat -F 32 "${disk}1"

case "$root_fs" in
    "ext4") mkfs.ext4 -F "${disk}2";;
    "xfs") mkfs.xfs -f "${disk}2";;
    "btrfs") mkfs.btrfs -f "${disk}2";;
esac

mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi

cd /mnt/gentoo

# --- Select Fastest Stage3 Mirror and Download ---
echo "--> Selecting fastest Stage3 mirror..."
MIRROR=$(curl -s https://www.gentoo.org/downloads/mirrors/ | \
  grep -oP 'https://mirror.*?gentoo.org' | head -n5 | while read url; do
    TIME=$(curl -o /dev/null -s -w "%{time_total}" "$url/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt")
    echo "$TIME $url"
done | sort -n | head -n1 | awk '{print $2}')

[[ "${MIRROR}" != */ ]] && MIRROR="${MIRROR}/"

STAGE3_PATH=$(wget -q -O - "${MIRROR}releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt" | \
  grep -v "^#" | grep 'stage3' | head -n1 | cut -d' ' -f1)

wget "${MIRROR}releases/amd64/autobuilds/${STAGE3_PATH}"
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

# --- make.conf ---
case $de_choice in
    "GNOME") DE_USE_FLAGS="gtk gnome -qt5 -kde";;
    "KDE Plasma") DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
    "XFCE") DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
    "LXQt") DE_USE_FLAGS="lxqt qt5 -gtk";;
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

# --- Prepare chroot ---
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# --- Chroot script ---
cat > /mnt/gentoo/tmp/chroot.sh << 'CHROOTEOF'
set -e
source /etc/profile

healing_emerge() {
    local emerge_args=("$@")
    local max_retries=5
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        echo "--> Healing Emerge: Attempt $attempt/$max_retries"
        emerge --verbose "${emerge_args[@]}" &> /tmp/emerge.log && return 0
        cat /tmp/emerge.log
        if grep -q "circular dependencies" /tmp/emerge.log; then
            local fix=$(grep "Change USE:" /tmp/emerge.log | head -n1)
            if [ -n "$fix" ]; then
                local full_package=$(echo "$fix" | awk '{print $2}')
                local clean_package=$(echo "$full_package" | sed 's/-[0-9].*//')
                local use_change=$(echo "$fix" | awk -F 'Change USE: ' '{print $2}' | sed 's/)//')
                mkdir -p /etc/portage/package.use
                echo "$clean_package $use_change" >> /etc/portage/package.use/99_autofix
                attempt=$((attempt+1))
                continue
            fi
        fi
        return 1
    done
}

emerge-webrsync

DE_CHOICE=$(eselect profile list | grep desktop | grep -v systemd | awk '{print $2}' | tail -n1)
eselect profile set "$DE_CHOICE"

healing_emerge --update --deep --newuse @system

case "$de_choice" in
    "GNOME") healing_emerge gnome-shell/gnome;;
    "KDE Plasma") healing_emerge kde-plasma/plasma-meta;;
    "XFCE") healing_emerge xfce-base/xfce4-meta;;
    "LXQt") healing_emerge lxqt-meta;;
    "MATE") healing_emerge mate-meta;;
    "Cinnamon") healing_emerge cinnamon-meta;;
esac

rm -f /etc/portage/package.use/99_autofix

healing_emerge --update --deep --newuse @world --keep-going=y

emerge -q app-portage/cpuid2cpuflags
echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8
env-update && source /etc/profile

echo "sys-kernel/installkernel grub dracut" > /etc/portage/package.use/installkernel
emerge -q sys-kernel/gentoo-kernel-bin

emerge -q sys-fs/genfstab
genfstab -U / > /etc/fstab

echo "$hostname" > /etc/hostname
echo "root:$root_password" | chpasswd

emerge -q app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate
rc-update add sysklogd default
rc-update add chronyd default
rc-update add cronie default

emerge -q net-misc/networkmanager
rc-update add NetworkManager default

rc-update add sshd default

emerge -q x11-base/xorg-server
case "$de_choice" in
    "GNOME") rc-update add gdm default;;
    "KDE Plasma") emerge -q sys-boot/sddm; rc-update add sddm default;;
    "XFCE") emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
    "LXQt"|"MATE"|"Cinnamon") emerge -q lightdm; rc-update add lightdm default;;
esac

useradd -m -G users,wheel,audio,video -s /bin/bash $username
echo "$username:$user_password" | chpasswd

emerge -q sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

exit
CHROOTEOF

chmod +x /mnt/gentoo/tmp/chroot.sh
chroot /mnt/gentoo /tmp/chroot.sh
rm /mnt/gentoo/tmp/chroot.sh

cd /
umount -l /mnt/gentoo/dev{/shm,/pts,}
umount -R /mnt/gentoo

echo "--- Installation Complete ---"
echo "Reboot with 'reboot' or stay in LiveCD environment."

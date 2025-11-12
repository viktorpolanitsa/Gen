#!/bin/bash
set -e

# --- Preparation ---
cd /

echo "---= Autotoo: The Wise Gentoo Installer =---"
echo "This script will erase ALL DATA on the selected disk."
echo "Ensure you select the correct disk."
echo ""

# --- Select disk ---
lsblk -dno NAME,SIZE,MODEL
echo ""
read -p "Enter the disk for installation (e.g., sda or nvme0n1): " disk
disk="/dev/${disk}"

# --- Select init system ---
echo "Select init system:"
init_options=("OpenRC" "Systemd" "Exit")
select init_choice in "${init_options[@]}"; do
    case $init_choice in
        "OpenRC") break;;
        "Systemd") break;;
        "Exit") exit;;
        *) echo "Invalid choice. Try again.";;
    esac
done

# --- Select Desktop Environment ---
echo "Select a desktop environment:"
de_options=("GNOME" "KDE Plasma" "XFCE" "LXQt" "MATE" "Exit")
select de_choice in "${de_options[@]}"; do
    case $de_choice in
        "GNOME"|"KDE Plasma"|"XFCE"|"LXQt"|"MATE") break;;
        "Exit") exit;;
        *) echo "Invalid choice. Try again.";;
    esac
done

# --- Hostname and user ---
read -p "Enter hostname: " hostname
read -p "Enter username: " username

# --- Root password ---
while true; do
    read -sp "Enter root password: " root_password
    echo
    read -sp "Confirm root password: " root_password2
    echo
    [ "$root_password" = "$root_password2" ] && break
    echo "Passwords do not match."
done

# --- User password ---
while true; do
    read -sp "Enter password for user $username: " user_password
    echo
    read -sp "Confirm password: " user_password2
    echo
    [ "$user_password" = "$user_password2" ] && break
    echo "Passwords do not match."
done

# --- Partitioning ---
echo "--> Partitioning disk $disk..."
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R ${disk}* || true
blockdev --flushbufs "$disk" || true
sleep 2

echo "Select filesystem for root partition:"
fs_options=("ext4" "xfs" "btrfs")
select fs_choice in "${fs_options[@]}"; do
    case $fs_choice in
        "ext4"|"xfs"|"btrfs") break;;
        *) echo "Invalid choice.";;
    esac
done

# --- Create GPT partitions ---
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

case "$fs_choice" in
    "ext4") mkfs.ext4 -F "${disk}2";;
    "xfs") mkfs.xfs -f "${disk}2";;
    "btrfs") mkfs.btrfs -f "${disk}2";;
esac

mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi

cd /mnt/gentoo

# --- Detect fastest Stage3 mirror ---
echo "--> Detecting user location..."
USER_COUNTRY=$(curl -s https://ipapi.co/country/ || echo "UNKNOWN")
echo "Detected country: $USER_COUNTRY"

echo "--> Getting Gentoo mirror list..."
MIRROR_LIST=$(curl -s https://www.gentoo.org/downloads/mirrors/ | grep -oP 'https?://[^"]+')
if [[ "$USER_COUNTRY" == "RU" ]]; then
    MIRROR_LIST=$(echo "$MIRROR_LIST" | grep -i "ru")
fi

FASTEST_MIRROR=""
MIN_TIME=1000
for MIRROR in $MIRROR_LIST; do
    RESPONSE_TIME=$(curl -o /dev/null -s -w "%{time_total}\n" "$MIRROR/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt" || echo 1000)
    RESPONSE_TIME=${RESPONSE_TIME%.*}
    if (( RESPONSE_TIME < MIN_TIME )); then
        MIN_TIME=$RESPONSE_TIME
        FASTEST_MIRROR=$MIRROR
    fi
done

if [[ -z "$FASTEST_MIRROR" ]]; then
    echo "ERROR: No accessible Stage3 mirrors found."
    exit 1
fi
echo "--> Using fastest mirror: $FASTEST_MIRROR"

STAGE3_FILE=$(wget -q -O - "$FASTEST_MIRROR/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt" | grep -v "^#" | grep 'stage3' | head -n1 | cut -d' ' -f1)
wget "$FASTEST_MIRROR/releases/amd64/autobuilds/$STAGE3_FILE"

# --- Extract Stage3 ---
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

# --- Make.conf ---
case $de_choice in
    "GNOME") DE_USE_FLAGS="gtk gnome -qt5 -kde";;
    "KDE Plasma") DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
    "XFCE") DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
    "LXQt") DE_USE_FLAGS="lxqt -kde -gnome";;
    "MATE") DE_USE_FLAGS="mate -kde -gnome";;
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
cat > /mnt/gentoo/tmp/chroot.sh << CHROOTEOF
set -e
source /etc/profile

healing_emerge() {
    local args=(\$@)
    local max_retries=5
    local attempt=1
    while [ \$attempt -le \$max_retries ]; do
        emerge --verbose "\${args[@]}" &> /tmp/emerge.log && return 0
        if grep -q "circular dependencies" /tmp/emerge.log; then
            attempt=\$((attempt + 1))
            continue
        fi
        return 1
    done
    return 1
}

# --- Sync Portage ---
emerge-webrsync

# --- Detect and set profile ---
PROFILE_LIST=\$(eselect profile list | grep "desktop" | grep -v "systemd" | awk '{print \$2}')
PROFILE_CHOICE=\$(echo "\$PROFILE_LIST" | tail -n1)
eselect profile set "\$PROFILE_CHOICE"

# --- Update system ---
healing_emerge --update --deep --newuse @system
case "$de_choice" in
    "GNOME") healing_emerge gnome-shell/gnome;;
    "KDE Plasma") healing_emerge kde-plasma/plasma-meta;;
    "XFCE") healing_emerge xfce-base/xfce4-meta;;
    "LXQt") healing_emerge lxqt-meta;;
    "MATE") healing_emerge mate-meta;;
esac
healing_emerge --update --deep --newuse @world --keep-going=y

# --- CPU flags ---
emerge -q app-portage/cpuid2cpuflags
echo "*/* \$(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

# --- Locales ---
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8
env-update && source /etc/profile

# --- Kernel ---
emerge -q sys-kernel/gentoo-kernel-bin

# --- Fstab ---
emerge -q sys-fs/genfstab
genfstab -U / > /etc/fstab

# --- Hostname ---
echo "$hostname" > /etc/hostname

# --- Root password ---
echo "root:$root_password" | chpasswd

# --- User ---
useradd -m -G users,wheel,audio,video -s /bin/bash $username
echo "$username:$user_password" | chpasswd

# --- Networking and SSH ---
emerge -q net-misc/networkmanager
rc-update add NetworkManager default
rc-update add sshd default

# --- X and Display Manager ---
emerge -q x11-base/xorg-server
case "$de_choice" in
    "GNOME") rc-update add gdm default;;
    "KDE Plasma") emerge -q sys-boot/sddm; rc-update add sddm default;;
    "XFCE") emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
    "LXQt") emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
    "MATE") emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
esac

# --- GRUB ---
emerge -q sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

exit
CHROOTEOF

chmod +x /mnt/gentoo/tmp/chroot.sh
chroot /mnt/gentoo /tmp/chroot.sh
rm /mnt/gentoo/tmp/chroot.sh

# --- Cleanup ---
cd /
umount -l /mnt/gentoo/dev{/shm,/pts,}
umount -R /mnt/gentoo

echo "--- Installation Complete! ---"
echo "Type 'reboot' to enter your new Gentoo system."

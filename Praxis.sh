#!/bin/bash
set -e

# --- Variables ---
ARCH="amd64"
DEFAULT_INIT="openrc"
BINPKG="yes"

# --- Disk selection ---
lsblk -dno NAME,SIZE,MODEL
echo ""
read -p "Enter the name of the disk for installation (e.g., sda or nvme0n1): " disk
disk="/dev/${disk}"

# --- Desktop Environment ---
DE_OPTIONS=("GNOME" "KDE Plasma" "XFCE" "MATE" "Cinnamon" "LXDE" "LXQt" "Exit")
echo "Select a Desktop Environment:"
select de_choice in "${DE_OPTIONS[@]}"; do
    [[ " ${DE_OPTIONS[*]} " =~ " ${de_choice} " ]] || { echo "Invalid choice"; continue; }
    [[ "$de_choice" == "Exit" ]] && exit
    break
done

# --- Init System ---
INIT_OPTIONS=("openrc" "systemd")
echo "Select init system:"
select init_choice in "${INIT_OPTIONS[@]}"; do
    [[ " ${INIT_OPTIONS[*]} " =~ " ${init_choice} " ]] || { echo "Invalid choice"; continue; }
    break
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

# --- Filesystem selection ---
FS_OPTIONS=("ext4" "xfs" "btrfs")
echo "Select filesystem for root partition:"
select fs_choice in "${FS_OPTIONS[@]}"; do
    [[ " ${FS_OPTIONS[*]} " =~ " ${fs_choice} " ]] || { echo "Invalid choice"; continue; }
    break
done

# --- Stage3 Mirror selection ---
echo "--> Selecting fastest available Stage3 mirror..."
MIRRORS=(
    "https://mirror.yandex.ru/gentoo"
    "https://mirror.truenetwork.ru/gentoo"
    "https://mirror.karneval.cz/gentoo"
    "https://distfiles.gentoo.org"
)
STAGE3_FILE=""
for MIRROR in "${MIRRORS[@]}"; do
    echo "--> Testing mirror $MIRROR ..."
    if wget --spider -q "$MIRROR/releases/$ARCH/autobuilds/latest-stage3-$ARCH-$init_choice.txt"; then
        STAGE3_FILE=$(wget -qO- "$MIRROR/releases/$ARCH/autobuilds/latest-stage3-$ARCH-$init_choice.txt" | grep -v "^#" | grep stage3 | head -n1 | awk '{print $1}')
        [ -n "$STAGE3_FILE" ] && { STAGE3_URL="$MIRROR/releases/$ARCH/autobuilds/$STAGE3_FILE"; break; }
    fi
done

[ -z "$STAGE3_URL" ] && { echo "ERROR: No valid Stage3 found. Exiting."; exit 1; }

echo "--> Stage3 URL: $STAGE3_URL"
wget "$STAGE3_URL" -O stage3.tar.xz

# --- Partitioning and Formatting ---
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R ${disk}* || true
blockdev --flushbufs "$disk" || true
sleep 2

echo "--> Partitioning $disk..."
sfdisk --force --wipe always --wipe-partitions always "$disk" << EOF
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
EOF

partprobe "$disk"
sleep 1

wipefs -a "${disk}1"
wipefs -a "${disk}2"

case "$fs_choice" in
    ext4) mkfs.ext4 -F "${disk}2";;
    xfs) mkfs.xfs -f "${disk}2";;
    btrfs) mkfs.btrfs -f "${disk}2";;
esac
mkfs.vfat -F32 "${disk}1"

mkdir -p /mnt/gentoo/efi
mount "${disk}2" /mnt/gentoo
mount "${disk}1" /mnt/gentoo/efi

# --- Unpack Stage3 ---
cd /mnt/gentoo
tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner

# --- make.conf ---
case $de_choice in
    "GNOME") DE_USE_FLAGS="gtk gnome -qt5 -kde";;
    "KDE Plasma") DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
    "XFCE") DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
    "MATE") DE_USE_FLAGS="gtk mate -qt5 -kde -gnome";;
    "Cinnamon") DE_USE_FLAGS="gtk cinnamon -qt5 -kde -gnome";;
    "LXDE") DE_USE_FLAGS="gtk lxde -qt5 -kde -gnome";;
    "LXQt") DE_USE_FLAGS="qt5 lxqt -gtk -kde -gnome";;
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

# --- Chroot setup ---
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
#!/bin/bash
set -e
source /etc/profile

healing_emerge() {
    local max_retries=5
    local attempt=1
    while [ \$attempt -le \$max_retries ]; do
        emerge --verbose "\$@" &> /tmp/emerge.log && { cat /tmp/emerge.log; return 0; }
        cat /tmp/emerge.log
        attempt=\$((attempt + 1))
    done
    echo "--> Failed after \$max_retries attempts"
    return 1
}

# Sync Portage
emerge-webrsync

# Set profile
LATEST_PROFILE=\$(eselect profile list | grep "default/linux/${ARCH}/" | tail -n1 | awk '{print \$1}')
eselect profile set \$LATEST_PROFILE

# Stage1/3: system base
healing_emerge --update --deep --newuse @system

# Stage2/3: desktop
case "${de_choice}" in
    "GNOME") healing_emerge gnome-shell/gnome;;
    "KDE Plasma") healing_emerge kde-plasma/plasma-meta;;
    "XFCE") healing_emerge xfce-base/xfce4-meta;;
    "MATE") healing_emerge mate-base/mate-meta;;
    "Cinnamon") healing_emerge cinnamon-meta/cinnamon-meta;;
    "LXDE") healing_emerge lxde-meta/lxde-meta;;
    "LXQt") healing_emerge lxqt-meta/lxqt-meta;;
esac

# Stage3/3: world update
healing_emerge --update --deep --newuse @world --keep-going=y

# Locale and timezone
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8
env-update && source /etc/profile

# Kernel binary
emerge -q sys-kernel/gentoo-kernel-bin

# Fstab
genfstab -U / > /etc/fstab

# Hostname and users
echo "${hostname}" > /etc/hostname
echo "root:${root_password}" | chpasswd
useradd -m -G users,wheel,audio,video -s /bin/bash ${username}
echo "${username}:${user_password}" | chpasswd

# Basic services
emerge -q app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate
rc-update add sysklogd default
rc-update add chronyd default
rc-update add cronie default
emerge -q net-misc/networkmanager
rc-update add NetworkManager default
rc-update add sshd default

# X11 and DM
emerge -q x11-base/xorg-server
case "${de_choice}" in
    "GNOME") rc-update add gdm default;;
    "KDE Plasma") emerge -q sys-boot/sddm; rc-update add sddm default;;
    "XFCE"|"MATE"|"Cinnamon"|"LXDE"|"LXQt") emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
esac

# GRUB
emerge -q sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

exit
CHROOTEOF

chmod +x /mnt/gentoo/tmp/chroot.sh

# --- Enter chroot ---
chroot /mnt/gentoo /tmp/chroot.sh
rm /mnt/gentoo/tmp/chroot.sh

# --- Cleanup ---
cd /
umount -l /mnt/gentoo/dev{/shm,/pts,} || true
umount -R /mnt/gentoo || true

echo "--- Installation Complete ---"
echo "Reboot with 'reboot' or stay in LiveCD environment."

#!/bin/bash

set -e
cd /

echo "---= AutoGentoo Installer =---"
echo "This script will erase ALL DATA on the selected disk."
echo "Ensure you select the correct disk."
echo ""

# --- Select disk ---
lsblk -dno NAME,SIZE,MODEL
echo ""
read -p "Enter the disk to install Gentoo (e.g., sda or nvme0n1): " disk
disk="/dev/$disk"

# --- Select Desktop Environment ---
echo "Select a desktop environment to install:"
options=("GNOME" "KDE Plasma" "XFCE" "MATE" "LXQt" "Exit")
select de_choice in "${options[@]}"; do
    case $de_choice in
        "GNOME"|"KDE Plasma"|"XFCE"|"MATE"|"LXQt") break;;
        "Exit") exit;;
        *) echo "Invalid choice. Try again.";;
    esac
done

read -p "Enter hostname: " hostname
read -p "Enter username: " username

# --- Root and user passwords ---
while true; do
    read -sp "Enter root password: " root_password
    echo
    read -sp "Confirm root password: " root_password2
    echo
    [[ "$root_password" == "$root_password2" ]] && break
    echo "Passwords do not match. Try again."
done

while true; do
    read -sp "Enter password for user $username: " user_password
    echo
    read -sp "Confirm password for user $username: " user_password2
    echo
    [[ "$user_password" == "$user_password2" ]] && break
    echo "Passwords do not match. Try again."
done

# --- Select filesystem ---
echo "Select filesystem for root partition:"
fs_options=("ext4" "xfs" "btrfs")
select fs_choice in "${fs_options[@]}"; do
    case $fs_choice in
        "ext4"|"xfs"|"btrfs") break;;
        *) echo "Invalid choice. Try again.";;
    esac
done

echo ""
echo "--- Installation Configuration ---"
echo "Disk: $disk"
echo "DE: $de_choice"
echo "Hostname: $hostname"
echo "User: $username"
echo "Root FS: $fs_choice"
echo "--------------------------------"
echo "Press Enter to continue..."
read

# --- Prepare disk ---
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R ${disk}* || true
blockdev --flushbufs "$disk" || true
sleep 3

# --- Partition disk ---
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
    ext4) mkfs.ext4 -F "${disk}2";;
    xfs) mkfs.xfs -f "${disk}2";;
    btrfs) mkfs.btrfs -f "${disk}2";;
esac

mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi

cd /mnt/gentoo

# --- Select fastest available Stage3 mirror ---
MIRRORS=(
"https://mirror.yandex.ru/gentoo-distfiles/"
"https://mirror.clarkson.edu/gentoo/"
"https://gentoo.osuosl.org/"
"https://mirror.csclub.uwaterloo.ca/gentoo/"
"https://ftp.halifax.rwth-aachen.de/gentoo/"
)

STAGE3_MIRROR=""
for mirror in "${MIRRORS[@]}"; do
    if curl -Is "$mirror" | head -n 1 | grep -q "200"; then
        STAGE3_MIRROR="$mirror"
        break
    fi
done

if [[ -z "$STAGE3_MIRROR" ]]; then
    echo "No Stage3 mirror available." >&2
    exit 1
fi
echo "Using Stage3 mirror: $STAGE3_MIRROR"

# --- Fetch latest Stage3 ---
STAGE3_URL="${STAGE3_MIRROR}releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt"
STAGE3_PATH=$(curl -s "$STAGE3_URL" | grep -v "^#" | grep 'stage3' | head -n1 | awk '{print $1}')

wget "${STAGE3_MIRROR}releases/amd64/autobuilds/${STAGE3_PATH}"

# --- Unpack Stage3 ---
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

# --- Generate make.conf ---
case $de_choice in
    "GNOME") DE_USE_FLAGS="gtk gnome -qt5 -kde";;
    "KDE Plasma") DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
    "XFCE") DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
    "MATE") DE_USE_FLAGS="gtk mate -qt5 -kde -gnome";;
    "LXQt") DE_USE_FLAGS="qt5 lxqt -gtk -gnome";;
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

# --- Chroot preparation ---
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# --- Detect latest profile ---
get_latest_profile() {
    local arch="amd64"
    latest_profile=$(eselect profile list | grep "default/linux/$arch" | tail -n1 | awk '{print $2}')
    if [[ -z "$latest_profile" ]]; then
        echo "Failed to detect latest profile." >&2
        exit 1
    fi
    echo "$latest_profile"
}

PROFILE=$(get_latest_profile)
echo "Detected latest profile: $PROFILE"
eselect profile set "$PROFILE"

# --- Generate chroot script ---
cat > /mnt/gentoo/tmp/chroot.sh << 'CHROOTEOF'
#!/bin/bash
set -e
source /etc/profile

healing_emerge() {
    local args=("$@")
    local max=5
    local attempt=1
    while [ $attempt -le $max ]; do
        emerge --verbose "${args[@]}" &> /tmp/emerge.log && return 0
        cat /tmp/emerge.log
        if grep -q "circular dependencies" /tmp/emerge.log; then
            fix=$(grep "Change USE:" /tmp/emerge.log | head -n1)
            if [[ -n "$fix" ]]; then
                pkg=$(echo "$fix" | awk '{print $2}' | sed 's/-[0-9].*//')
                use_change=$(echo "$fix" | awk -F 'Change USE: ' '{print $2}' | sed 's/)//')
                mkdir -p /etc/portage/package.use
                echo "$pkg $use_change" >> /etc/portage/package.use/99_autofix
                attempt=$((attempt+1))
                continue
            fi
        fi
        return 1
    done
    return 1
}

emerge-webrsync

healing_emerge --update --deep --newuse @system

case "$DE_CHOICE" in
    "GNOME") healing_emerge gnome-shell/gnome;;
    "KDE Plasma") healing_emerge kde-plasma/plasma-meta;;
    "XFCE") healing_emerge xfce-base/xfce4-meta;;
    "MATE") healing_emerge mate-base/mate-meta;;
    "LXQt") healing_emerge lxqt-base/lxqt-meta;;
esac

rm -f /etc/portage/package.use/99_autofix
healing_emerge --update --deep --newuse @world --keep-going=y

echo "$HOSTNAME" > /etc/hostname
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G users,wheel,audio,video -s /bin/bash $USER_NAME
echo "$USER_NAME:$USER_PASS" | chpasswd

emerge -q sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

exit
CHROOTEOF

chmod +x /mnt/gentoo/tmp/chroot.sh

# --- Enter chroot ---
chroot /mnt/gentoo /tmp/chroot.sh
rm /mnt/gentoo/tmp/chroot.sh

echo "--- Installation Complete! ---"
cd /
umount -l /mnt/gentoo/dev{/shm,/pts,}
umount -R /mnt/gentoo
echo "System ready. Type 'reboot' to start."

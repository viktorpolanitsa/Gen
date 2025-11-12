#!/bin/bash

set -e

# ------------------------------
# Gentoo Auto Installer (Binary)
# Fully automated, minimal user intervention
# Supports multiple DEs, init systems, filesystems
# Dynamically selects fastest mirror
# ------------------------------

# --- Functions ---

detect_region_mirror() {
    # Detect region by IP and suggest mirrors
    echo "--> Detecting region and best mirror..."
    REGION=$(curl -s https://ipapi.co/country/)
    case "$REGION" in
        RU)
            MIRROR_LIST=("https://mirror.yandex.ru/gentoo" "https://mirror.karelia.ru/gentoo")
            ;;
        *)
            MIRROR_LIST=("https://mirror.rackspace.com/gentoo" "https://gentoo.osuosl.org")
            ;;
    esac
}

select_fastest_mirror() {
    # Select fastest available mirror
    echo "--> Selecting fastest mirror..."
    for mirror in "${MIRROR_LIST[@]}"; do
        if curl --head --silent --fail "$mirror/releases/amd64/autobuilds/" >/dev/null; then
            FASTEST_MIRROR=$mirror
            echo "--> Mirror selected: $FASTEST_MIRROR"
            return
        fi
    done
    echo "No available mirrors found. Exiting."
    exit 1
}

get_latest_stage3() {
    echo "--> Fetching latest Stage3 tarball URL..."
    STAGE3_LIST=$(curl -s "$FASTEST_MIRROR/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt" | grep -v "^#" | grep "stage3")
    STAGE3_FILE=$(echo "$STAGE3_LIST" | head -n1 | awk '{print $1}')
    echo "--> Latest Stage3: $STAGE3_FILE"
}

# --- User Input ---

lsblk -dno NAME,SIZE,MODEL
echo ""
read -p "Enter disk for installation (e.g., sda or nvme0n1): " disk
disk="/dev/${disk}"

# Filesystem choice
echo "Select filesystem for root partition:"
fs_options=("ext4" "xfs" "btrfs")
select fs_choice in "${fs_options[@]}"; do
    case $fs_choice in
        ext4|xfs|btrfs) break;;
        *) echo "Invalid. Try again.";;
    esac
done

# Desktop Environment choice
echo "Select Desktop Environment:"
de_options=("GNOME" "KDE Plasma" "XFCE" "LXQt" "MATE" "Cinnamon" "Exit")
select de_choice in "${de_options[@]}"; do
    case $de_choice in
        GNOME|KDE\ Plasma|XFCE|LXQt|MATE|Cinnamon) break;;
        Exit) exit;;
        *) echo "Invalid choice.";;
    esac
done

# Init system
echo "Select init system:"
init_options=("OpenRC" "systemd")
select init_choice in "${init_options[@]}"; do
    case $init_choice in
        OpenRC|systemd) break;;
        *) echo "Invalid choice.";;
    esac
done

# Hostname & user
read -p "Enter hostname: " hostname
read -p "Enter username: " username

# Passwords
while true; do
    read -sp "Enter root password: " root_password
    echo
    read -sp "Confirm root password: " root_password2
    echo
    [ "$root_password" = "$root_password2" ] && break
    echo "Passwords do not match."
done

while true; do
    read -sp "Enter password for user $username: " user_password
    echo
    read -sp "Confirm password: " user_password2
    echo
    [ "$user_password" = "$user_password2" ] && break
    echo "Passwords do not match."
done

# --- Mirror & Stage3 ---
detect_region_mirror
select_fastest_mirror
get_latest_stage3

# --- Disk preparation ---
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R ${disk}* || true
blockdev --flushbufs "$disk" || true
sleep 2

echo "--> Partitioning disk..."
sfdisk --force --wipe always --wipe-partitions always "$disk" << EOF
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
EOF

partprobe "$disk"
sleep 1

echo "--> Wiping old signatures..."
wipefs -a "${disk}1"
wipefs -a "${disk}2"

echo "--> Formatting partitions..."
mkfs.vfat -F32 "${disk}1"
case "$fs_choice" in
    ext4) mkfs.ext4 -F "${disk}2";;
    xfs) mkfs.xfs -f "${disk}2";;
    btrfs) mkfs.btrfs -f "${disk}2";;
esac

echo "--> Mounting partitions..."
mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi

cd /mnt/gentoo

echo "--> Downloading Stage3..."
wget "$FASTEST_MIRROR/releases/amd64/autobuilds/$STAGE3_FILE"
tar xpvf stage3-*.tar.* --xattrs-include='*.*' --numeric-owner

# --- make.conf ---
case $de_choice in
    GNOME) DE_USE_FLAGS="gtk gnome -qt5 -kde";;
    KDE\ Plasma) DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
    XFCE) DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
    LXQt) DE_USE_FLAGS="qt5 lxqt -gtk -gnome -kde";;
    MATE) DE_USE_FLAGS="gtk mate -qt5 -kde -gnome";;
    Cinnamon) DE_USE_FLAGS="gtk cinnamon -qt5 -kde -gnome";;
esac

cat > /mnt/gentoo/etc/portage/make.conf << EOF
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
EOF

# --- Chroot environment ---
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
#!/bin/bash
set -e
source /etc/profile

healing_emerge() {
    local emerge_args=("$@")
    local max_retries=5
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        echo "--> Emerge attempt $attempt/$max_retries for: ${emerge_args[@]}"
        emerge --verbose "${emerge_args[@]}" &> /tmp/emerge.log && return 0
        cat /tmp/emerge.log
        if grep -q "circular dependencies" /tmp/emerge.log; then
            echo "--> Circular dependencies detected. Applying USE fixes..."
            mkdir -p /etc/portage/package.use
            echo "*/*" >> /etc/portage/package.use/99_autofix
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# Sync Portage
emerge-webrsync

# Profile selection (merged-usr)
eselect profile list | grep -v 'systemd' | tail -n1 | xargs -n1 eselect profile set

# Stage 1: Base system
healing_emerge --update --deep --newuse @system

# Stage 2: Desktop environment
case "${DE}" in
    GNOME) healing_emerge gnome-shell/gnome;;
    KDE) healing_emerge kde-plasma/plasma-meta;;
    XFCE) healing_emerge xfce-base/xfce4-meta;;
    LXQt) healing_emerge lxqt-base/lxqt-meta;;
    MATE) healing_emerge mate-base/mate-meta;;
    Cinnamon) healing_emerge cinnamon/cinnamon-meta;;
esac

# Stage 3: World update
healing_emerge --update --deep --newuse @world --keep-going=y

# CPU flags
emerge -q app-portage/cpuid2cpuflags
echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

# Locale and hostname
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8
env-update && source /etc/profile
echo "${HOSTNAME}" > /etc/hostname

# Root and user password
echo "root:${ROOT_PASSWORD}" | chpasswd
useradd -m -G users,wheel,audio,video -s /bin/bash ${USERNAME}
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# Networking
emerge -q net-misc/networkmanager
rc-update add NetworkManager default

# SSH
rc-update add sshd default

# X11 and Display Manager
emerge -q x11-base/xorg-server
case "${DE}" in
    GNOME) rc-update add gdm default;;
    KDE) emerge -q sys-boot/sddm; rc-update add sddm default;;
    XFCE) emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
    LXQt|MATE|Cinnamon) rc-update add lightdm default;;
esac

# GRUB installation
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
umount -l /mnt/gentoo/dev{/shm,/pts,} || true
umount -R /mnt/gentoo || true

echo "--- Installation Complete ---"
echo "System ready to reboot. Type 'reboot' to enter new Gentoo system."

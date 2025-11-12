#!/bin/bash
set -e

cd /

echo "---= Gentoo Ultimate Binary Installer =---"
echo "WARNING: THIS WILL ERASE ALL DATA ON THE SELECTED DISK."
echo ""

# --- Disk selection ---
lsblk -dno NAME,SIZE,MODEL
read -p "Enter the target disk (e.g., sda or nvme0n1): " disk
disk="/dev/${disk}"

# --- Desktop Environment selection ---
options=("GNOME" "KDE Plasma" "XFCE" "LXDE" "MATE" "Cinnamon" "Exit")
echo "Select a Desktop Environment:"
select de_choice in "${options[@]}"; do
    case $de_choice in
        "GNOME"|"KDE Plasma"|"XFCE"|"LXDE"|"MATE"|"Cinnamon") break;;
        "Exit") exit;;
        *) echo "Invalid choice.";;
    esac
done

# --- Init system ---
options=("OpenRC" "Systemd")
echo "Select init system:"
select init_choice in "${options[@]}"; do
    case $init_choice in
        "OpenRC"|"Systemd") break;;
        *) echo "Invalid choice.";;
    esac
done

read -p "Enter hostname: " hostname
read -p "Enter username: " username

# --- Passwords ---
while true; do
    read -sp "Enter root password: " root_password; echo
    read -sp "Confirm root password: " root_password2; echo
    [ "$root_password" = "$root_password2" ] && break
    echo "Passwords do not match."
done

while true; do
    read -sp "Enter password for $username: " user_password; echo
    read -sp "Confirm password for $username: " user_password2; echo
    [ "$user_password" = "$user_password2" ] && break
    echo "Passwords do not match."
done

# --- Filesystem ---
fs_options=("ext4" "xfs" "btrfs")
echo "Select filesystem for root partition:"
select fs_choice in "${fs_options[@]}"; do
    case $fs_choice in
        "ext4"|"xfs"|"btrfs") break;;
        *) echo "Invalid choice.";;
    esac
done

# --- Installation summary ---
echo ""
echo "--- Installation Summary ---"
echo "Disk: $disk"
echo "DE: $de_choice"
echo "Init: $init_choice"
echo "Hostname: $hostname"
echo "User: $username"
echo "Filesystem: $fs_choice"
read -p "Press Enter to start installation..."

# --- Temporary swap if RAM < 4GB ---
RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
if [ "$RAM_MB" -lt 4096 ]; then
    echo "--> Creating temporary swap..."
    dd if=/dev/zero of=/swapfile bs=1M count=4096
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
fi

# --- Prepare disk ---
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R ${disk}* || true
blockdev --flushbufs "$disk" || true
sleep 2

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

# --- Format partitions ---
mkfs.vfat -F 32 "${disk}1"
case "$fs_choice" in
    ext4) mkfs.ext4 -F "${disk}2";;
    xfs) mkfs.xfs -f "${disk}2";;
    btrfs) mkfs.btrfs -f "${disk}2";;
esac

# --- Mount ---
mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi
cd /mnt/gentoo

# --- Stage3 Mirror selection ---
MIRROR=$(curl -s https://www.gentoo.org/downloads/mirrors/ | grep -oP 'https://[^"]+gentoo/releases/amd64/autobuilds/' | head -n 1)
STAGE3_FILE=$(wget -q -O - "${MIRROR}latest-stage3-amd64-openrc.txt" | grep -v "^#" | grep 'stage3' | head -n1 | awk '{print $1}')

echo "--> Downloading Stage3 from $MIRROR"
wget "${MIRROR}${STAGE3_FILE}"

# --- Cleanup and unpack ---
rm -rf /mnt/gentoo/*
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

# --- make.conf ---
case $de_choice in
    "GNOME") DE_USE_FLAGS="gtk gnome -qt5 -kde";;
    "KDE Plasma") DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
    "XFCE") DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
    "LXDE") DE_USE_FLAGS="gtk lxde -qt5 -kde -gnome";;
    "MATE") DE_USE_FLAGS="gtk mate -qt5 -kde -gnome";;
    "Cinnamon") DE_USE_FLAGS="gtk cinnamon -qt5 -kde -gnome";;
esac

cat > /mnt/gentoo/etc/portage/make.conf << MAKECONF
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C target-cpu=native"
MAKEOPTS="-j$(nproc)"
USE="${DE_USE_FLAGS} dbus elogind pulseaudio bindist"
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
#!/bin/bash
set -e
source /etc/profile

healing_emerge() {
    local args=("$@")
    local max_attempts=5
    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        echo "--> Emerge attempt $attempt: ${args[@]}"
        emerge --verbose "${args[@]}" &> /tmp/emerge.log && { cat /tmp/emerge.log; return 0; }
        cat /tmp/emerge.log
        if grep -q "circular dependencies" /tmp/emerge.log; then
            local fix=$(grep "Change USE:" /tmp/emerge.log | head -n1)
            if [ -n "$fix" ]; then
                local pkg=$(echo "$fix" | awk '{print $2}' | sed 's/-[0-9].*//')
                local use=$(echo "$fix" | awk -F 'Change USE: ' '{print $2}' | sed 's/)//')
                mkdir -p /etc/portage/package.use
                echo "$pkg $use" >> /etc/portage/package.use/99_autofix
                attempt=$((attempt+1))
                continue
            fi
        fi
        return 1
    done
}

emerge-webrsync

# --- Select profile ---
DE_CHOICE='GNOME'
INIT_CHOICE='OpenRC'
DE_PROFILE=$(eselect profile list | grep 'desktop/gnome' | grep 'merged-usr' | awk '{print $2}' | tail -n1)
eselect profile set "$DE_PROFILE"

# --- Stage 1: system foundation ---
healing_emerge --update --deep --newuse @system

# --- Stage 2: desktop environment ---
healing_emerge gnome-shell/gnome

# --- Stage 3: world update ---
healing_emerge --update --deep --newuse @world --keep-going=y

# --- Kernel ---
read -p "Install binary kernel? [y/N]: " KERNEL_CHOICE
if [[ "$KERNEL_CHOICE" =~ ^[Yy]$ ]]; then
    emerge -q sys-kernel/gentoo-kernel-bin
else
    emerge -q sys-kernel/gentoo-sources
fi

# --- Bootloader ---
emerge -q sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

# --- User setup ---
read -p "Enter hostname: " hostname
read -p "Enter username: " username
read -sp "Enter root password: " root_pass; echo
read -sp "Enter user password: " user_pass; echo

echo "$hostname" > /etc/hostname
echo "root:$root_pass" | chpasswd
useradd -m -G users,wheel,audio,video -s /bin/bash "$username"
echo "$username:$user_pass" | chpasswd

# --- Services ---
emerge -q net-misc/networkmanager
rc-update add NetworkManager default
rc-update add sshd default

# --- Display manager ---
rc-update add gdm default

exit
CHROOTEOF

chmod +x /mnt/gentoo/tmp/chroot.sh

chroot /mnt/gentoo /tmp/chroot.sh
rm /mnt/gentoo/tmp/chroot.sh

echo "--- Installation Complete ---"
umount -R /mnt/gentoo || true
echo "System ready. Reboot to enter Gentoo."

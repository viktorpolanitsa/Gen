#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Initialization ---
cd /

echo "---= Autotoo: The Wise Gentoo Installer =---"
echo "This script will erase ALL DATA on the selected disk."
echo "Please ensure you have selected the correct one."
echo ""

# --- Select disk ---
lsblk -dno NAME,SIZE,MODEL
echo ""
read -p "Enter the disk name for installation (e.g., sda or nvme0n1): " disk
disk="/dev/${disk}"

# --- Select Desktop Environment (DE) ---
echo "Select a desktop environment to install:"
options=("GNOME" "KDE Plasma" "XFCE" "MATE" "LXQt" "Exit")
select de_choice in "${options[@]}"; do
    case $de_choice in
        "GNOME") break;;
        "KDE Plasma") break;;
        "XFCE") break;;
        "MATE") break;;
        "LXQt") break;;
        "Exit") exit;;
        *) echo "Invalid choice. Try again.";;
    esac
done

# --- Hostname and User ---
read -p "Enter hostname: " hostname
read -p "Enter username for the new user: " username

# --- Root password ---
while true; do
    read -sp "Enter root password: " root_password
    echo
    read -sp "Confirm root password: " root_password2
    echo
    [ "$root_password" = "$root_password2" ] && break
    echo "Passwords do not match. Try again."
done

# --- User password ---
while true; do
    read -sp "Enter password for user $username: " user_password
    echo
    read -sp "Confirm password for user $username: " user_password2
    echo
    [ "$user_password" = "$user_password2" ] && break
    echo "Passwords do not match. Try again."
done

echo ""
echo "--- Installation Configuration ---"
echo "Disk: $disk"
echo "Desktop Environment: $de_choice"
echo "Hostname: $hostname"
echo "User: $username"
echo "---------------------------------"
echo "Press Enter to begin or Ctrl+C to cancel."
read

# --- System Preparation ---
echo "--> Unmounting any existing mounts..."
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R ${disk}* || true
blockdev --flushbufs "$disk" || true
sleep 2

# --- Partitioning ---
echo "--> Partitioning disk $disk..."
sfdisk --force --wipe always --wipe-partitions always "$disk" << DISK_END
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
DISK_END

partprobe "$disk"
sleep 1

# --- Format partitions ---
wipefs -a "${disk}1"
wipefs -a "${disk}2"
mkfs.vfat -F 32 "${disk}1"
mkfs.xfs -f "${disk}2"

# --- Mount partitions ---
mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi

cd /mnt/gentoo

# --- Download Stage3 ---
STAGE3_PATH=$(wget -q -O - https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | grep -v "^#" | grep 'stage3' | head -n1 | cut -d' ' -f1)
wget "https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_PATH}"
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

# --- Generate make.conf ---
case $de_choice in
    "GNOME") DE_USE_FLAGS="gtk gnome -qt5 -kde";;
    "KDE Plasma") DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
    "XFCE") DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
    "MATE") DE_USE_FLAGS="gtk mate -qt5 -kde -gnome";;
    "LXQt") DE_USE_FLAGS="qt5 lxqt -gtk -kde -gnome";;
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

# --- Generate chroot script ---
cat > /mnt/gentoo/tmp/chroot.sh << 'CHROOTEOF'
#!/bin/bash
set -e
source /etc/profile

# --- Healing emerge function ---
healing_emerge() {
    local emerge_args=("$@")
    local max_retries=5
    local attempt=1
    while [ $attempt -le $max_retries ]; do
        emerge --verbose "${emerge_args[@]}" &> /tmp/emerge.log && { cat /tmp/emerge.log; return 0; }
        cat /tmp/emerge.log
        if grep -q "circular dependencies" /tmp/emerge.log; then
            fix=$(grep "Change USE:" /tmp/emerge.log | head -n1)
            if [ -n "$fix" ]; then
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

# --- Sync Portage ---
emerge-webrsync

# --- Profile selection ---
case "$DE_CHOICE" in
    "GNOME") PROFILE=$(eselect profile list | grep 'desktop/gnome' | grep 'merged-usr' | grep -v 'systemd' | awk '{print $2}' | tail -n1);;
    "KDE Plasma") PROFILE=$(eselect profile list | grep 'desktop/plasma' | grep 'merged-usr' | grep -v 'systemd' | awk '{print $2}' | tail -n1);;
    "XFCE") PROFILE=$(eselect profile list | grep 'desktop' | grep 'merged-usr' | grep -v 'gnome' | grep -v 'plasma' | grep -v 'systemd' | awk '{print $2}' | tail -n1);;
    "MATE") PROFILE=$(eselect profile list | grep 'desktop/mate' | grep 'merged-usr' | grep -v 'systemd' | awk '{print $2}' | tail -n1);;
    "LXQt") PROFILE=$(eselect profile list | grep 'desktop/lxqt' | grep 'merged-usr' | grep -v 'systemd' | awk '{print $2}' | tail -n1);;
esac

eselect profile set "$PROFILE"
ln -sf "$PROFILE" /etc/portage/make.profile

# --- System build ---
healing_emerge --update --deep --newuse @system

case "$DE_CHOICE" in
    "GNOME") healing_emerge gnome-base/gnome;;
    "KDE Plasma") healing_emerge kde-plasma/plasma-meta;;
    "XFCE") healing_emerge xfce-base/xfce4-meta;;
    "MATE") healing_emerge mate-base/mate-meta;;
    "LXQt") healing_emerge lxqt-meta/lxqt-meta;;
esac

# --- Final world update ---
healing_emerge --update --deep --newuse @world --keep-going=y

# --- Kernel ---
echo "sys-kernel/installkernel grub dracut" > /etc/portage/package.use/installkernel
healing_emerge sys-kernel/gentoo-kernel-bin

# --- Fstab and hostname ---
genfstab -U / > /etc/fstab
echo "$HOSTNAME" > /etc/hostname

# --- Set passwords ---
echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -G users,wheel,audio,video -s /bin/bash $USER_NAME
echo "$USER_NAME:$USER_PASSWORD" | chpasswd

# --- Base system ---
healing_emerge app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate

rc-update add sysklogd default
rc-update add chronyd default
rc-update add cronie default
rc-update add NetworkManager default
rc-update add sshd default

# --- Graphical subsystem ---
healing_emerge x11-base/xorg-server
case "$DE_CHOICE" in
    "GNOME") rc-update add gdm default;;
    "KDE Plasma") healing_emerge sys-boot/sddm; rc-update add sddm default;;
    "XFCE") healing_emerge x11-misc/lightdm x11-misc/lightdm-gtk-greeter; rc-update add lightdm default;;
    "MATE") healing_emerge x11-misc/lightdm x11-misc/lightdm-gtk-greeter; rc-update add lightdm default;;
    "LXQt") healing_emerge x11-misc/sddm; rc-update add sddm default;;
esac

# --- Bootloader ---
healing_emerge sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

exit
CHROOTEOF

chmod +x /mnt/gentoo/tmp/chroot.sh

# --- Enter chroot and run ---
DE_CHOICE="$de_choice"
HOSTNAME="$hostname"
USER_NAME="$username"
ROOT_PASSWORD="$root_password"
USER_PASSWORD="$user_password"

chroot /mnt/gentoo /tmp/chroot.sh
rm /mnt/gentoo/tmp/chroot.sh

# --- Finish ---
echo "--- Installation Complete! ---"
umount -l /mnt/gentoo/dev{/shm,/pts,}
umount -R /mnt/gentoo

echo "System ready. Type 'reboot' to start your new Gentoo system."

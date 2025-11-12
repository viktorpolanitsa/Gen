#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- Initial Setup ---
cd /

echo "---= Autotoo: The Wise Gentoo Installer =---"
echo "WARNING: This script will erase ALL DATA on the selected disk."
echo "Ensure the correct disk is selected before proceeding."
echo ""

# --- Disk Selection ---
lsblk -dno NAME,SIZE,MODEL
echo ""
read -p "Enter the disk for installation (e.g., sda or nvme0n1): " disk
disk="/dev/${disk}"

# --- Desktop Environment Selection ---
echo "Select a desktop environment to install:"
options=("GNOME" "KDE Plasma" "XFCE" "LXQt" "MATE" "Exit")
select de_choice in "${options[@]}"; do
    case $de_choice in
        "GNOME") break;;
        "KDE Plasma") break;;
        "XFCE") break;;
        "LXQt") break;;
        "MATE") break;;
        "Exit") exit;;
        *) echo "Invalid choice. Please try again.";;
    esac
done

# --- Hostname and User ---
read -p "Enter hostname: " hostname
read -p "Enter username for the new user: " username

# --- Passwords ---
while true; do
    read -sp "Enter root password: " root_password
    echo
    read -sp "Confirm root password: " root_password2
    echo
    [ "$root_password" = "$root_password2" ] && break
    echo "Passwords do not match. Try again."
done

while true; do
    read -sp "Enter password for user $username: " user_password
    echo
    read -sp "Confirm password for user $username: " user_password2
    echo
    [ "$user_password" = "$user_password2" ] && break
    echo "Passwords do not match. Try again."
done

echo ""
echo "---= Installation Configuration =---"
echo "Disk: $disk"
echo "Desktop Environment: $de_choice"
echo "Hostname: $hostname"
echo "User: $username"
echo "------------------------------------"
echo "Press Enter to begin installation or Ctrl+C to cancel."
read

# --- Phase 1: System Preparation ---
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R ${disk}* || true
blockdev --flushbufs "$disk" || true
sleep 3

echo "--> Partitioning disk $disk..."
sfdisk --force --wipe always --wipe-partitions always "$disk" << DISKCFG
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
DISKCFG

partprobe "$disk"
sleep 1

wipefs -a "${disk}1"
wipefs -a "${disk}2"

echo "--> Formatting partitions..."
mkfs.vfat -F 32 "${disk}1"
mkfs.xfs -f "${disk}2"

mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi

cd /mnt/gentoo

echo "--> Downloading latest Stage3 tarball..."
STAGE3_PATH=$(wget -q -O - https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt \
    | grep -v "^#" | grep 'stage3' | head -n1 | cut -d' ' -f1)
wget "https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_PATH}"

echo "--> Extracting Stage3..."
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

# --- make.conf Setup ---
case $de_choice in
    "GNOME") DE_USE_FLAGS="gtk gnome -qt5 -kde";;
    "KDE Plasma") DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
    "XFCE") DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
    "LXQt") DE_USE_FLAGS="lxqt qt5 -gnome -kde";;
    "MATE") DE_USE_FLAGS="gtk mate -qt5 -kde -gnome";;
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

# --- Prepare chroot environment ---
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# --- Generate chroot script ---
cat > /mnt/gentoo/tmp/chroot.sh << CHROOTEOF
#!/bin/bash
set -e
source /etc/profile

# --- Emergence helper ---
healing_emerge() {
    local args=(\$@)
    local max_retries=5
    local attempt=1
    while [ \$attempt -le \$max_retries ]; do
        emerge --verbose "\${args[@]}" &> /tmp/emerge.log && return 0
        if grep -q "circular dependencies" /tmp/emerge.log; then
            # Attempt automatic fix
            local fix=\$(grep "Change USE:" /tmp/emerge.log | head -n1)
            if [ -n "\$fix" ]; then
                local pkg=\$(echo "\$fix" | awk '{print \$2}' | sed 's/-[0-9].*//')
                local use_change=\$(echo "\$fix" | awk -F 'Change USE: ' '{print \$2}' | sed 's/)//')
                mkdir -p /etc/portage/package.use
                echo "\$pkg \$use_change" >> /etc/portage/package.use/99_autofix
                attempt=\$((attempt + 1))
                continue
            fi
        fi
        attempt=\$((attempt + 1))
    done
    return 1
}

emerge-webrsync

# --- Profile selection dynamically ---
DE_PROFILE=\$(eselect profile list | awk -v de="$de_choice" '/desktop/ && \$0 ~ de && \$0 !~ /systemd/ {gsub(/^[0-9]+:/,""); print \$1}' | tail -n1)
eselect profile set "\$DE_PROFILE"

# --- Stage 1: System foundation ---
healing_emerge --update --deep --newuse @system

# --- Stage 2: Desktop Environment ---
case "$de_choice" in
    "GNOME") healing_emerge gnome-shell/gnome;;
    "KDE Plasma") healing_emerge kde-plasma/plasma-meta;;
    "XFCE") healing_emerge xfce-base/xfce4-meta;;
    "LXQt") healing_emerge lxqt-base/lxqt-meta;;
    "MATE") healing_emerge mate-base/mate-meta;;
esac

rm -f /etc/portage/package.use/99_autofix

# --- Stage 3: Final update ---
healing_emerge --update --deep --newuse @world --keep-going=y

# --- CPU Flags ---
emerge -q app-portage/cpuid2cpuflags
echo "*/* \$(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

# --- Locale ---
grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8
env-update && source /etc/profile

# --- Kernel ---
emerge -q sys-kernel/gentoo-kernel-bin || emerge sys-kernel/gentoo-sources

# --- Fstab ---
emerge -q sys-fs/genfstab
genfstab -U / > /etc/fstab

# --- Hostname ---
echo "$hostname" > /etc/hostname

# --- Root password ---
echo "root:$root_password" | chpasswd

# --- Base utilities ---
emerge -q app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate
rc-update add sysklogd default
rc-update add chronyd default
rc-update add cronie default

# --- Networking ---
emerge -q net-misc/networkmanager
rc-update add NetworkManager default

# --- SSH ---
rc-update add sshd default

# --- X11 and Display Manager ---
emerge -q x11-base/xorg-server
case "$de_choice" in
    "GNOME") rc-update add gdm default;;
    "KDE Plasma") emerge -q sys-boot/sddm; rc-update add sddm default;;
    "XFCE"|"LXQt"|"MATE") emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
esac

# --- Create user ---
useradd -m -G users,wheel,audio,video -s /bin/bash "$username"
echo "$username:$user_password" | chpasswd

# --- GRUB ---
emerge -q sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

echo "--> Chroot installation complete."
exit
CHROOTEOF

chmod +x /mnt/gentoo/tmp/chroot.sh

# --- Phase 2: Enter chroot ---
chroot /mnt/gentoo /tmp/chroot.sh
rm /mnt/gentoo/tmp/chroot.sh

echo "--- Installation Complete! ---"
echo "--> Unmounting filesystems..."
cd /
umount -l /mnt/gentoo/dev{/shm,/pts,} || true
umount -lR /mnt/gentoo || true

echo "The system is ready to reboot. Type 'reboot' to enter your new Gentoo system."
echo "Press Ctrl+C to remain in the LiveCD environment."

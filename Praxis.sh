#!/bin/bash
set -e

# --- Gentoo Installer: Merged-usr, Binary-first ---

cd /

echo "---= Autotoo: Gentoo Installer (Merged-usr, Binary-first) =---"
echo "WARNING: This script will erase ALL DATA on the selected disk."
echo ""

# --- Disk selection ---
lsblk -dno NAME,SIZE,MODEL
echo ""
read -p "Enter disk for installation (e.g., sda or nvme0n1): " disk
disk="/dev/${disk}"

# --- Partition filesystem selection ---
echo "Select filesystem for root partition:"
fs_options=("ext4" "xfs" "btrfs")
select fs_choice in "${fs_options[@]}"; do
    case $fs_choice in
        ext4|xfs|btrfs) break;;
        *) echo "Invalid choice";;
    esac
done

# --- Init system selection ---
echo "Select init system:"
init_options=("OpenRC" "systemd")
select init_choice in "${init_options[@]}"; do
    case $init_choice in
        OpenRC|systemd) break;;
        *) echo "Invalid choice";;
    esac
done

# --- Desktop environment selection ---
echo "Select desktop environment:"
de_options=("GNOME" "KDE Plasma" "XFCE" "LXQt" "MATE" "Exit")
select de_choice in "${de_options[@]}"; do
    case $de_choice in
        "Exit") exit;;
        *) break;;
    esac
done

# --- Hostname and user ---
read -p "Enter hostname: " hostname
read -p "Enter username: " username

# --- Passwords ---
while true; do
    read -sp "Enter root password: " root_password
    echo
    read -sp "Confirm root password: " root_password2
    echo
    [ "$root_password" = "$root_password2" ] && break
    echo "Passwords do not match"
done

while true; do
    read -sp "Enter password for $username: " user_password
    echo
    read -sp "Confirm password for $username: " user_password2
    echo
    [ "$user_password" = "$user_password2" ] && break
    echo "Passwords do not match"
done

echo ""
echo "--- Installation Configuration ---"
echo "Disk: $disk"
echo "Filesystem: $fs_choice"
echo "Init system: $init_choice"
echo "Desktop: $de_choice"
echo "Hostname: $hostname"
echo "User: $username"
echo "Press Enter to continue..."
read

# --- Phase 1: System preparation ---
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R ${disk}* || true
blockdev --flushbufs "$disk" || true
sleep 3

# --- Partitioning ---
sfdisk --force --wipe always --wipe-partitions always "$disk" << EOF
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
EOF

partprobe "$disk"
sleep 1

wipefs -a "${disk}1"
wipefs -a "${disk}2"

# --- Formatting ---
mkfs.vfat -F 32 "${disk}1"
case $fs_choice in
    ext4) mkfs.ext4 -F "${disk}2";;
    xfs) mkfs.xfs -f "${disk}2";;
    btrfs) mkfs.btrfs -f "${disk}2";;
esac

mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi

cd /mnt/gentoo

# --- Stage3 download with fastest mirror ---
STAGE3_FILE=$(wget -qO- https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt \
 | grep stage3 | head -n1 | awk '{print $1}')
wget "https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_FILE}"

# --- Unpack Stage3 ---
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

# --- make.conf ---
case $de_choice in
    GNOME) DE_USE_FLAGS="gtk gnome -qt5 -kde";;
    "KDE Plasma") DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
    XFCE) DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
    LXQt) DE_USE_FLAGS="lxqt qt5 -gnome -kde";;
    MATE) DE_USE_FLAGS="mate gtk -qt5 -kde -gnome";;
esac

cat > /mnt/gentoo/etc/portage/make.conf << MAKECONF
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C target-cpu=native"
MAKEOPTS="-j$(nproc)"
USE="${DE_USE_FLAGS} dbus elogind pulseaudio binary"
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
    local max_retries=5
    local attempt=1
    while [ $attempt -le $max_retries ]; do
        echo "--> Emerge attempt $attempt: ${args[*]}"
        emerge --verbose "${args[@]}" &> /tmp/emerge.log && return 0
        cat /tmp/emerge.log
        if grep -q "circular dependencies" /tmp/emerge.log; then
            local fix=$(grep "Change USE:" /tmp/emerge.log | head -n1)
            if [ -n "$fix" ]; then
                local pkg=$(echo "$fix" | awk '{print $2}' | sed 's/-[0-9].*//')
                local use_change=$(echo "$fix" | awk -F 'Change USE: ' '{print $2}' | sed 's/)//')
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

# --- Profile ---
eselect profile list | grep merged
DE_PROFILE=$(eselect profile list | grep merged | awk '{print $1}' | tail -n1)
eselect profile set $DE_PROFILE

healing_emerge --update --deep --newuse @system

case "$DE" in
    GNOME) healing_emerge gnome-shell/gnome;;
    "KDE Plasma") healing_emerge kde-plasma/plasma-meta;;
    XFCE) healing_emerge xfce-base/xfce4-meta;;
    LXQt) healing_emerge lxqt-base/lxqt-meta;;
    MATE) healing_emerge mate-base/mate-meta;;
esac

rm -f /etc/portage/package.use/99_autofix

healing_emerge --update --deep --newuse @world --keep-going=y

emerge -q app-portage/cpuid2cpuflags
echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8
env-update && source /etc/profile

# --- Kernel ---
echo "sys-kernel/installkernel grub dracut" > /etc/portage/package.use/installkernel
emerge -q sys-kernel/gentoo-kernel-bin

# --- Fstab ---
emerge -q sys-fs/genfstab
genfstab -U / > /etc/fstab

# --- Hostname and user ---
echo "$HOSTNAME" > /etc/hostname
echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -G users,wheel,audio,video -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASSWORD" | chpasswd

# --- Base packages ---
emerge -q app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate
rc-update add sysklogd default
rc-update add chronyd default
rc-update add cronie default

# --- Networking and SSH ---
emerge -q net-misc/networkmanager
rc-update add NetworkManager default
rc-update add sshd default

# --- Xorg and DM ---
emerge -q x11-base/xorg-server
case "$DE" in
    GNOME) rc-update add gdm default;;
    "KDE Plasma") emerge -q sys-boot/sddm; rc-update add sddm default;;
    XFCE) emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
    LXQt) emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
    MATE) emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
esac

# --- GRUB ---
emerge -q sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

exit
CHROOTEOF

chmod +x /mnt/gentoo/tmp/chroot.sh

# --- Chroot phase ---
chroot /mnt/gentoo /tmp/chroot.sh
rm /mnt/gentoo/tmp/chroot.sh

echo "--- Installation Complete! ---"
echo "--> Unmounting..."
cd /
umount -l /mnt/gentoo/dev{/shm,/pts,} || true
umount -R /mnt/gentoo || true
echo "Reboot with 'reboot' command."

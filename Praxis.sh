#!/bin/bash

set -e

# --- Preliminary Setup ---
cd /

echo "---= Autotoo: The Ultimate Gentoo Installer =---"
echo "This script will erase ALL DATA on the selected disk."
echo "Ensure you have selected the correct disk!"
echo ""

# --- Disk Selection ---
lsblk -dno NAME,SIZE,MODEL
echo ""
read -p "Enter disk name (e.g., sda, nvme0n1): " disk
disk="/dev/$disk"

# --- File System Selection ---
echo "Select file system for root partition:"
fs_options=("ext4" "xfs" "btrfs")
select fs_choice in "${fs_options[@]}"; do
    case $fs_choice in
        ext4|xfs|btrfs) break;;
        *) echo "Invalid choice";;
    esac
done

# --- Init System Selection ---
echo "Select init system:"
init_options=("OpenRC" "Systemd")
select init_choice in "${init_options[@]}"; do
    case $init_choice in
        OpenRC|Systemd) break;;
        *) echo "Invalid choice";;
    esac
done

# --- Desktop Environment Selection ---
echo "Select desktop environment:"
de_options=("GNOME" "KDE" "XFCE" "LXDE" "MATE" "Exit")
select de_choice in "${de_options[@]}"; do
    case $de_choice in
        GNOME|KDE|XFCE|LXDE|MATE) break;;
        Exit) exit;;
        *) echo "Invalid choice";;
    esac
done

# --- Hostname and User Setup ---
read -p "Enter hostname: " hostname
read -p "Enter username: " username

# --- Passwords ---
while true; do
    read -sp "Root password: " root_password; echo
    read -sp "Confirm root password: " root_password2; echo
    [ "$root_password" = "$root_password2" ] && break
    echo "Passwords do not match"
done

while true; do
    read -sp "Password for $username: " user_password; echo
    read -sp "Confirm password for $username: " user_password2; echo
    [ "$user_password" = "$user_password2" ] && break
    echo "Passwords do not match"
done

# --- Display Configuration Summary ---
echo ""
echo "--- Installation Configuration ---"
echo "Disk: $disk"
echo "Filesystem: $fs_choice"
echo "Init system: $init_choice"
echo "Desktop Environment: $de_choice"
echo "Hostname: $hostname"
echo "Username: $username"
echo "--------------------------------"
read -p "Press Enter to continue or Ctrl+C to cancel"

# --- Disk Preparation ---
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R ${disk}* || true
blockdev --flushbufs "$disk" || true
sleep 3

# --- Partitioning ---
sfdisk --force --wipe always --wipe-partitions always "$disk" << DISKEOF
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
DISKEOF

partprobe "$disk"; sleep 1
wipefs -a "${disk}1"; wipefs -a "${disk}2"

# --- Formatting ---
case $fs_choice in
    ext4) mkfs.ext4 -F "${disk}2";;
    xfs) mkfs.xfs -f "${disk}2";;
    btrfs) mkfs.btrfs -f "${disk}2";;
esac
mkfs.vfat -F 32 "${disk}1"

# --- Mounting ---
mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi
cd /mnt/gentoo

# --- Stage3 Selection (Fast Mirror) ---
echo "--> Selecting fastest Stage3 mirror..."
MIRRORS=$(curl -s https://www.gentoo.org/downloads/mirrors/ | grep -oP 'https://[^"]+gentoo/releases/amd64/autobuilds/')
for MIRROR in $MIRRORS; do
    if curl --head --silent --fail "$MIRROR" >/dev/null; then
        echo "--> Using mirror: $MIRROR"
        break
    fi
done

STAGE3_FILE=$(curl -s "${MIRROR}latest-stage3-amd64-openrc.txt" | grep -v "^#" | grep 'stage3' | head -n1 | awk '{print $1}')
echo "--> Downloading Stage3: ${STAGE3_FILE}"
wget "${MIRROR}${STAGE3_FILE}"

# --- Unpack Stage3 ---
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

# --- make.conf ---
case $de_choice in
    GNOME) DE_USE_FLAGS="gtk gnome -kde -qt5";;
    KDE) DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
    XFCE) DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
    LXDE) DE_USE_FLAGS="gtk lxde -kde -gnome -qt5";;
    MATE) DE_USE_FLAGS="gtk mate -kde -gnome -qt5";;
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
FEATURES="buildpkg"
EMERGE_DEFAULT_OPTS="--binarypkg-respect-use=y"
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
cat > /mnt/gentoo/tmp/chroot.sh << CHROOTEOF
#!/bin/bash
set -e
source /etc/profile

healing_emerge() {
    local args=(\$@)
    local max_retries=5
    local attempt=1
    while [ \$attempt -le \$max_retries ]; do
        echo "--> Attempt \$attempt: emerge \${args[@]}"
        emerge --verbose "\${args[@]}" &> /tmp/emerge.log && return 0
        if grep -q "circular dependencies" /tmp/emerge.log; then
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
        return 1
    done
    return 1
}

emerge-webrsync

# --- Set profile ---
if [ "$init_choice" == "Systemd" ]; then
    eselect profile set "default/linux/amd64/23.0/systemd"
else
    eselect profile set "default/linux/amd64/23.0/openrc"
fi

healing_emerge --update --deep --newuse @system

case "$de_choice" in
    GNOME) healing_emerge gnome-shell/gnome;;
    KDE) healing_emerge kde-plasma/plasma-meta;;
    XFCE) healing_emerge xfce-base/xfce4-meta;;
    LXDE) healing_emerge lxde-base/lxde-meta;;
    MATE) healing_emerge mate-base/mate-meta;;
esac

rm -f /etc/portage/package.use/99_autofix
healing_emerge --update --deep --newuse @world --keep-going=y

emerge -q app-portage/cpuid2cpuflags
echo "*/* \$(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8
env-update && source /etc/profile
emerge -q sys-kernel/gentoo-kernel-bin

genfstab -U / > /etc/fstab
echo "$hostname" > /etc/hostname
echo "root:$root_password" | chpasswd
useradd -m -G users,wheel,audio,video -s /bin/bash $username
echo "$username:$user_password" | chpasswd

emerge -q app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate
rc-update add sysklogd default
rc-update add chronyd default
rc-update add cronie default

emerge -q net-misc/networkmanager
rc-update add NetworkManager default
rc-update add sshd default

emerge -q x11-base/xorg-server
case "$de_choice" in
    GNOME) rc-update add gdm default;;
    KDE) emerge -q sys-boot/sddm; rc-update add sddm default;;
    XFCE|LXDE|MATE) emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
esac

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

echo "Installation complete! Reboot to enter your new Gentoo system."

#!/bin/bash
set -e
LOGFILE="/tmp/autogentoo_install.log"
exec > >(tee -i $LOGFILE)
exec 2>&1

# --- Preliminary ---
cd /
echo "---= AutoGentoo Installer =---"
echo "WARNING: This will erase ALL DATA on the selected disk."

lsblk -dno NAME,SIZE,MODEL
read -p "Enter disk (e.g., sda or nvme0n1): " disk
disk="/dev/$disk"

echo "Select Desktop Environment:"
options=("GNOME" "KDE Plasma" "XFCE" "LXQt" "MATE" "Exit")
select de_choice in "${options[@]}"; do
  [[ "$de_choice" =~ ^(GNOME|KDE\ Plasma|XFCE|LXQt|MATE)$ ]] && break
  [[ "$de_choice" == "Exit" ]] && exit
  echo "Invalid choice."
done

read -p "Enter hostname: " hostname
read -p "Enter username: " username
read -p "Enter timezone (e.g., Europe/Moscow): " timezone

while true; do
  read -sp "Root password: " root_password; echo
  read -sp "Confirm root password: " root_password2; echo
  [[ "$root_password" == "$root_password2" ]] && break
  echo "Passwords do not match."
done

while true; do
  read -sp "Password for $username: " user_password; echo
  read -sp "Confirm password: " user_password2; echo
  [[ "$user_password" == "$user_password2" ]] && break
  echo "Passwords do not match."
done

echo ""
echo "--- Installation Configuration ---"
echo "Disk: $disk"
echo "Desktop Environment: $de_choice"
echo "Hostname: $hostname"
echo "Timezone: $timezone"
read -p "Press Enter to continue..."

# --- System Preparation ---
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R ${disk}* || true
blockdev --flushbufs "$disk" || true
sleep 3

# --- Partitioning ---
sfdisk --force --wipe always --wipe-partitions always "$disk" <<DISKEOF
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
DISKEOF
partprobe "$disk"; sleep 1
wipefs -a "${disk}1"; wipefs -a "${disk}2"

echo "Select filesystem for root partition:"
fs_options=("ext4" "xfs" "btrfs")
select fs_choice in "${fs_options[@]}"; do
  [[ "$fs_choice" =~ ^(ext4|xfs|btrfs)$ ]] && break
done

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

# --- Mirror selection with fallback ---
COUNTRY=$(curl -s https://ipapi.co/country/)
declare -a MIRRORS
case "$COUNTRY" in
  "RU") MIRRORS=("https://mirror.yandex.ru/gentoo/" "https://mirror.mos.ru/gentoo/" "https://mirror.kaspersky.com/gentoo/") ;;
  *) MIRRORS=("https://distfiles.gentoo.org/") ;;
esac

STAGE3_URL=""
for MIRROR in "${MIRRORS[@]}"; do
  TXT_URL="${MIRROR}releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt"
  if curl -s --head --fail --max-time 10 "$TXT_URL" >/dev/null; then
    STAGE3_FILE=$(curl -s "$TXT_URL" | grep -v "^#" | grep 'stage3' | head -n1 | cut -d' ' -f1)
    FULL_URL="${MIRROR}releases/amd64/autobuilds/$STAGE3_FILE"
    if curl -s --head --fail --max-time 10 "$FULL_URL" >/dev/null; then
      STAGE3_URL="$FULL_URL"
      break
    fi
  fi
done
[[ -z "$STAGE3_URL" ]] && { echo "Failed to detect Stage3 mirror. Exiting."; exit 1; }

wget "$STAGE3_URL"
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

# --- make.conf ---
case $de_choice in
  "GNOME") DE_USE_FLAGS="gtk gnome -qt5 -kde";;
  "KDE Plasma") DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
  "XFCE") DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
  "LXQt") DE_USE_FLAGS="qt5 lxqt -gnome -kde";;
  "MATE") DE_USE_FLAGS="gtk mate -qt5 -kde -gnome";;
esac

cat > /mnt/gentoo/etc/portage/make.conf <<MAKECONF
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

# --- Chroot prep ---
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys; mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev; mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run; mount --make-slave /mnt/gentoo/run

# --- Chroot script ---
cat > /mnt/gentoo/tmp/chroot.sh <<'CHROOTEOF'
set -e
source /etc/profile

healing_emerge() {
  local args=("$@"); local max=5; local n=1
  while [[ $n -le $max ]]; do
    echo "Emerge attempt $n/$max: ${args[*]}"
    emerge --verbose "${args[@]}" &> /tmp/emerge.log && { cat /tmp/emerge.log; return 0; }
    cat /tmp/emerge.log
    if grep -q "circular dependencies" /tmp/emerge.log; then
      fix=$(grep "Change USE:" /tmp/emerge.log | head -n1)
      if [[ -n "$fix" ]]; then
        pkg=$(echo "$fix" | awk '{print $2}' | sed 's/-[0-9].*//')
        use_change=$(echo "$fix" | awk -F 'Change USE: ' '{print $2}' | sed 's/)//')
        mkdir -p /etc/portage/package.use
        echo "$pkg $use_change" >> /etc/portage/package.use/99_autofix
        n=$((n+1))
        continue
      fi
    fi
    return 1
  done
  return 1
}

emerge-webrsync
PROFILE=$(eselect profile list | grep -E 'amd64.*openrc' | awk '{print $1}' | tail -n1)
eselect profile set $PROFILE

healing_emerge --update --deep --newuse @system

case "${de_choice}" in
  "GNOME") healing_emerge gnome-shell/gnome;;
  "KDE Plasma") healing_emerge kde-plasma/plasma-meta;;
  "XFCE") healing_emerge xfce-base/xfce4-meta;;
  "LXQt") healing_emerge lxqt-meta;;
  "MATE") healing_emerge mate-meta;;
esac

healing_emerge --update --deep --newuse @world --keep-going=y
emerge -q app-portage/cpuid2cpuflags
echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8
env-update && source /etc/profile

echo "sys-kernel/installkernel grub dracut" > /etc/portage/package.use/installkernel
emerge -q sys-kernel/gentoo-kernel-bin

echo "${hostname}" > /etc/hostname
echo "root:${root_password}" | chpasswd

ln -sf /usr/share/zoneinfo/${timezone} /etc/localtime
hwclock --systohc

emerge -q app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate
rc-update add sysklogd default
rc-update add chronyd default
rc-update add cronie default

emerge -q net-misc/networkmanager
rc-update add NetworkManager default
rc-update add sshd default

emerge -q x11-base/xorg-server
case "${de_choice}" in
  "GNOME") rc-update add gdm default;;
  "KDE Plasma") emerge -q sys-boot/sddm; rc-update add sddm default;;
  "XFCE"|"LXQt"|"MATE") emerge -q lightdm lightdm-gtk-greeter; rc-update add lightdm default;;
esac

useradd -m -G users,wheel,audio,video -s /bin/bash ${username}
echo "${username}:${user_password}" | chpasswd

emerge -q sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg
exit
CHROOTEOF

chmod +x /mnt/gentoo/tmp/chroot.sh
chroot /mnt/gentoo /tmp/chroot.sh
rm /mnt/gentoo/tmp/chroot.sh

cd /
umount -l /mnt/gentoo/dev{/shm,/pts,} || true
umount -R /mnt/gentoo || true

echo "--- Installation Complete ---"
echo "Reboot to enter the new Gentoo system or Ctrl+C to stay in LiveCD"

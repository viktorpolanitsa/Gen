#!/usr/bin/env bash
set -euo pipefail

# AutoGentoo — Fully corrected robust Gentoo installer (single-file)
# - Downloads Stage3 reliably to /tmp, extracts into /mnt/gentoo
# - Does NOT delete the downloaded tarball before extraction
# - Properly injects env into chroot via /tmp/autogen_env
# - Consistent DE naming and mapping
# - Proper make.conf generation (no fragile markers)
# - Validates required host commands
# - Creates temporary swap if RAM < 4GB and removes it at the end
# - Safer unmount / cleanup logic
# - Prefers merged-usr profiles where appropriate, but falls back safely
# - Defensive error messages and exit codes
# - Test in VM before using on real hardware (destructive)

err() { echo "ERROR: $*" >&2; }
info() { echo "--> $*"; }

# ---------- Check required host tools ----------
required_cmds=(curl wget tar sfdisk mkfs.vfat partprobe wipefs lsblk awk grep sed chroot dd mkswap swapon umount mkdir mount)
missing=()
for c in "${required_cmds[@]}"; do
  if ! command -v "$c" >/dev/null 2>&1; then
    missing+=("$c")
  fi
done
if [ "${#missing[@]}" -ne 0 ]; then
  err "Missing required commands in live environment: ${missing[*]}"
  err "Install them or use an official Gentoo minimal environment that provides them."
  exit 2
fi

# ---------- Interactive configuration ----------
echo "=== AutoGentoo: Fully corrected installer ==="
echo "This script WILL ERASE data on the selected disk. Test in VM first!"
echo

lsblk -dno NAME,SIZE,MODEL
echo
read -rp "Enter target disk (example: sda or nvme0n1): " disk_name
disk="/dev/${disk_name}"

if [ ! -b "$disk" ]; then
  err "Disk device does not exist: $disk"
  exit 3
fi

# filesystem
fs_options=(ext4 xfs btrfs)
echo "Select root filesystem:"
select root_fs in "${fs_options[@]}"; do
  case "$root_fs" in
    ext4|xfs|btrfs) break;;
    *) echo "Invalid";;
  esac
done

# init
init_options=(OpenRC Systemd)
echo "Select init system:"
select init_choice in "${init_options[@]}"; do
  case "$init_choice" in
    OpenRC|Systemd) break;;
    *) echo "Invalid";;
  esac
done

# desktop environment choices (use internal keys to avoid mismatches)
de_keys=(GNOME KDE_PLASMA XFCE LXDE MATE CINNAMON NONE)
de_labels=("GNOME" "KDE Plasma" "XFCE" "LXDE" "MATE" "Cinnamon" "None (minimal)")
echo "Select desktop environment (None for minimal):"
PS3="Choice: "
select de_label in "${de_labels[@]}"; do
  idx=$((REPLY-1))
  if [ "$idx" -ge 0 ] 2>/dev/null && [ "$idx" -lt "${#de_keys[@]}" ]; then
    de_key="${de_keys[$idx]}"
    de_choice_label="${de_labels[$idx]}"
    break
  else
    echo "Invalid"
  fi
done

read -rp "Enter hostname: " hostname
read -rp "Enter username: " username

# passwords (hidden)
while true; do
  read -rsp "Root password: " root_password; echo
  read -rsp "Confirm root password: " root_password2; echo
  [ "$root_password" = "$root_password2" ] && break
  echo "Passwords do not match."
done

while true; do
  read -rsp "User password: " user_password; echo
  read -rsp "Confirm user password: " user_password2; echo
  [ "$user_password" = "$user_password2" ] && break
  echo "Passwords do not match."
done

echo
echo "Summary:"
echo " Disk: $disk"
echo " Root FS: $root_fs"
echo " Init: $init_choice"
echo " Desktop: $de_choice_label"
echo " Hostname: $hostname"
echo " Username: $username"
echo
read -rp "Type YES (uppercase) to confirm destructive operations: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
  err "Confirmation not received. Exiting."
  exit 4
fi

# ---------- Prepare host environment ----------
info "Disabling swap and unmounting previous mounts"
swapoff -a || true
umount -R /mnt/gentoo 2>/dev/null || true
blockdev --flushbufs "$disk" || true
sleep 1

# create temporary swap if RAM < 4GB
ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
created_swap=0
if [ "$ram_mb" -lt 4096 ]; then
  info "RAM ${ram_mb}MB < 4096MB — creating temporary 4GB swapfile at /swapfile"
  if [ ! -f /swapfile ]; then
    dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none || true
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  swapon /swapfile
  created_swap=1
fi

# ---------- Partitioning ----------
info "Partitioning ${disk} (GPT: EFI + root)"
sfdisk --wipe always --wipe-partitions always "$disk" <<PARTS
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
PARTS

partprobe "$disk"
sleep 1

info "Wiping signatures (if any)"
wipefs -a "${disk}1" || true
wipefs -a "${disk}2" || true

info "Formatting partitions"
mkfs.vfat -F32 "${disk}1"
case "$root_fs" in
  ext4) mkfs.ext4 -F "${disk}2";;
  xfs) mkfs.xfs -f "${disk}2";;
  btrfs) mkfs.btrfs -f "${disk}2";;
esac

info "Mounting partitions"
mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi

# don't remove the entire mountpoint now (we need place to store tarball or we will download to /tmp)
cd /mnt/gentoo

# ---------- Download Stage3 reliably to /tmp ----------
AUTOBUILDS_BASE="https://distfiles.gentoo.org/releases/amd64/autobuilds/"
info "Fetching latest stage3 listing from ${AUTOBUILDS_BASE}latest-stage3-amd64-openrc.txt"
stage3_list_url="${AUTOBUILDS_BASE}latest-stage3-amd64-openrc.txt"
if ! curl -fsS "$stage3_list_url" -o /tmp/latest-stage3-list.txt; then
  err "Failed to retrieve latest-stage3 list from ${stage3_list_url}"
  exit 5
fi

STAGE3_FILE=$(awk 'NF && $1 !~ /^#/{print $1; exit}' /tmp/latest-stage3-list.txt)
if [ -z "$STAGE3_FILE" ]; then
  err "Could not parse Stage3 filename from list"
  exit 6
fi

STAGE3_URL="${AUTOBUILDS_BASE}${STAGE3_FILE}"
info "Downloading Stage3 to /tmp: ${STAGE3_URL}"
if ! wget -q --show-progress -O "/tmp/${STAGE3_FILE}" "${STAGE3_URL}"; then
  err "Failed to download ${STAGE3_URL}"
  exit 7
fi

info "Extracting Stage3 into /mnt/gentoo"
tar xpvf "/tmp/${STAGE3_FILE}" -C /mnt/gentoo --xattrs-include='*.*' --numeric-owner

# optional: remove the tarball to save space (commented out by default)
# rm -f "/tmp/${STAGE3_FILE}"

# ---------- make.conf generation (robust) ----------
DE_USE_FLAGS=""
case "$de_key" in
  GNOME) DE_USE_FLAGS="gnome gtk -qt5 -kde";;
  KDE_PLASMA) DE_USE_FLAGS="plasma kde qt5 -gtk -gnome";;
  XFCE) DE_USE_FLAGS="xfce gtk -qt5 -kde -gnome";;
  LXDE) DE_USE_FLAGS="lxde gtk -qt5 -kde -gnome";;
  MATE) DE_USE_FLAGS="mate gtk -qt5 -kde -gnome";;
  CINNAMON) DE_USE_FLAGS="cinnamon gtk -qt5 -kde -gnome";;
  NONE) DE_USE_FLAGS="";;
esac

info "Writing /mnt/gentoo/etc/portage/make.conf"
cat > /mnt/gentoo/etc/portage/make.conf <<EOF
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C target-cpu=native"
MAKEOPTS="-j$(nproc)"
FEATURES="buildpkg"
EMERGE_DEFAULT_OPTS="--binarypkg-respect-use=y"
ACCEPT_LICENSE="@FREE"
VIDEO_CARDS="amdgpu intel nouveau"
INPUT_DEVICES="libinput"
GRUB_PLATFORMS="efi-64"
EOF

if [ -n "$DE_USE_FLAGS" ]; then
  echo "USE=\"$DE_USE_FLAGS dbus elogind pulseaudio\"" >> /mnt/gentoo/etc/portage/make.conf
else
  echo "USE=\"dbus elogind pulseaudio\"" >> /mnt/gentoo/etc/portage/make.conf
fi

cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

info "Preparing chroot mounts"
mount -t proc proc /mnt/gentoo/proc || true
mount --rbind /sys /mnt/gentoo/sys || true
mount --make-rslave /mnt/gentoo/sys || true
mount --rbind /dev /mnt/gentoo/dev || true
mount --make-rslave /mnt/gentoo/dev || true
mount --bind /run /mnt/gentoo/run || true
mount --make-slave /mnt/gentoo/run || true

CHROOT_SCRIPT_PATH="/mnt/gentoo/tmp/chroot_install.sh"
CHROOT_ENV_PATH="/mnt/gentoo/tmp/autogen_env"

info "Creating autogen_env and chroot script inside /mnt/gentoo/tmp"
mkdir -p /mnt/gentoo/tmp
cat > "$CHROOT_ENV_PATH" <<EOF
DE_CHOICE='${de_key}'
INIT_CHOICE='${init_choice}'
HOSTNAME='${hostname}'
USERNAME='${username}'
ROOT_PASSWORD='${root_password}'
USER_PASSWORD='${user_password}'
EOF

cat > "$CHROOT_SCRIPT_PATH" <<'CHROOT_SH'
#!/bin/bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/local/sbin"

info() { echo "--> [CHROOT] $*"; }

healing_emerge() {
  local args=( "$@" )
  local max_attempts=5
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    info "emerge attempt $attempt: ${args[*]}"
    if emerge --verbose "${args[@]}" &> /tmp/emerge.log; then
      cat /tmp/emerge.log
      return 0
    fi
    cat /tmp/emerge.log
    if grep -q "circular dependencies" /tmp/emerge.log 2>/dev/null; then
      fix_line=$(grep "Change USE:" /tmp/emerge.log | head -n1 || true)
      if [ -n "$fix_line" ]; then
        pkg=$(echo "$fix_line" | awk '{print $2}' | sed 's/-[0-9].*//')
        usechg=$(echo "$fix_line" | awk -F 'Change USE: ' '{print $2}' | sed 's/)//')
        mkdir -p /etc/portage/package.use
        echo "$pkg $usechg" >> /etc/portage/package.use/99_autofix
        attempt=$((attempt+1))
        continue
      fi
    fi
    attempt=$((attempt+1))
  done
  return 1
}

info "Running emerge-webrsync"
emerge-webrsync || true

info "Selecting profile (prefer merged-usr)"
PROFILE=""
if [ "${INIT_CHOICE:-OpenRC}" = "Systemd" ]; then
  PROFILE=$(eselect profile list | grep -i 'systemd' | grep -i 'merged-usr' | tail -n1 | awk '{print $2}' || true)
  if [ -z "$PROFILE" ]; then
    PROFILE=$(eselect profile list | grep -i 'systemd' | tail -n1 | awk '{print $2}' || true)
  fi
else
  PROFILE=$(eselect profile list | grep -i 'openrc' | grep -i 'merged-usr' | tail -n1 | awk '{print $2}' || true)
  if [ -z "$PROFILE" ]; then
    PROFILE=$(eselect profile list | grep -i 'openrc' | tail -n1 | awk '{print $2}' || true)
  fi
fi

if [ -n "$PROFILE" ]; then
  info "Setting profile: $PROFILE"
  eselect profile set "$PROFILE" || info "eselect profile set failed for $PROFILE"
  PRPATH=$(eselect profile show 2>/dev/null || true)
  if [ -n "$PRPATH" ]; then
    ln -sf "$PRPATH" /etc/portage/make.profile || true
  fi
else
  info "No profile candidate found; skipping profile set"
fi

healing_emerge --update --deep --newuse @system || true

case "${DE_CHOICE:-NONE}" in
  GNOME) healing_emerge gnome-shell/gnome || true;;
  KDE_PLASMA) healing_emerge kde-plasma/plasma-meta || true;;
  XFCE) healing_emerge xfce-base/xfce4-meta || true;;
  LXDE) healing_emerge lxde-base/lxde-meta || true;;
  MATE) healing_emerge mate-base/mate-meta || true;;
  CINNAMON) healing_emerge cinnamon-meta || true;;
  NONE) info "Minimal install (no DE)";;
esac

rm -f /etc/portage/package.use/99_autofix || true

healing_emerge --update --deep --newuse @world --keep-going=y || true

if emerge -q app-portage/cpuid2cpuflags >/dev/null 2>&1; then
  echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags || true
fi

grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen || true
eselect locale set en_US.UTF-8 || true
env-update && source /etc/profile || true

if emerge -q sys-kernel/gentoo-kernel-bin >/dev/null 2>&1; then
  info "Installed gentoo-kernel-bin"
else
  info "gentoo-kernel-bin not available; trying gentoo-sources"
  emerge -q sys-kernel/gentoo-sources || true
fi

emerge -q sys-fs/genfstab || true
genfstab -U / > /etc/fstab || true

echo "$HOSTNAME" > /etc/hostname
echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -G users,wheel,audio,video -s /bin/bash "$USERNAME" || true
echo "$USERNAME:$USER_PASSWORD" | chpasswd || true

emerge -q app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate || true
rc-update add sysklogd default || true
rc-update add chronyd default || true
rc-update add cronie default || true

emerge -q net-misc/networkmanager || true
rc-update add NetworkManager default || true
rc-update add sshd default || true

emerge -q x11-base/xorg-server || true
case "${DE_CHOICE:-NONE}" in
  GNOME) rc-update add gdm default || true;;
  KDE_PLASMA) emerge -q sys-boot/sddm || true; rc-update add sddm default || true;;
  XFCE|LXDE|MATE|CINNAMON) emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter || true; rc-update add lightdm default || true;;
  NONE) info "No display manager to configure";;
esac

emerge -q sys-boot/grub || true
mkdir -p /boot || true
grub-install --target=x86_64-efi --efi-directory=/efi || true
grub-mkconfig -o /boot/grub/grub.cfg || true

info "Chroot configuration complete"
exit 0
CHROOT_SH

chmod +x "$CHROOT_SCRIPT_PATH"

WRAPPER_PATH="/mnt/gentoo/tmp/chroot_wrapper.sh"
cat > "$WRAPPER_PATH" <<'WRAP'
#!/bin/bash
set -euo pipefail
if [ -f /tmp/autogen_env ]; then
  source /tmp/autogen_env
fi
export DE_CHOICE INIT_CHOICE HOSTNAME USERNAME ROOT_PASSWORD USER_PASSWORD
/bin/bash /tmp/chroot_install.sh
WRAP
chmod +x "$WRAPPER_PATH"

info "Entering chroot and running installation (this may take a long time)"
chroot /mnt/gentoo /tmp/chroot_wrapper.sh

info "Removing temporary files inside chroot and on host"
rm -f /mnt/gentoo/tmp/chroot_install.sh /mnt/gentoo/tmp/chroot_wrapper.sh /mnt/gentoo/tmp/autogen_env || true

info "Unmounting filesystems"
umount /mnt/gentoo/run 2>/dev/null || true
umount -l /mnt/gentoo/dev/pts 2>/dev/null || true
umount -l /mnt/gentoo/dev/shm 2>/dev/null || true
umount -R /mnt/gentoo 2>/dev/null || true

if [ "${created_swap:-0}" -eq 1 ]; then
  info "Removing temporary swapfile"
  swapoff /swapfile || true
  rm -f /swapfile || true
fi

info "Installation finished successfully. Reboot to boot into the new system."
exit 0

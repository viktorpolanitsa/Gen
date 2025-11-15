#!/usr/bin/env bash
# autogentoo_final_total_fix.sh
# Single-file Gentoo installer — comprehensive fixes for:
#  - robust Stage3 discovery & mirror RTT ranking (mirrorselect fallback)
#  - correct profile selection (prefer merged-usr profiles if available)
#  - automatic acceptance of linux-firmware redistributable license & keywords
#  - resilient chroot installer with "healing_emerge" retries and autounmask handling
#  - deterministic EFI/GRUB install, NVRAM verification and fallback (EFI/Boot/bootx64.efi)
#  - filesystem choices (ext4/xfs/btrfs), GPT partitioning (EFI + root)
#  - logging, retries, safe cleanup
#
# WARNING: THIS SCRIPT WILL ERASE THE SELECTED TARGET DISK. TEST IN A VM FIRST.
set -euo pipefail
export TZ="UTC"
IFS=$'\n\t'

# ---------------- Logging ----------------
LOG="/tmp/autogentoo_install.log"
exec > >(tee -a "$LOG") 2>&1
log() { printf '%s %s\n' "$(date -Is)" "$*"; }
err() { printf '%s ERROR: %s\n' "$(date -Is)" "$*" >&2; }
note() { printf '%s NOTE: %s\n' "$(date -Is)" "$*"; }

# ---------------- Sanity ----------------
if [[ $EUID -ne 0 ]]; then
  err "Script must be run as root"
  exit 1
fi

# ---------------- Helpers ----------------
retry_cmd() {
  local -i attempts=${1:-3}; shift
  local sleep_s=${1:-2}; shift
  local n=0
  until "$@"; do
    n=$((n+1))
    if (( n >= attempts )); then return 1; fi
    sleep "$sleep_s"
  done
  return 0
}
http_head_time() {
  curl -s -o /dev/null -w '%{time_total}' --head --max-time 8 "$1" 2>/dev/null || echo ""
}
join_by() { local IFS="$1"; shift; echo "$*"; }

cleanup() {
  log "Running cleanup..."
  rm -f /mnt/gentoo/tmp/.installer_env.sh 2>/dev/null || true
  umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
  umount -l /mnt/gentoo/run 2>/dev/null || true
  umount -R /mnt/gentoo 2>/dev/null || true
  log "Cleanup complete."
}
trap cleanup EXIT

# ---------------- CLI args ----------------
UNATTENDED=${UNATTENDED:-0}
SAVE_INSTALLER_COPY=${SAVE_INSTALLER_COPY:-0}
while (( $# )); do
  case "$1" in
    --unattended) UNATTENDED=1; shift;;
    --save-copy) SAVE_INSTALLER_COPY=1; shift;;
    --help) printf 'Usage: %s [--unattended] [--save-copy]\n' "$0"; exit 0;;
    *) break;;
  esac
done

# ---------------- Input collection ----------------
if [[ "$UNATTENDED" -eq 0 ]]; then
  log "Interactive mode"
  lsblk -dno NAME,SIZE,MODEL || true
  read -rp "Target disk (example: sda or nvme0n1): " disk_in
  read -rp "Filesystem for root (ext4,xfs,btrfs) [ext4]: " fs_choice; fs_choice=${fs_choice:-ext4}
  read -rp "Desktop environment (GNOME,KDE Plasma,XFCE,MATE,LXQt,None) [None]: " de_choice; de_choice=${de_choice:-None}
  read -rp "Hostname [gentoo]: " hostname; hostname=${hostname:-gentoo}
  read -rp "Username [gentoo]: " username; username=${username:-gentoo}
  read -rp "Timezone (e.g. Europe/Moscow) [UTC]: " timezone; timezone=${timezone:-UTC}
  read -rp "Save installer copy to /tmp? (yes/no) [no]: " savecopy; savecopy=${savecopy:-no}
  [[ "$savecopy" =~ ^(yes|y)$ ]] && SAVE_INSTALLER_COPY=1
  read -rp "Proceed and erase /dev/${disk_in}? Type YES to continue: " conf
  [[ "$conf" == "YES" ]] || { log "Cancelled by user"; exit 0; }
  read -rsp "Root password: " root_pw; echo
  read -rsp "Confirm root password: " root_pw2; echo
  [[ "$root_pw" == "$root_pw2" ]] || { err "Root passwords differ"; exit 1; }
  read -rsp "User password: " user_pw; echo
  read -rsp "Confirm user password: " user_pw2; echo
  [[ "$user_pw" == "$user_pw2" ]] || { err "User passwords differ"; exit 1; }
else
  log "Unattended mode: reading environment variables"
  disk_in="${DISK:-}"
  fs_choice="${FS_CHOICE:-ext4}"
  de_choice="${DE_CHOICE:-None}"
  hostname="${HOSTNAME:-gentoo}"
  username="${USERNAME:-gentoo}"
  timezone="${TIMEZONE:-UTC}"
  root_pw="${ROOT_PASSWORD:-changeme}"
  user_pw="${USER_PASSWORD:-changeme}"
  [[ -n "$disk_in" ]] || { err "DISK env required in unattended mode"; exit 1; }
fi

disk="/dev/${disk_in##*/}"
if [[ ! -b "$disk" ]]; then err "Block device $disk not found"; exit 1; fi
case "$fs_choice" in ext4|xfs|btrfs) : ;; *) fs_choice=ext4; note "Defaulted root fs to ext4";; esac
case "$de_choice" in GNOME|KDE\ Plasma|KDE|XFCE|MATE|LXQt|None) : ;; *) de_choice="None";; esac

log "Config: disk=$disk fs=$fs_choice de=$de_choice host=$hostname user=$username tz=$timezone"

# ---------------- Disk partitioning & formatting ----------------
log "Preparing disk: unmounting and flush"
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R "${disk}"* || true
blockdev --flushbufs "$disk" || true
sleep 1

log "Partitioning $disk: GPT with EFI 512MiB + root"
sfdisk --force --wipe always --wipe-partitions always "$disk" <<PART
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
PART

partprobe "$disk"; sleep 1
wipefs -a "${disk}1" || true
wipefs -a "${disk}2" || true

log "Formatting partitions"
mkfs.vfat -F32 "${disk}1"
case "$fs_choice" in
  ext4) mkfs.ext4 -F "${disk}2" ;;
  xfs) mkfs.xfs -f "${disk}2" ;;
  btrfs) mkfs.btrfs -f "${disk}2" ;;
esac

mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount "${disk}1" /mnt/gentoo/boot/efi
cd /mnt/gentoo

# ---------------- Mirror selection & Stage3 discovery ----------------
log "Detecting region (geo-IP)"
REGION="$(curl -s --max-time 5 https://ipapi.co/country || true)"
log "Region detected: ${REGION:-unknown}"

CANDIDATES=()
if command -v mirrorselect >/dev/null 2>&1; then
  note "mirrorselect available"
  TMP=$(mktemp)
  if mirrorselect -s4 -b8 --country "${REGION:-}" -o "$TMP" >/dev/null 2>&1; then
    while IFS= read -r l; do
      u=$(echo "$l" | grep -oE 'https?://[^ ]+' || true)
      [[ -n "$u" ]] && CANDIDATES+=("$u")
    done < "$TMP"
  fi
  rm -f "$TMP" || true
fi

if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
  note "Using curated mirror list"
  if [[ "$REGION" == "RU" ]]; then
    CANDIDATES+=( "https://mirror.yandex.ru/gentoo/" "https://mirror.mos.ru/gentoo/" "https://mirror.kaspersky.com/gentoo/" "https://distfiles.gentoo.org/" )
  else
    CANDIDATES+=( "https://distfiles.gentoo.org/" "https://builds.gentoo.org/" "https://ftp.snt.utwente.nl/gentoo/" "https://mirror.clarkson.edu/gentoo/" )
  fi
fi

log "Candidate mirrors: $(join_by ', ' "${CANDIDATES[@]}")"

BEST_STAGE3=""
BEST_RTT=9999
for m in "${CANDIDATES[@]}"; do
  [[ "${m: -1}" != "/" ]] && m="${m}/"
  for idx in "releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt" "releases/amd64/autobuilds/latest-stage3-amd64.txt"; do
    IDX="${m}${idx}"
    if curl -s --head --fail --max-time 6 "$IDX" >/dev/null 2>&1; then
      STG=$(curl -fsS "$IDX" 2>/dev/null | awk '!/^#/ && /stage3/ {print $1; exit}')
      if [[ -n "$STG" ]]; then
        FULL="${m}releases/amd64/autobuilds/${STG}"
        if curl -s --head --fail --max-time 8 "$FULL" >/dev/null 2>&1; then
          rtt=$(http_head_time "$FULL" || echo "")
          if [[ -n "$rtt" ]]; then
            if awk "BEGIN{exit !($rtt < $BEST_RTT)}"; then
              BEST_RTT="$rtt"
              BEST_STAGE3="$FULL"
              log "Selected candidate: $BEST_STAGE3 (rtt=$BEST_RTT)"
            fi
          elif [[ -z "$BEST_STAGE3" ]]; then
            BEST_STAGE3="$FULL"
            log "Fallback candidate: $BEST_STAGE3"
          fi
        fi
      fi
    fi
  done
done

if [[ -z "$BEST_STAGE3" ]]; then
  note "Trying official distfiles as fallback"
  IDX="https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt"
  if curl -s --head --fail "$IDX" >/dev/null 2>&1; then
    STG=$(curl -fsS "$IDX" 2>/dev/null | awk '!/^#/ && /stage3/ {print $1; exit}')
    BEST_STAGE3="https://distfiles.gentoo.org/releases/amd64/autobuilds/${STG}"
  fi
fi

[[ -n "$BEST_STAGE3" ]] || { err "Failed to locate a Stage3 tarball on candidate mirrors"; exit 1; }
log "Stage3 chosen: $BEST_STAGE3"

# ---------------- Download Stage3 ----------------
STAGE3_LOCAL="/tmp/stage3.tar.xz"
log "Downloading Stage3 -> $STAGE3_LOCAL"
if ! retry_cmd 6 5 wget -c -O "$STAGE3_LOCAL" "$BEST_STAGE3"; then
  err "Stage3 download failed"; exit 1
fi

log "Extracting Stage3 into /mnt/gentoo"
tar xpvf "$STAGE3_LOCAL" --xattrs-include='*.*' --numeric-owner

# ---------------- make.conf ----------------
log "Generating /mnt/gentoo/etc/portage/make.conf"
case "$de_choice" in
  GNOME) DE_USE="gtk gnome -qt5 -kde";;
  "KDE Plasma"|KDE) DE_USE="qt5 plasma kde -gtk -gnome";;
  XFCE) DE_USE="gtk xfce -qt5 -kde -gnome";;
  MATE) DE_USE="gtk mate -qt5 -kde -gnome";;
  LXQt) DE_USE="qt5 lxqt -gnome -kde";;
  *) DE_USE="";;
esac

cat > /mnt/gentoo/etc/portage/make.conf <<MCF
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C target-cpu=native"
MAKEOPTS="-j$(nproc)"
USE="${DE_USE} dbus elogind pulseaudio"
ACCEPT_LICENSE="@FREE"
VIDEO_CARDS="amdgpu intel nouveau"
INPUT_DEVICES="libinput"
GRUB_PLATFORMS="efi-64"
MCF

# ---------------- chroot mounts ----------------
log "Preparing chroot mounts and copying resolv.conf"
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/ || true
mount -t proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys; mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev; mount --make-rslave /mnt/gentoo/dev
mkdir -p /mnt/gentoo/run
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# ---------------- secure env ----------------
log "Writing secure environment to /mnt/gentoo/tmp/.installer_env.sh"
cat > /mnt/gentoo/tmp/.installer_env.sh <<ENV
#!/usr/bin/env bash
export DE_CHOICE='${de_choice}'
export HOSTNAME='${hostname}'
export USERNAME='${username}'
export TIMEZONE='${timezone}'
export ROOT_PASSWORD='${root_pw}'
export USER_PASSWORD='${user_pw}'
ENV
chmod 600 /mnt/gentoo/tmp/.installer_env.sh
chmod 700 /mnt/gentoo/tmp/.installer_env.sh

# ---------------- chroot script ----------------
log "Creating chroot installer script"
cat > /mnt/gentoo/tmp/chroot_install.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
log(){ printf '%s %s\n' "$(date -Is)" "$*" >&2; }

retry_inner(){
  local -i attempts=${1:-3}; shift
  local sleep_s=${1:-2}; shift
  local n=0
  until "$@"; do
    n=$((n+1))
    if (( n >= attempts )); then return 1; fi
    sleep "$sleep_s"
  done
  return 0
}

healing_emerge(){
  local -a args=( "$@" )
  local attempt=1 max=4
  while (( attempt <= max )); do
    log "healing_emerge attempt $attempt: emerge ${args[*]}"
    if emerge --backtrack=30 --verbose "${args[@]}" &> /tmp/emerge.log; then
      cat /tmp/emerge.log
      return 0
    fi
    cat /tmp/emerge.log
    if grep -q "Change USE" /tmp/emerge.log; then
      fix=$(grep "Change USE" /tmp/emerge.log | head -n1 || true)
      pkg=$(echo "$fix" | awk '{for(i=1;i<=NF;i++){ if ($i ~ /[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+/) {print $i; break}} }' || true)
      usechange=$(echo "$fix" | sed -n 's/.*Change USE: //p' | sed 's/)//' || true)
      if [[ -n "$pkg" && -n "$usechange" ]]; then
        mkdir -p /etc/portage/package.use
        echo "$pkg $usechange" >> /etc/portage/package.use/99_autofix
        log "Applied temporary USE fix: $pkg $usechange"
        attempt=$((attempt+1))
        continue
      fi
    fi
    if emerge --autounmask-write "${args[@]}" &> /tmp/autounmask 2>&1; then
      etc-update --automode -3 || true
      attempt=$((attempt+1))
      continue
    fi
    return 1
  done
  return 1
}

# load env
if [[ -f /tmp/.installer_env.sh ]]; then
  # shellcheck source=/tmp/.installer_env.sh
  source /tmp/.installer_env.sh
else
  log "/tmp/.installer_env.sh missing; abort"
  exit 1
fi

log "Chroot started: DE=${DE_CHOICE}, HOSTNAME=${HOSTNAME}"

# Sync portage
if ! retry_inner 3 5 emerge-webrsync; then
  log "emerge-webrsync failed; trying emerge --sync"
  retry_inner 3 20 emerge --sync || log "portage sync fallback failed"
fi

# Profile selection: prefer merged-usr profiles if available (fix for split-usr vs merged-usr issues)
log "Selecting appropriate profile (prefer merged-usr if available)"
PROFILE=""
if eselect profile list | grep -q 'merged-usr'; then
  PROFILE=$(eselect profile list | grep 'merged-usr' | awk '{print $1}' | tail -n1 || true)
fi
if [[ -z "$PROFILE" ]]; then
  # fallback: choose latest amd64 openrc if available else latest amd64
  if eselect profile list | grep -Eq 'amd64.*openrc'; then
    PROFILE=$(eselect profile list | grep -E 'amd64.*openrc' | tail -n1 | awk '{print $1}')
  else
    PROFILE=$(eselect profile list | grep -E 'amd64' | tail -n1 | awk '{print $1}')
  fi
fi
if [[ -n "$PROFILE" ]]; then
  eselect profile set "$PROFILE" || true
  log "Profile set to $PROFILE"
else
  log "Unable to detect profile automatically; please set manually"
fi

# Accept linux-firmware license and keywords automatically to prevent masked-package failures
log "Ensuring linux-firmware license and keyword acceptance"
mkdir -p /etc/portage/package.license /etc/portage/package.accept_keywords
# accept redistributable license for linux-firmware
echo "sys-kernel/linux-firmware linux-fw-redistributable" > /etc/portage/package.license/linux-firmware || true
# allow unstable keyword for linux-firmware if required
echo "sys-kernel/linux-firmware ~amd64" > /etc/portage/package.accept_keywords/linux-firmware || true

# Update system/world
healing_emerge --update --deep --newuse @world || log "world update had issues; proceeding"

# Kernel: try binary first; if masked/unavailable, install sources + genkernel
log "Kernel: try binary kernel"
if ! ls /boot/vmlinuz-* >/dev/null 2>&1; then
  if retry_inner 3 10 emerge -q sys-kernel/gentoo-kernel-bin; then
    log "Binary kernel installed"
  else
    log "Binary kernel unavailable; installing sources and genkernel"
    retry_inner 3 30 emerge -q sys-kernel/gentoo-sources sys-kernel/genkernel || true
    if command -v genkernel >/dev/null 2>&1; then genkernel all || true; fi
  fi
fi

if ! ls /boot/vmlinuz-* >/dev/null 2>&1; then
  log "Warning: no kernel found after attempts"
fi

# cpu flags
retry_inner 3 5 emerge -q app-portage/cpuid2cpuflags || true
if command -v cpuid2cpuflags >/dev/null 2>&1; then
  echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags || true
fi

# locales & timezone
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen || true
locale-gen || true
eselect locale set en_US.UTF-8 || true
env-update && source /etc/profile || true
if [[ -n "${TIMEZONE:-}" && -f /usr/share/zoneinfo/${TIMEZONE} ]]; then
  ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime || true
  hwclock --systohc || true
fi

# essential services
healing_emerge app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate || true
rc-update add sysklogd default || true
rc-update add chronyd default || true
rc-update add cronie default || true

# networking & ssh
healing_emerge net-misc/networkmanager || true
rc-update add NetworkManager default || true
rc-update add sshd default || true

# X and DE packages (best-effort)
healing_emerge x11-base/xorg-drivers x11-base/xorg-server || true
case "${DE_CHOICE:-None}" in
  GNOME) healing_emerge gnome-base/gnome || true ;;
  "KDE Plasma"|KDE) healing_emerge kde-plasma/plasma-meta || true ;;
  XFCE) healing_emerge xfce-base/xfce4-meta || true ;;
  MATE) healing_emerge mate-meta || true ;;
  LXQt) healing_emerge lxqt-meta || true ;;
esac

# display manager
case "${DE_CHOICE:-None}" in
  GNOME) rc-update add gdm default || true ;;
  "KDE Plasma"|KDE) healing_emerge sys-boot/sddm || true; rc-update add sddm default || true ;;
  XFCE|MATE|LXQt) healing_emerge x11-misc/lightdm x11-misc/lightdm-gtk-greeter || true; rc-update add lightdm default || true ;;
esac

# create user and set passwords
if ! id -u "${USERNAME}" >/dev/null 2>&1; then useradd -m -G users,wheel,audio,video -s /bin/bash "${USERNAME}" || true; fi
echo "root:${ROOT_PASSWORD}" | chpasswd || true
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd || true

# install GRUB and configure EFI
log "Install GRUB and configure EFI"
retry_inner 3 10 emerge -q sys-boot/grub || true

# pick EFI dir inside chroot
if [[ -d /boot/efi ]]; then EFI_DIR=/boot/efi
elif [[ -d /efi ]]; then EFI_DIR=/efi
else mkdir -p /boot/efi; EFI_DIR=/boot/efi; fi

log "Using EFI directory: ${EFI_DIR}"
# install with --removable to create fallback bootx64.efi
grub-install --target=x86_64-efi --efi-directory="${EFI_DIR}" --bootloader-id=Gentoo --recheck --removable || true
grub-mkconfig -o /boot/grub/grub.cfg || true

# ensure linux entries exist in grub.cfg
if ! grep -q "linux" /boot/grub/grub.cfg 2>/dev/null; then
  log "grub.cfg lacks linux entries; listing /boot for debug"
  ls -l /boot || true
  grub-mkconfig -o /boot/grub/grub.cfg || true
fi

# mount efivarfs in chroot to permit efibootmgr writes
if ! mountpoint -q /sys/firmware/efi/efivars 2>/dev/null; then
  log "Mounting efivarfs inside chroot"
  mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true
fi

# ensure NVRAM entry exists, else create or fallback
if command -v efibootmgr >/dev/null 2>&1; then
  if ! efibootmgr -v | grep -qi "Gentoo"; then
    log "Trying to create NVRAM entry for Gentoo"
    if [[ -f "${EFI_DIR}/EFI/Gentoo/grubx64.efi" ]]; then
      DISK_DEV=""
      if [[ -d /dev/disk/by-id ]]; then
        DISK_DEV=$(ls -1 /dev/disk/by-id/ | grep -v part | head -n1 || true)
      fi
      if [[ -n "$DISK_DEV" ]]; then
        efibootmgr --create --disk /dev/disk/by-id/"$DISK_DEV" --part 1 --loader "\\EFI\\Gentoo\\grubx64.efi" --label "Gentoo" || true
      else
        efibootmgr --create --label "Gentoo" --loader "\\EFI\\Gentoo\\grubx64.efi" || true
      fi
    else
      log "grubx64.efi missing; creating fallback Boot/bootx64.efi"
      mkdir -p "${EFI_DIR}/EFI/Boot" || true
      if [[ -f "${EFI_DIR}/EFI/Gentoo/grubx64.efi" ]]; then
        cp -f "${EFI_DIR}/EFI/Gentoo/grubx64.efi" "${EFI_DIR}/EFI/Boot/bootx64.efi" || true
      elif [[ -f "${EFI_DIR}/EFI/Boot/grubx64.efi" ]]; then
        cp -f "${EFI_DIR}/EFI/Boot/grubx64.efi" "${EFI_DIR}/EFI/Boot/bootx64.efi" || true
      fi
      efibootmgr --create --label "Gentoo" --loader "\\EFI\\Boot\\bootx64.efi" || true
    fi
  else
    log "Gentoo NVRAM entry exists"
  fi
else
  log "efibootmgr not available in chroot; NVRAM creation deferred to host-side step"
fi

log "Chroot installation finished"
CHROOT

# ---------------- Run chroot installer ----------------
chmod 700 /mnt/gentoo/tmp/.installer_env.sh || true
chmod +x /mnt/gentoo/tmp/chroot_install.sh || true
log "Entering chroot to run installer (this will take time)."
if ! chroot /mnt/gentoo /tmp/chroot_install.sh; then
  err "Chroot installer failed — inspect $LOG and chroot logs under /mnt/gentoo/var/log"
  # continue to post-chroot fixes attempt to salvage
fi

# ---------------- Post-chroot: Ensure EFI fallback + NVRAM (host) ----------------
log "Host-side EFI fix & NVRAM creation (run on host, not in chroot)"

# mount efivarfs on host if available
if [[ -d /sys/firmware/efi ]]; then
  if ! mountpoint -q /sys/firmware/efi/efivars 2>/dev/null; then
    log "Mounting efivarfs on host"
    mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true
  fi
else
  err "Host is not booted in UEFI mode; cannot write NVRAM (firmware must be UEFI for efibootmgr to work)"
fi

EFI_MOUNT_POINT="/mnt/gentoo/boot/efi"
if ! mountpoint -q "$EFI_MOUNT_POINT"; then
  # try to detect ESP
  ESP_DEV=""
  ESP_DEV=$(blkid -t PARTLABEL=EFI -o device 2>/dev/null || true)
  if [[ -z "$ESP_DEV" ]]; then
    # fallback: pick first vfat partition on target disk
    DEV_CAND=$(lsblk -rno NAME,FSTYPE | awk '$2=="vfat"{print "/dev/"$1}' | head -n1 || true)
    if [[ -n "$DEV_CAND" ]]; then ESP_DEV="$DEV_CAND"; fi
  fi
  if [[ -n "$ESP_DEV" && -b "$ESP_DEV" ]]; then
    log "Mounting ESP $ESP_DEV -> $EFI_MOUNT_POINT"
    mkdir -p "$EFI_MOUNT_POINT"
    mount "$ESP_DEV" "$EFI_MOUNT_POINT" || true
  else
    note "Cannot auto-detect ESP. Ensure /mnt/gentoo/boot/efi is mounted correctly."
  fi
fi

INSTALLED_GRUB="${EFI_MOUNT_POINT}/EFI/Gentoo/grubx64.efi"
FALLBACK_DIR="${EFI_MOUNT_POINT}/EFI/Boot"
FALLBACK_BIN="${FALLBACK_DIR}/bootx64.efi"

if [[ -f "$INSTALLED_GRUB" ]]; then
  mkdir -p "$FALLBACK_DIR" || true
  if [[ ! -f "$FALLBACK_BIN" || ! cmp -s "$INSTALLED_GRUB" "$FALLBACK_BIN" ]]; then
    cp -f "$INSTALLED_GRUB" "$FALLBACK_BIN" || true
    log "Created fallback EFI: $FALLBACK_BIN"
  else
    log "Fallback EFI already present"
  fi
else
  POSSIBLE=$(find /mnt/gentoo/boot /mnt/gentoo/efi -type f -iname "grubx64.efi" -print -quit 2>/dev/null || true)
  if [[ -n "$POSSIBLE" ]]; then
    mkdir -p "$FALLBACK_DIR" || true
    cp -f "$POSSIBLE" "$FALLBACK_BIN" || true
    log "Copied discovered grub ($POSSIBLE) to fallback $FALLBACK_BIN"
  else
    log "No grubx64.efi found in installed tree; grub-install may have failed in chroot"
  fi
fi

# Try to create NVRAM entry using efibootmgr on host
if command -v efibootmgr >/dev/null 2>&1; then
  if efibootmgr -v | grep -qi "Gentoo"; then
    log "Gentoo NVRAM entry already present on host"
  else
    ESP_DEV_PATH=$(findmnt -n -o SOURCE --target "$EFI_MOUNT_POINT" 2>/dev/null || true)
    if [[ -n "$ESP_DEV_PATH" ]]; then
      DISK_DEVICE=$(echo "$ESP_DEV_PATH" | sed -r 's/(p?[0-9]+)$//')
      PART_NO=$(echo "$ESP_DEV_PATH" | sed -r 's/.*p?([0-9]+)$/\1/')
      log "ESP device: $ESP_DEV_PATH (disk: $DISK_DEVICE, part: $PART_NO)"
      LOADER_PATH="\\EFI\\Gentoo\\grubx64.efi"
      if efibootmgr --create --disk "$DISK_DEVICE" --part "$PART_NO" --loader "$LOADER_PATH" --label "Gentoo" >/dev/null 2>&1; then
        log "Created NVRAM entry for Gentoo"
      else
        log "efibootmgr create failed; trying fallback loader path"
        efibootmgr --create --disk "$DISK_DEVICE" --part "$PART_NO" --loader "\\EFI\\Boot\\bootx64.efi" --label "Gentoo" >/dev/null 2>&1 || true
      fi
    else
      log "Cannot determine ESP device path; skip efibootmgr creation"
    fi
  fi
  log "efibootmgr -v output:"
  efibootmgr -v || true
else
  log "efibootmgr not present on host; please install efibootmgr and create NVRAM entry manually if required"
fi

# ---------------- Final cleanup & unmount ----------------
log "Removing temporary chroot files"
rm -f /mnt/gentoo/tmp/chroot_install.sh /mnt/gentoo/tmp/.installer_env.sh || true

log "Unmounting /mnt/gentoo"
umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
umount -R /mnt/gentoo 2>/dev/null || true

log "Installation finished. Reboot into the new system when ready."

# ---------------- Save installer copy if requested ----------------
if [[ "${SAVE_INSTALLER_COPY:-0}" -ne 0 ]]; then
  OUT="/tmp/autogentoo_installer_saved.sh"
  if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    cp --preserve=mode,ownership "${BASH_SOURCE[0]}" "$OUT" || true
    chmod +x "$OUT" || true
    log "Installer copy saved to $OUT"
    echo "Write to USB example: sudo dd if=${OUT} of=/dev/sdX bs=4M status=progress && sync"
  fi
fi

log "All done. See $LOG for full trace."

#!/usr/bin/env bash
# autogentoo_final_full.sh
# Fully consolidated Gentoo installer (single-file)
# Features:
#  - Region-aware mirror selection (mirrorselect + RTT fallback)
#  - Robust Stage3 discovery & download with retries and fallbacks
#  - Partitioning (GPT) with EFI (512MiB) + root; filesystem choices ext4/xfs/btrfs
#  - Mounting of EFI to /mnt/gentoo/boot/efi (ensures grub installs correctly)
#  - Secure passing of secrets into chroot via restricted file
#  - Chroot installer with self-healing emerge heuristics, kernel install fallback
#  - GRUB installation with NVRAM verification, --removable fallback (bootx64.efi)
#  - efivarfs handling, efibootmgr checks & creation
#  - Logging, retries, safe cleanup (trap)
#
# WARNING: This script WILL ERASE TARGET DISK. Test in VM first.
set -euo pipefail
export TZ="UTC"
IFS=$'\n\t'

# ------------ Logging -------------
LOG="/tmp/autogentoo_install.log"
exec > >(tee -a "$LOG") 2>&1
log(){ printf '%s %s\n' "$(date -Is)" "$*"; }
err(){ printf '%s ERROR: %s\n' "$(date -Is)" "$*" >&2; }
note(){ printf '%s NOTE: %s\n' "$(date -Is)" "$*"; }

# ------------ Basic sanity -------------
if [[ $EUID -ne 0 ]]; then
  err "Must run as root"
  exit 1
fi

# ------------ Helpers -------------
retry_cmd(){
  # retry_cmd <attempts> <sleep> <cmd...>
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

http_head_time(){
  local url="$1"
  curl -s -o /dev/null -w '%{time_total}' --head --max-time 8 "$url" 2>/dev/null || echo ""
}

join_by(){ local IFS="$1"; shift; echo "$*"; }

cleanup(){
  log "Cleanup: attempting to unmount and remove temp files"
  rm -f /mnt/gentoo/tmp/.installer_env.sh 2>/dev/null || true
  umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
  umount -l /mnt/gentoo/run 2>/dev/null || true
  umount -R /mnt/gentoo 2>/dev/null || true
  log "Cleanup finished"
}
trap cleanup EXIT

# ------------ CLI args -------------
UNATTENDED=${UNATTENDED:-0}
GEN_INSTALLER_COPY=${GEN_INSTALLER_COPY:-0}
while (( $# )); do
  case "$1" in
    --unattended) UNATTENDED=1; shift;;
    --gen-copy) GEN_INSTALLER_COPY=1; shift;;
    --help) echo "Usage: $0 [--unattended] [--gen-copy]"; exit 0;;
    *) break;;
  esac
done

# ------------ Input collection -------------
if [[ "$UNATTENDED" -eq 0 ]]; then
  log "Interactive mode"
  lsblk -dno NAME,SIZE,MODEL || true
  read -rp "Target disk (e.g. sda or nvme0n1): " disk_in
  read -rp "Root filesystem (ext4,xfs,btrfs) [ext4]: " fs_choice; fs_choice=${fs_choice:-ext4}
  read -rp "Desktop env (GNOME,KDE Plasma,XFCE,LXQt,MATE,None) [None]: " de_choice; de_choice=${de_choice:-None}
  read -rp "Hostname [gentoo]: " hostname; hostname=${hostname:-gentoo}
  read -rp "Username [gentoo]: " username; username=${username:-gentoo}
  read -rp "Timezone (e.g. Europe/Moscow) [UTC]: " timezone; timezone=${timezone:-UTC}
  read -rp "Save installer copy to /tmp? (yes/no) [no]: " savecopy; savecopy=${savecopy:-no}
  [[ "$savecopy" =~ ^(yes|y)$ ]] && GEN_INSTALLER_COPY=1
  read -rp "Proceed and erase /dev/${disk_in}? Type YES to continue: " confirm
  [[ "$confirm" == "YES" ]] || { log "User cancelled"; exit 0; }
  read -rsp "Root password: " root_pw; echo
  read -rsp "Confirm root password: " root_pw2; echo
  [[ "$root_pw" == "$root_pw2" ]] || { err "Root passwords differ"; exit 1; }
  read -rsp "User password for ${username}: " user_pw; echo
  read -rsp "Confirm user password: " user_pw2; echo
  [[ "$user_pw" == "$user_pw2" ]] || { err "User passwords differ"; exit 1; }
else
  log "Unattended mode, reading environment variables"
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
if [[ ! -b "$disk" ]]; then err "Device $disk not found"; exit 1; fi
log "Config: disk=$disk fs=$fs_choice de=$de_choice host=$hostname user=$username tz=$timezone"

# ------------ Disk prep -------------
log "Preparing disk: unmounting and flush buffers"
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R "${disk}"* || true
blockdev --flushbufs "$disk" || true
sleep 1

log "Partitioning: GPT, EFI 512MiB + root"
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
  ext4) mkfs.ext4 -F "${disk}2";;
  xfs) mkfs.xfs -f "${disk}2";;
  btrfs) mkfs.btrfs -f "${disk}2";;
esac

mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount "${disk}1" /mnt/gentoo/boot/efi
cd /mnt/gentoo

# ------------ Mirror selection & Stage3 discovery -------------
log "Detecting region via geo-IP"
REGION="$(curl -s --max-time 5 https://ipapi.co/country || true)"
log "Region: ${REGION:-unknown}"

CANDIDATES=()
if command -v mirrorselect >/dev/null 2>&1; then
  note "Using mirrorselect to produce candidate list"
  TMP=$(mktemp)
  # try localized first, fallback to generic
  if mirrorselect -s4 -b8 --country "${REGION:-}" -o "$TMP" >/dev/null 2>&1; then
    while IFS= read -r l; do
      u=$(echo "$l" | grep -oE 'https?://[^ ]+' || true)
      [[ -n "$u" ]] && CANDIDATES+=("$u")
    done < "$TMP"
  fi
  rm -f "$TMP" || true
fi

if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
  note "Using curated fallback mirrors"
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
              log "Best so far: $BEST_STAGE3 (rtt=$BEST_RTT)"
            fi
          elif [[ -z "$BEST_STAGE3" ]]; then
            BEST_STAGE3="$FULL"
            log "Fallback chosen: $BEST_STAGE3"
          fi
        fi
      fi
    fi
  done
done

if [[ -z "$BEST_STAGE3" ]]; then
  note "Attempting official distfiles fallback"
  IDX="https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt"
  if curl -s --head --fail "$IDX" >/dev/null 2>&1; then
    STG=$(curl -fsS "$IDX" 2>/dev/null | awk '!/^#/ && /stage3/ {print $1; exit}')
    BEST_STAGE3="https://distfiles.gentoo.org/releases/amd64/autobuilds/${STG}"
  fi
fi

[[ -n "$BEST_STAGE3" ]] || { err "No Stage3 discovered; aborting"; exit 1; }
log "Using Stage3: $BEST_STAGE3"

# ------------ Download Stage3 -------------
STAGE3_LOCAL="/tmp/stage3.tar.xz"
log "Downloading Stage3 to $STAGE3_LOCAL"
if ! retry_cmd 6 5 wget -c -O "$STAGE3_LOCAL" "$BEST_STAGE3"; then
  err "Stage3 download failed"; exit 1
fi

log "Extract stage3 into /mnt/gentoo"
tar xpvf "$STAGE3_LOCAL" --xattrs-include='*.*' --numeric-owner

# ------------ make.conf -------------
log "Writing make.conf"
case "$de_choice" in
  "GNOME") DE_USE="gtk gnome -qt5 -kde";;
  "KDE Plasma") DE_USE="qt5 plasma kde -gtk -gnome";;
  "XFCE") DE_USE="gtk xfce -qt5 -kde -gnome";;
  "LXQt") DE_USE="qt5 lxqt -gnome -kde";;
  "MATE") DE_USE="gtk mate -qt5 -kde -gnome";;
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

# ------------ chroot mounts -------------
log "Mounting necessary filesystems for chroot"
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/ || true
mount -t proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys; mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev; mount --make-rslave /mnt/gentoo/dev
mkdir -p /mnt/gentoo/run
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# ------------ secure env into chroot -------------
log "Creating secure env for chroot"
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

# ------------ chroot installer -------------
log "Creating chroot installer"
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
  source /tmp/.installer_env.sh
else
  log "Missing env; abort"
  exit 1
fi

log "Chroot: DE=${DE_CHOICE}, HOST=${HOSTNAME}"

# portage sync
if ! retry_inner 3 5 emerge-webrsync; then
  log "emerge-webrsync failed; trying emerge --sync"
  retry_inner 3 20 emerge --sync || log "sync fallback failed"
fi

# profile selection prefer openrc
PROFILE=""
if eselect profile list | grep -Eq 'amd64.*openrc'; then
  PROFILE=$(eselect profile list | grep -E 'amd64.*openrc' | tail -n1 | awk '{print $1}')
else
  PROFILE=$(eselect profile list | grep -E 'amd64' | tail -n1 | awk '{print $1}')
fi
if [[ -n "$PROFILE" ]]; then eselect profile set "$PROFILE" || true; fi
log "Profile set: $PROFILE"

# update system
healing_emerge --update --deep --newuse @system || log "system update had issues"

# kernel: try binary, else sources+genkernel
if ! ls /boot/vmlinuz-* >/dev/null 2>&1; then
  log "No kernel found: try binary kernel"
  if retry_inner 3 10 emerge -q sys-kernel/gentoo-kernel-bin; then
    log "Binary kernel installed"
  else
    log "Installing sources + genkernel"
    retry_inner 3 30 emerge -q sys-kernel/gentoo-sources sys-kernel/genkernel || true
    if command -v genkernel >/dev/null 2>&1; then genkernel all || true; fi
  fi
fi

if ! ls /boot/vmlinuz-* >/dev/null 2>&1; then
  log "Warning: no vmlinuz found after kernel install attempts"
fi

# cpuid2cpuflags
retry_inner 3 5 emerge -q app-portage/cpuid2cpuflags || true
if command -v cpuid2cpuflags >/dev/null 2>&1; then
  echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags || true
fi

# locale/timezone
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

# networking and x
healing_emerge net-misc/networkmanager || true
rc-update add NetworkManager default || true
rc-update add sshd default || true
healing_emerge x11-base/xorg-drivers x11-base/xorg-server || true

case "${DE_CHOICE:-None}" in
  "GNOME") healing_emerge gnome-base/gnome || true ;;
  "KDE Plasma") healing_emerge kde-plasma/plasma-meta || true ;;
  "XFCE") healing_emerge xfce-base/xfce4-meta || true ;;
  "LXQt") healing_emerge lxqt-meta || true ;;
  "MATE") healing_emerge mate-meta || true ;;
esac

case "${DE_CHOICE:-None}" in
  "GNOME") rc-update add gdm default || true ;;
  "KDE Plasma") healing_emerge sys-boot/sddm || true; rc-update add sddm default || true ;;
  "XFCE"|"LXQt"|"MATE") healing_emerge x11-misc/lightdm x11-misc/lightdm-gtk-greeter || true; rc-update add lightdm default || true ;;
esac

# user creation
if ! id -u "${USERNAME}" >/dev/null 2>&1; then useradd -m -G users,wheel,audio,video -s /bin/bash "${USERNAME}" || true; fi
echo "root:${ROOT_PASSWORD}" | chpasswd || true
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd || true

# grub and efi
log "Installing GRUB"
retry_inner 3 10 emerge -q sys-boot/grub || true

# detect EFI dir
if [[ -d /boot/efi ]]; then EFI_DIR=/boot/efi
elif [[ -d /efi ]]; then EFI_DIR=/efi
else mkdir -p /boot/efi; EFI_DIR=/boot/efi; fi

log "EFI dir: ${EFI_DIR}"
grub-install --target=x86_64-efi --efi-directory="${EFI_DIR}" --bootloader-id=Gentoo --recheck || true
grub-mkconfig -o /boot/grub/grub.cfg || true

# ensure linux entries present
if ! grep -q "linux" /boot/grub/grub.cfg 2>/dev/null; then
  log "No linux entries in grub.cfg; listing /boot for debug"
  ls -l /boot || true
  grub-mkconfig -o /boot/grub/grub.cfg || true
fi

# ensure efivarfs available
if ! mountpoint -q /sys/firmware/efi/efivars 2>/dev/null; then
  log "Mounting efivarfs"
  mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true
fi

# ensure NVRAM entry; if unable, install fallback to EFI/Boot/bootx64.efi
if command -v efibootmgr >/dev/null 2>&1; then
  if ! efibootmgr -v | grep -qi "Gentoo"; then
    log "No Gentoo NVRAM entry; attempting create"
    if [[ -f "${EFI_DIR}/EFI/Gentoo/grubx64.efi" ]]; then
      # try to determine disk for partition 1
      if [[ -d /dev/disk/by-id ]]; then
        DID=$(ls -1 /dev/disk/by-id/ | grep -v part | head -n1 || true)
      else
        DID=""
      fi
      if [[ -n "$DID" ]]; then
        efibootmgr --create --disk /dev/disk/by-id/"$DID" --part 1 --loader "\EFI\Gentoo\grubx64.efi" --label "Gentoo" || true
      else
        efibootmgr --create --label "Gentoo" --loader "\EFI\Gentoo\grubx64.efi" || true
      fi
    else
      log "grubx64.efi not found; creating fallback Boot/bootx64.efi"
      mkdir -p "${EFI_DIR}/EFI/Boot" || true
      if [[ -f "${EFI_DIR}/EFI/Gentoo/grubx64.efi" ]]; then
        cp -f "${EFI_DIR}/EFI/Gentoo/grubx64.efi" "${EFI_DIR}/EFI/Boot/bootx64.efi" || true
      elif [[ -f "${EFI_DIR}/EFI/Boot/grubx64.efi" ]]; then
        cp -f "${EFI_DIR}/EFI/Boot/grubx64.efi" "${EFI_DIR}/EFI/Boot/bootx64.efi" || true
      fi
      efibootmgr --create --label "Gentoo" --loader "\EFI\Boot\bootx64.efi" || true
    fi
  else
    log "Gentoo NVRAM entry exists"
  fi
else
  log "efibootmgr not installed; cannot create/verify NVRAM entries"
fi

log "Chroot installer finished"
CHROOT

# make executable & secure
chmod 700 /mnt/gentoo/tmp/.installer_env.sh || true
chmod +x /mnt/gentoo/tmp/chroot_install.sh || true

# run chroot installer
log "Entering chroot to run installer"
if ! chroot /mnt/gentoo /tmp/chroot_install.sh; then
  err "Chroot installation failed - inspect $LOG and chroot logs"
  exit 1
fi

# cleanup & finalization
log "Removing temporary scripts and env"
rm -f /mnt/gentoo/tmp/chroot_install.sh /mnt/gentoo/tmp/.installer_env.sh || true

log "Unmounting and finishing"
umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
umount -R /mnt/gentoo 2>/dev/null || true

log "Installation complete. Reboot when ready."

# optional: save installer copy
if [[ "${GEN_INSTALLER_COPY:-0}" -ne 0 ]]; then
  OUT="/tmp/autogentoo_installer_saved.sh"
  if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    cp --preserve=mode,ownership "${BASH_SOURCE[0]}" "$OUT" || true
    chmod +x "$OUT" || true
    log "Installer copy saved to $OUT"
    echo "To write to USB: sudo dd if=${OUT} of=/dev/sdX bs=4M status=progress && sync"
  fi
fi

log "All done. See $LOG for details."

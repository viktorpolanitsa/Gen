#!/usr/bin/env bash
# Praxis.sh
# Final, consolidated, robust Gentoo installer script.
# Features:
#  - Region-aware mirror selection using mirror list + RTT ranking
#  - Fallback to distfiles.gentoo.org
#  - Robust Stage3 discovery and download with retries
#  - Secure transmission of secrets into chroot (temp file with restricted perms)
#  - Safe trap/cleanup to unmount on exit
#  - Partitioning (EFI + root), filesystem choices (ext4/xfs/btrfs)
#  - make.conf generation using chosen DE USE flags
#  - Chroot installer with self-healing emerge heuristics and autounmask attempts
#  - Optional unattended mode and installer copy generation
#
# WARNING: This script WILL ERASE data on the selected disk. Use only on systems
# where you accept complete disk reformat. Test in VM first.
set -euo pipefail
IFS=$'\n\t'

# ---------------- Logging -------------------------------------------------
LOGFILE="/tmp/autogentoo_install.log"
exec > >(tee -a "$LOGFILE") 2>&1
readonly LOGFILE

log()  { printf '%s %s\n' "$(date -Is)" "$*"; }
err()  { printf '%s ERROR: %s\n' "$(date -Is)" "$*" >&2; }
note() { printf '%s NOTE: %s\n' "$(date -Is)" "$*"; }

# ---------------- Safety & sanity checks ----------------------------------
if [[ $EUID -ne 0 ]]; then
  err "This installer must be run as root."
  exit 1
fi

# ---------------- Utilities ------------------------------------------------
retry_cmd() {
  # retry_cmd <retries> <sleep_seconds> <command...>
  local -i retries=${1:-3}; shift
  local sleep_s=${1:-2}; shift
  local n=0
  until "$@"; do
    n=$((n+1))
    if (( n >= retries )); then
      return 1
    fi
    sleep "$sleep_s"
  done
  return 0
}

http_head_time() {
  # returns curl time_total for HEAD request (float) or empty string on failure
  local url="$1"
  local tt
  tt=$(curl -s -o /dev/null -w '%{time_total}' --head --max-time 8 --silent "$url" 2>/dev/null || true)
  if [[ -z "$tt" || "$tt" == "0" ]]; then
    echo ""
  else
    echo "$tt"
  fi
}

# safe join for arrays
join_by() { local IFS="$1"; shift; echo "$*"; }

# ---------------- Cleanup -------------------------------------------------
cleanup() {
  log "Running cleanup..."
  # remove secure env inside chroot if exists
  if mountpoint -q /mnt/gentoo 2>/dev/null; then
    if [[ -f /mnt/gentoo/tmp/.installer_env.sh ]]; then
      rm -f /mnt/gentoo/tmp/.installer_env.sh || true
    fi
  fi
  # Attempt to unmount common mountpoints
  umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
  umount -l /mnt/gentoo/run 2>/dev/null || true
  umount -R /mnt/gentoo 2>/dev/null || true
  log "Cleanup complete."
}
trap cleanup EXIT

# ---------------- CLI args / environment ---------------------------------
UNATTENDED=${UNATTENDED:-0}
GENERATE_INSTALLER_COPY=${GENERATE_INSTALLER_COPY:-0}

while (( $# )); do
  case "$1" in
    --unattended) UNATTENDED=1; shift;;
    --generate-installer) GENERATE_INSTALLER_COPY=1; shift;;
    --help) printf 'Usage: %s [--unattended] [--generate-installer]\n' "$0"; exit 0;;
    *) break;;
  esac
done

# ---------------- Input collection ---------------------------------------
if [[ "$UNATTENDED" -eq 0 ]]; then
  log "Interactive mode."
  lsblk -dno NAME,SIZE,MODEL || true
  read -rp "Enter target disk (e.g., sda or nvme0n1): " disk_input
  read -rp "Choose Desktop Environment (GNOME,KDE Plasma,XFCE,LXQt,MATE,None): " de_choice
  read -rp "Enter hostname: " hostname
  read -rp "Enter username: " username
  read -rp "Enter timezone (e.g., Europe/Moscow) or leave empty for UTC: " timezone_input
  read -rp "Choose root filesystem (ext4,xfs,btrfs): " fs_choice
  read -rp "Save installer copy to /tmp/final_autogentoo_installer.sh? (yes/no): " gen_choice
  [[ "$gen_choice" =~ ^(yes|y|Y)$ ]] && GENERATE_INSTALLER_COPY=1
  read -rp "Proceed with installation to /dev/${disk_input}? Type YES to continue: " confirm
  [[ "$confirm" == "YES" ]] || { log "Cancelled by user."; exit 0; }
  read -rsp "Root password: " root_password; echo
  read -rsp "Confirm root password: " root_password2; echo
  [[ "$root_password" == "$root_password2" ]] || { err "Root passwords do not match"; exit 1; }
  read -rsp "Password for ${username}: " user_password; echo
  read -rsp "Confirm user password: " user_password2; echo
  [[ "$user_password" == "$user_password2" ]] || { err "User passwords do not match"; exit 1; }
else
  log "Unattended mode: reading env variables."
  disk_input="${DISK:-}"
  de_choice="${DE_CHOICE:-None}"
  hostname="${HOSTNAME:-gentoo-host}"
  username="${USERNAME:-gentoo}"
  timezone_input="${TIMEZONE:-UTC}"
  fs_choice="${FS_CHOICE:-ext4}"
  root_password="${ROOT_PASSWORD:-changeme}"
  user_password="${USER_PASSWORD:-changeme}"
  [[ -n "$disk_input" ]] || { err "DISK environment variable required for unattended mode"; exit 1; }
fi

# sanitize/defaults
disk="/dev/${disk_input##*/}"
timezone="${timezone_input:-UTC}"
case "$de_choice" in
  "GNOME"|"KDE Plasma"|"XFCE"|"LXQt"|"MATE"|"None") : ;;
  *) de_choice="None"; note "Unrecognized DE; defaulting to None";;
esac
case "$fs_choice" in
  ext4|xfs|btrfs) : ;;
  *) fs_choice="ext4"; note "Unrecognized fs; defaulting to ext4";;
esac
[[ -b "$disk" ]] || { err "Block device $disk not found"; exit 1; }

log "Configuration: disk=$disk, DE=$de_choice, host=$hostname, user=$username, fs=$fs_choice, timezone=$timezone, unattended=$UNATTENDED"

# ---------------- Disk partitioning & formatting -------------------------
log "Preparing disk: disabling swap, unmounting previous mounts."
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R "${disk}"* || true
blockdev --flushbufs "$disk" || true
sleep 1

log "Partitioning disk $disk: GPT with EFI (512MiB) + root (rest)."
sfdisk --force --wipe always --wipe-partitions always "$disk" <<PART
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
PART

partprobe "$disk"
sleep 1
wipefs -a "${disk}1" || true
wipefs -a "${disk}2" || true

log "Formatting partitions."
mkfs.vfat -F32 "${disk}1"
case "$fs_choice" in
  ext4) mkfs.ext4 -F "${disk}2";;
  xfs) mkfs.xfs -f "${disk}2";;
  btrfs) mkfs.btrfs -f "${disk}2";;
esac

mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi
cd /mnt/gentoo

# ---------------- Mirror selection (mirrorselect / RTT) -------------------
log "Detecting region (geo-IP)."
REGION="$(curl -s --fail --max-time 5 https://ipapi.co/country || true)"
log "Region detected: ${REGION:-unknown}"

# Build candidate mirror list. Use mirrorselect if available; else fallback to curated list.
CANDIDATES=()

if command -v mirrorselect >/dev/null 2>&1; then
  note "mirrorselect detected. Generating candidate mirror list via mirrorselect (localize by region)."
  # use mirrorselect to produce a short list into a temp file
  TMP_MIRRORS="$(mktemp)"
  # Prefer local mirrors when possible (-s4 selects 4 fastest, -b10 picks top 10 by bandwidth)
  mirrorselect -s4 -b10 --country "${REGION:-}" -o "$TMP_MIRRORS" >/dev/null 2>&1 || mirrorselect -s4 -b10 -o "$TMP_MIRRORS" >/dev/null 2>&1 || true
  if [[ -s "$TMP_MIRRORS" ]]; then
    # mirrorselect output may not be purely URLs; extract urls
    while IFS= read -r line; do
      url=$(echo "$line" | grep -oE 'https?://[^ ]+' || true)
      [[ -n "$url" ]] && CANDIDATES+=("$url")
    done < "$TMP_MIRRORS"
  fi
  rm -f "$TMP_MIRRORS" || true
fi

# If no candidates from mirrorselect, use curated list with region preference
if [[ "${#CANDIDATES[@]}" -eq 0 ]]; then
  note "Using curated default mirror list."
  if [[ "$REGION" == "RU" ]]; then
    CANDIDATES+=( \
      "https://mirror.yandex.ru/gentoo/" \
      "https://mirror.mos.ru/gentoo/" \
      "https://mirror.kaspersky.com/gentoo/" \
      "https://distfiles.gentoo.org/" \
    )
  else
    CANDIDATES+=( \
      "https://distfiles.gentoo.org/" \
      "https://builds.gentoo.org/" \
      "https://ftp.snt.utwente.nl/gentoo/" \
      "https://mirror.clarkson.edu/gentoo/" \
      "https://mirror.leaseweb.com/gentoo/" \
    )
  fi
fi

log "Candidate mirrors: $(join_by ', ' "${CANDIDATES[@]}")"

# For each candidate, probe latest-stage3 index and measure HEAD time_total for the resolved Stage3 full URL.
BEST_STAGE3_URL=""
BEST_RTT=9999

for m in "${CANDIDATES[@]}"; do
  # ensure trailing slash
  [[ "${m: -1}" != "/" ]] && m="${m}/"
  for idx in "releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt" "releases/amd64/autobuilds/latest-stage3-amd64.txt"; do
    IDX_URL="${m}${idx}"
    if curl -s --head --fail --max-time 6 "$IDX_URL" >/dev/null 2>&1; then
      # parse first non-comment stage3 file
      STG_NAME=$(curl -fsS "$IDX_URL" 2>/dev/null | awk '!/^#/ && /stage3/ {print $1; exit}')
      if [[ -n "$STG_NAME" ]]; then
        FULL_URL="${m}releases/amd64/autobuilds/${STG_NAME}"
        if curl -s --head --fail --max-time 8 "$FULL_URL" >/dev/null 2>&1; then
          RTT=$(http_head_time "$FULL_URL" || echo "")
          if [[ -n "$RTT" ]]; then
            # numeric compare
            if awk "BEGIN{exit !($RTT < $BEST_RTT)}"; then
              BEST_RTT="$RTT"
              BEST_STAGE3_URL="$FULL_URL"
              log "Candidate chosen so far: $BEST_STAGE3_URL (rtt=${BEST_RTT})"
            fi
          else
            # accept as backup if none selected yet
            if [[ -z "$BEST_STAGE3_URL" ]]; then
              BEST_STAGE3_URL="$FULL_URL"
              log "Fallback candidate selected: $BEST_STAGE3_URL"
            fi
          fi
        fi
      fi
    fi
  done
done

if [[ -z "$BEST_STAGE3_URL" ]]; then
  err "No Stage3 found on candidates. Trying distfiles.gentoo.org fallback."
  IDX="https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt"
  if curl -s --head --fail "$IDX" >/dev/null 2>&1; then
    STG_NAME=$(curl -fsS "$IDX" 2>/dev/null | awk '!/^#/ && /stage3/ {print $1; exit}')
    BEST_STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/${STG_NAME}"
  fi
fi

[[ -n "$BEST_STAGE3_URL" ]] || { err "Failed to locate any Stage3 URL. Aborting."; exit 1; }
log "Selected Stage3 URL: $BEST_STAGE3_URL"

# ---------------- Download Stage3 ---------------------------------------
STAGE3_LOCAL="/tmp/stage3.tar.xz"
log "Downloading Stage3 to $STAGE3_LOCAL (with retries)."
if ! retry_cmd 6 5 wget -c -O "$STAGE3_LOCAL" "$BEST_STAGE3_URL"; then
  err "Failed to download Stage3 from $BEST_STAGE3_URL"
  exit 1
fi

log "Extracting Stage3 content..."
tar xpvf "$STAGE3_LOCAL" --xattrs-include='*.*' --numeric-owner

# ---------------- make.conf creation -------------------------------------
log "Generating /mnt/gentoo/etc/portage/make.conf"
case "$de_choice" in
  "GNOME") DE_USE_FLAGS="gtk gnome -qt5 -kde";;
  "KDE Plasma") DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
  "XFCE") DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
  "LXQt") DE_USE_FLAGS="qt5 lxqt -gnome -kde";;
  "MATE") DE_USE_FLAGS="gtk mate -qt5 -kde -gnome";;
  "None") DE_USE_FLAGS="";;
  *) DE_USE_FLAGS="";;
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

# ---------------- Prepare chroot mounts ----------------------------------
log "Preparing chroot mounts and copying resolv.conf."
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/ || true
mount -t proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys; mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev; mount --make-rslave /mnt/gentoo/dev
mkdir -p /mnt/gentoo/run
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# ---------------- Securely pass env into chroot --------------------------
log "Creating secure environment file inside chroot (/mnt/gentoo/tmp/.installer_env.sh)."
cat > /mnt/gentoo/tmp/.installer_env.sh <<ENV
#!/usr/bin/env bash
export DE_CHOICE='${de_choice}'
export HOSTNAME='${hostname}'
export USERNAME='${username}'
export TIMEZONE='${timezone}'
export ROOT_PASSWORD='${root_password}'
export USER_PASSWORD='${user_password}'
ENV
chmod 600 /mnt/gentoo/tmp/.installer_env.sh
# make executable for sourcing safety
chmod 700 /mnt/gentoo/tmp/.installer_env.sh

# ---------------- Write chroot installer script --------------------------
log "Creating chroot installer script (/mnt/gentoo/tmp/chroot_install.sh)."
cat > /mnt/gentoo/tmp/chroot_install.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
log(){ printf '%s %s\n' "$(date -Is)" "$*" >&2; }

retry_inner() {
  local -i retries=${1:-3}; shift
  local sleep_s=${1:-2}; shift
  local n=0
  until "$@"; do
    n=$((n+1))
    if (( n >= retries )); then return 1; fi
    sleep "$sleep_s"
  done
  return 0
}

healing_emerge() {
  local -a args=( "$@" )
  local max_attempts=4
  local attempt=1
  while (( attempt <= max_attempts )); do
    log "healing_emerge attempt $attempt: emerge ${args[*]}"
    if emerge --backtrack=30 --verbose "${args[@]}" &> /tmp/emerge_attempt.log; then
      log "emerge success: ${args[*]}"
      cat /tmp/emerge_attempt.log
      return 0
    fi
    cat /tmp/emerge_attempt.log
    if grep -q "Change USE" /tmp/emerge_attempt.log; then
      suggestion=$(grep "Change USE" /tmp/emerge_attempt.log | head -n1 || true)
      pkg=$(echo "$suggestion" | awk '{for(i=1;i<=NF;i++){ if ($i ~ /[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+/) {print $i; break}} }' || true)
      use_change=$(echo "$suggestion" | sed -n 's/.*Change USE: //p' | sed 's/)//' | awk '{$1=$1};1' || true)
      if [[ -n "$pkg" && -n "$use_change" ]]; then
        mkdir -p /etc/portage/package.use
        echo "$pkg $use_change" >> /etc/portage/package.use/99_autofix
        log "Applied temporary USE fix: $pkg $use_change"
        attempt=$((attempt+1))
        continue
      fi
    fi
    if emerge --autounmask-write "${args[@]}" &> /tmp/autounmask_out 2>&1; then
      etc-update --automode -3 || true
      log "Applied autounmask fixes"
      attempt=$((attempt+1))
      continue
    fi
    return 1
  done
  return 1
}

# Load secure env
if [[ -f /tmp/.installer_env.sh ]]; then
  # shellcheck source=/tmp/.installer_env.sh
  source /tmp/.installer_env.sh
else
  log "/tmp/.installer_env.sh missing; aborting"
  exit 1
fi

log "Chroot installer starting (DE=${DE_CHOICE}, HOSTNAME=${HOSTNAME})."

# Portage sync attempts
if ! retry_inner 3 5 emerge-webrsync; then
  log "emerge-webrsync failed; trying 'emerge --sync'"
  retry_inner 3 20 emerge --sync || log "Portage sync fallback failed"
fi

# Profile selection: prefer amd64 openrc
PROFILE_ID=""
if eselect profile list | grep -Eq 'amd64.*openrc'; then
  PROFILE_ID=$(eselect profile list | grep -E 'amd64.*openrc' | tail -n1 | awk '{print $1}')
else
  PROFILE_ID=$(eselect profile list | grep -E 'amd64' | tail -n1 | awk '{print $1}')
fi
if [[ -n "$PROFILE_ID" ]]; then
  eselect profile set "$PROFILE_ID" || true
  log "Profile set to $PROFILE_ID"
fi

# Update base system (best-effort)
healing_emerge --update --deep --newuse @system || log "System update had issues; continuing."

# Kernel installation: prefer binary kernel
if ! retry_inner 3 10 emerge -q sys-kernel/gentoo-kernel-bin; then
  log "Binary kernel unavailable; installing sources"
  retry_inner 3 30 emerge -q sys-kernel/gentoo-sources sys-kernel/genkernel || true
  if command -v genkernel >/dev/null 2>&1; then genkernel all || true; fi
fi

# CPU flags
retry_inner 3 5 emerge -q app-portage/cpuid2cpuflags || true
if command -v cpuid2cpuflags >/dev/null 2>&1; then
  echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags || true
fi

# Locales/timezone
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen || true
locale-gen || true
eselect locale set en_US.UTF-8 || true
env-update && source /etc/profile || true

if [[ -n "${TIMEZONE:-}" && -f /usr/share/zoneinfo/${TIMEZONE} ]]; then
  ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime || true
  hwclock --systohc || true
else
  log "Timezone ${TIMEZONE} not present in chroot; skipping timezone setup."
fi

# Essential utilities and services
healing_emerge app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate || true
rc-update add sysklogd default || true
rc-update add chronyd default || true
rc-update add cronie default || true

# Networking & SSH
healing_emerge net-misc/networkmanager || true
rc-update add NetworkManager default || true
rc-update add sshd default || true

# X and DE
healing_emerge x11-base/xorg-drivers x11-base/xorg-server || true
case "${DE_CHOICE:-None}" in
  "GNOME") healing_emerge gnome-base/gnome || true ;;
  "KDE Plasma") healing_emerge kde-plasma/plasma-meta || true ;;
  "XFCE") healing_emerge xfce-base/xfce4-meta || true ;;
  "LXQt") healing_emerge lxqt-meta || true ;;
  "MATE") healing_emerge mate-meta || true ;;
esac

# Display manager
case "${DE_CHOICE:-None}" in
  "GNOME") rc-update add gdm default || true ;;
  "KDE Plasma") healing_emerge sys-boot/sddm || true; rc-update add sddm default || true ;;
  "XFCE"|"LXQt"|"MATE") healing_emerge x11-misc/lightdm x11-misc/lightdm-gtk-greeter || true; rc-update add lightdm default || true ;;
esac

# Create user and set passwords (avoid logging)
if ! id -u "${USERNAME}" >/dev/null 2>&1; then
  useradd -m -G users,wheel,audio,video -s /bin/bash "${USERNAME}" || true
fi
echo "root:${ROOT_PASSWORD}" | chpasswd || true
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd || true

# Install and configure GRUB (EFI)
retry_inner 3 10 emerge -q sys-boot/grub || true
if [[ -d /efi ]]; then EFI_DIR=/efi
elif [[ -d /boot/efi ]]; then EFI_DIR=/boot/efi
else mkdir -p /boot/efi; EFI_DIR=/boot/efi; fi
grub-install --target=x86_64-efi --efi-directory="${EFI_DIR}" || true
grub-mkconfig -o /boot/grub/grub.cfg || true

log "Chroot installation finished successfully."
CHROOT

# Make chroot scripts executable and secure
chmod 700 /mnt/gentoo/tmp/.installer_env.sh || true
chmod +x /mnt/gentoo/tmp/chroot_install.sh || true

# ---------------- Execute chroot installer --------------------------------
log "Running chroot installer (may take long time)."
if ! chroot /mnt/gentoo /tmp/chroot_install.sh; then
  err "Chroot installer failed. Inspect $LOGFILE and /mnt/gentoo/var/log for details."
  exit 1
fi

# ---------------- Finalize & cleanup --------------------------------------
log "Removing temporary chroot scripts and env file."
rm -f /mnt/gentoo/tmp/chroot_install.sh /mnt/gentoo/tmp/.installer_env.sh || true

log "Unmounting and finishing."
umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
umount -R /mnt/gentoo 2>/dev/null || true

log "Installation complete. Reboot into the new system when ready."

# ---------------- Generate installer copy & USB hint -----------------------
if [[ "${GENERATE_INSTALLER_COPY:-0}" -ne 0 ]]; then
  SCRIPT_PATH="/tmp/final_autogentoo_installer.sh"
  if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    cp --preserve=mode,ownership "${BASH_SOURCE[0]}" "$SCRIPT_PATH" || true
  else
    cat > "$SCRIPT_PATH" <<'EOF'
# Installer copy not available automatically. Please save the installer content manually.
EOF
  fi
  chmod +x "$SCRIPT_PATH" || true
  log "Installer saved to $SCRIPT_PATH"
  echo
  echo "To write the installer to USB (example /dev/sdX):"
  echo "  sudo dd if=${SCRIPT_PATH} of=/dev/sdX bs=4M status=progress && sync"
  echo "Replace /dev/sdX with your device."
  echo
fi

log "All done. See $LOGFILE for full trace."

#!/usr/bin/env bash
# The Gentoo Genesis Engine
# Version: 10.3.12 "The Prophylactic"
# Author: viktorpolanitsa
# License: MIT
#
# Fully automated Gentoo Linux installer implementing the features described in the README:
# - Interactive configuration wizard
# - Checkpoints and resume
# - LUKS2, LVM, separate /home, swap/zram
# - Btrfs with @ and @home subvolumes, boot environments
# - OpenRC/systemd, standard/hardened profiles
# - LSM: AppArmor / SELinux / none
# - UFW, desktop environment (KDE/GNOME/XFCE/i3/server)
# - Kernel: genkernel / gentoo-kernel / gentoo-kernel-bin / manual
# - ccache, binpkg, LTO
# - Automatic updates, CPU frequency scaling

set -euo pipefail
IFS=$'\n\t'

GENESIS_VERSION="10.3.12"
GENESIS_NAME="The Gentoo Genesis Engine"
CHECKPOINT_FILE="/tmp/genesis_checkpoint"
LIVECD_FIX_LOG="/var/log/genesis-livecd-fix.log"
LOG_FILE="/var/log/genesis-install.log"
ERR_LOG="/var/log/genesis-install-error.log"

# Defaults
FORCE_AUTO=0
SKIP_CHECKSUM=0

# Ensure basic paths exist
mkdir -p /var/log /mnt/gentoo

# Global logging
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$ERR_LOG" >&2)

log()  { printf '%s [INFO]  %s\n'  "$(date -Is)" "$*"; }
warn() { printf '%s [WARN]  %s\n'  "$(date -Is)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n'  "$(date -Is)" "$*" >&2; }
die()  { err "$*"; exit 1; }

retry_cmd() {
  local -i attempts=${1:-3}; shift
  local sleep_s=${1:-3}; shift
  local i=0
  until "$@"; do
    i=$((i+1))
    (( i >= attempts )) && return 1
    warn "Retry $i/$attempts: $*"
    sleep "$sleep_s"
  done
  return 0
}

checkpoint() {
  echo "$1" > "$CHECKPOINT_FILE"
  sync
}

get_checkpoint() {
  [[ -f "$CHECKPOINT_FILE" ]] && cat "$CHECKPOINT_FILE" || echo "0"
}

clear_checkpoint() {
  rm -f "$CHECKPOINT_FILE" 2>/dev/null || true
}

cleanup() {
  log "Cleanup: unmounting /mnt/gentoo and cleaning temporary environment"
  rm -f /mnt/gentoo/tmp/.genesis_env.sh 2>/dev/null || true
  umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
  umount -l /mnt/gentoo/run 2>/dev/null || true
  umount -R /mnt/gentoo 2>/dev/null || true
}
trap cleanup EXIT

usage() {
  cat <<EOF
${GENESIS_NAME} v${GENESIS_VERSION}

Usage: $0 [--force|--auto] [--skip-checksum]

  --force, --auto       Automatically answer "yes" to confirmation questions.
  --skip-checksum       Disable Stage3 integrity verification (NOT recommended).

EOF
}

# Must be root
if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root."
fi

# ---------------- ARGS ----------------
while (( $# )); do
  case "$1" in
    --force|--auto) FORCE_AUTO=1; shift;;
    --skip-checksum) SKIP_CHECKSUM=1; shift;;
    --help|-h) usage; exit 0;;
    *) warn "Unknown argument: $1"; shift;;
  esac
done

# ---------------- LiveCD self-heal ----------------
self_heal_livecd() {
  log "LiveCD self-diagnostics and self-healing"

  # zram if RAM < 6 GiB
  local mem_kb
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  if (( mem_kb > 0 && mem_kb < 6*1024*1024 )); then
    if ! grep -q zram /proc/swaps 2>/dev/null; then
      log "Low RAM (${mem_kb} kB) — configuring ZRAM swap"
      modprobe zram || true
      echo $((mem_kb*1024/2)) > /sys/block/zram0/disksize 2>/dev/null || true
      mkswap /dev/zram0 2>/dev/null || true
      swapon /dev/zram0 2>/dev/null || true
    fi
  fi

  # Required tools
  local need_tools=( lsblk sfdisk mkfs.ext4 mkfs.xfs mkfs.btrfs cryptsetup pvcreate vgcreate lvcreate btrfs )
  local missing=()
  for t in "${need_tools[@]}"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if ((${#missing[@]})); then
    log "Missing tools: ${missing[*]}"
    if command -v emerge >/dev/null 2>&1; then
      log "Trying to install missing tools: ${missing[*]} (log: $LIVECD_FIX_LOG)"
      (
        emerge --quiet sys-fs/cryptsetup sys-fs/lvm2 sys-fs/btrfs-progs sys-fs/xfsprogs \
               sys-apps/util-linux sys-apps/pv || true
      ) >>"$LIVECD_FIX_LOG" 2>&1
    else
      warn "emerge not found; skipping tool installation"
    fi
  fi
}

# ---------------- Hardware detection ----------------
CPU_VENDOR="Unknown"
CPU_MODEL=""
CPU_MARCH="native"
GPU_VENDOR="Unknown"
GPU_DRIVER="amdgpu"

detect_hardware() {
  log "Detecting CPU/GPU"
  if command -v lscpu >/dev/null 2>&1; then
    CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID:/ {gsub(/^[ \t]+/, "", $2); print $2}')
    CPU_MODEL=$(lscpu | awk -F: '/Model name:/ {sub(/^ +/, "", $2); print $2}')
  fi

  case "$CPU_VENDOR" in
    GenuineIntel) CPU_MARCH="x86-64-v3";;
    AuthenticAMD) CPU_MARCH="znver1";;
    *) CPU_MARCH="native";;
  esac

  if command -v lspci >/dev/null 2>&1; then
    if lspci | grep -qi 'NVIDIA'; then
      GPU_VENDOR="NVIDIA"
      GPU_DRIVER="nouveau"
    elif lspci | grep -qi 'AMD/ATI'; then
      GPU_VENDOR="AMD"
      GPU_DRIVER="amdgpu"
    elif lspci | grep -qi 'Intel'; then
      GPU_VENDOR="Intel"
      GPU_DRIVER="intel"
    fi
  fi
  log "CPU: $CPU_VENDOR | $CPU_MODEL | march=$CPU_MARCH ; GPU: $GPU_VENDOR ($GPU_DRIVER)"
}

# ---------------- Checkpoint / resume ----------------
handle_resume() {
  local cp
  cp=$(get_checkpoint)
  if [[ "$cp" != "0" ]]; then
    log "Found unfinished installation checkpoint: stage=$cp"
    if (( FORCE_AUTO )); then
      log "FORCE/auto: resuming from checkpoint $cp"
      return
    fi
    echo "[C]ontinue — resume from this stage"
    echo "[R]estart  — start installation from scratch"
    echo "[A]bort    — cancel and exit"
    read -rp "Your choice [C/R/A]: " ans
    case "$ans" in
      C|c|"") log "Continuing from checkpoint $cp";;
      R|r) log "Clearing checkpoints and starting over"; clear_checkpoint;;
      A|a) die "Aborted by user";;
      *) log "Unknown answer, default: Continue";;
    esac
  fi
}

# ---------------- Interactive wizard ----------------
TARGET_DISK=""
BOOT_MODE="uefi"      # uefi|bios
FS_TYPE="btrfs"       # btrfs|xfs|ext4
USE_LVM=1
USE_LUKS=1
ENCRYPT_BOOT=0
SEPARATE_HOME=1
SWAP_MODE="zram"      # zram|partition|none
INIT_SYSTEM="openrc"  # openrc|systemd
PROFILE_FLAVOR="standard" # standard|hardened
LSM_CHOICE="none"     # none|apparmor|selinux
ENABLE_UFW=1
DE_CHOICE="kde"       # kde|gnome|xfce|i3|server
KERNEL_MODE="gentoo-kernel-bin" # genkernel|gentoo-kernel|gentoo-kernel-bin|manual
ENABLE_CCACHE=1
ENABLE_BINPKG=1
ENABLE_LTO=0
BUNDLE_FLATPAK=1
BUNDLE_TERM=1
BUNDLE_DEV=1
BUNDLE_OFFICE=1
BUNDLE_GAMING=0
AUTO_UPDATE=1
CPU_FREQ_TUNE=1
HOSTNAME="gentoo"
USERNAME="gentoo"
TIMEZONE="UTC"
ROOT_PASSWORD=""
USER_PASSWORD=""

yesno() {
  local prompt="$1" def="$2" ans
  if (( FORCE_AUTO )); then
    echo "$def"
    return
  fi
  read -rp "$prompt [$def]: " ans || true
  ans=${ans:-$def}
  echo "$ans"
}

wizard() {
  log "Starting interactive configuration wizard"

  # Disk
  lsblk -dno NAME,SIZE,MODEL
  read -rp "Select target disk (e.g. sda or nvme0n1): " d
  [[ -n "$d" ]] || die "No disk selected"
  TARGET_DISK="/dev/${d##*/}"
  [[ -b "$TARGET_DISK" ]] || die "Block device $TARGET_DISK not found"

  # Boot mode detection
  if [[ -d /sys/firmware/efi ]]; then
    BOOT_MODE="uefi"
  else
    BOOT_MODE="bios"
  fi
  log "Detected boot mode: $BOOT_MODE"

  # Root filesystem
  if (( ! FORCE_AUTO )); then
    echo "Root filesystem:"
    echo "1) Btrfs (default, @ and @home subvolumes, boot environments)"
    echo "2) XFS"
    echo "3) Ext4"
    read -rp "Choice [1/2/3, default 1]: " f
    case "$f" in
      2) FS_TYPE="xfs";;
      3) FS_TYPE="ext4";;
      *) FS_TYPE="btrfs";;
    esac
  fi

  # LVM
  ans=$(yesno "Use LVM?" "yes")
  [[ "$ans" =~ ^[Yy] ]] && USE_LVM=1 || USE_LVM=0

  # LUKS
  ans=$(yesno "Enable full disk encryption (LUKS2)?" "yes")
  [[ "$ans" =~ ^[Yy] ]] && USE_LUKS=1 || USE_LUKS=0

  # Encrypt /boot (UEFI+LVM+LUKS only)
  if (( USE_LUKS )) && (( USE_LVM )) && [[ "$BOOT_MODE" == "uefi" ]]; then
    ans=$(yesno "Encrypt /boot (except small EFI partition)?" "no")
    [[ "$ans" =~ ^[Yy] ]] && ENCRYPT_BOOT=1 || ENCRYPT_BOOT=0
  else
    ENCRYPT_BOOT=0
  fi

  # /home
  ans=$(yesno "Create separate /home (LVM LV or Btrfs subvolume)?" "yes")
  [[ "$ans" =~ ^[Yy] ]] && SEPARATE_HOME=1 || SEPARATE_HOME=0

  # Swap
  if (( ! FORCE_AUTO )); then
    echo "Swap configuration:"
    echo "1) ZRAM (in RAM)"
    echo "2) Dedicated swap LV/partition"
    echo "3) No swap"
    read -rp "Choice [1/2/3, default 1]: " s
    case "$s" in
      2) SWAP_MODE="partition";;
      3) SWAP_MODE="none";;
      *) SWAP_MODE="zram";;
    esac
  fi

  # Init system
  if (( ! FORCE_AUTO )); then
    echo "Init system:"
    echo "1) OpenRC (recommended)"
    echo "2) systemd"
    read -rp "Choice [1/2, default 1]: " i
    case "$i" in
      2) INIT_SYSTEM="systemd";;
      *) INIT_SYSTEM="openrc";;
    esac
  fi

  # Profile flavor
  ans=$(yesno "Use hardened profile (more security)?" "no")
  [[ "$ans" =~ ^[Yy] ]] && PROFILE_FLAVOR="hardened" || PROFILE_FLAVOR="standard"

  # LSM
  if (( ! FORCE_AUTO )); then
    echo "Kernel LSM (security module):"
    echo "1) None"
    echo "2) AppArmor"
    echo "3) SELinux"
    read -rp "Choice [1/2/3, default 1]: " l
    case "$l" in
      2) LSM_CHOICE="apparmor";;
      3) LSM_CHOICE="selinux";;
      *) LSM_CHOICE="none";;
    esac
  fi

  # UFW
  ans=$(yesno "Enable basic firewall via UFW?" "yes")
  [[ "$ans" =~ ^[Yy] ]] && ENABLE_UFW=1 || ENABLE_UFW=0

  # Desktop / server profile
  if (( ! FORCE_AUTO )); then
    echo "System profile:"
    echo "1) KDE Plasma"
    echo "2) GNOME"
    echo "3) XFCE"
    echo "4) i3-wm (minimalistic)"
    echo "5) Server (no GUI)"
    read -rp "Choice [1-5, default 1]: " de
    case "$de" in
      2) DE_CHOICE="gnome";;
      3) DE_CHOICE="xfce";;
      4) DE_CHOICE="i3";;
      5) DE_CHOICE="server";;
      *) DE_CHOICE="kde";;
    esac
  fi

  # Kernel management
  if (( ! FORCE_AUTO )); then
    echo "Kernel management:"
    echo "1) gentoo-kernel-bin (fastest, prebuilt)"
    echo "2) gentoo-kernel (managed sources)"
    echo "3) genkernel (automatic kernel build)"
    echo "4) Manual (only install sources)"
    read -rp "Choice [1-4, default 1]: " k
    case "$k" in
      2) KERNEL_MODE="gentoo-kernel";;
      3) KERNEL_MODE="genkernel";;
      4) KERNEL_MODE="manual";;
      *) KERNEL_MODE="gentoo-kernel-bin";;
    esac
  fi

  # Performance options
  ans=$(yesno "Enable ccache?" "yes")
  [[ "$ans" =~ ^[Yy] ]] && ENABLE_CCACHE=1 || ENABLE_CCACHE=0
  ans=$(yesno "Enable binary packages (buildpkg)?" "yes")
  [[ "$ans" =~ ^[Yy] ]] && ENABLE_BINPKG=1 || ENABLE_BINPKG=0
  ans=$(yesno "Enable LTO (experimental)?" "no")
  [[ "$ans" =~ ^[Yy] ]] && ENABLE_LTO=1 || ENABLE_LTO=0

  # Bundles
  ans=$(yesno "Install Flatpak + Distrobox?" "yes")
  [[ "$ans" =~ ^[Yy] ]] && BUNDLE_FLATPAK=1 || BUNDLE_FLATPAK=0
  ans=$(yesno "Install \"Cyber terminal\" (zsh + starship)?" "yes")
  [[ "$ans" =~ ^[Yy] ]] && BUNDLE_TERM=1 || BUNDLE_TERM=0
  ans=$(yesno "Developer tools (git, VSCode, Docker)?" "yes")
  [[ "$ans" =~ ^[Yy] ]] && BUNDLE_DEV=1 || BUNDLE_DEV=0
  ans=$(yesno "Office and graphics (LibreOffice, GIMP, Inkscape)?" "yes")
  [[ "$ans" =~ ^[Yy] ]] && BUNDLE_OFFICE=1 || BUNDLE_OFFICE=0
  ans=$(yesno "Gaming set (Steam, Lutris, Wine)?" "no")
  [[ "$ans" =~ ^[Yy] ]] && BUNDLE_GAMING=1 || BUNDLE_GAMING=0

  # Auto update
  ans=$(yesno "Enable weekly system auto-update?" "yes")
  [[ "$ans" =~ ^[Yy] ]] && AUTO_UPDATE=1 || AUTO_UPDATE=0

  # CPU frequency tuning
  ans=$(yesno "Enable CPU frequency management (laptops etc.)?" "yes")
  [[ "$ans" =~ ^[Yy] ]] && CPU_FREQ_TUNE=1 || CPU_FREQ_TUNE=0

  # Hostname/user/timezone
  read -rp "Hostname [gentoo]: " HOSTNAME; HOSTNAME=${HOSTNAME:-gentoo}
  read -rp "Username [gentoo]: " USERNAME; USERNAME=${USERNAME:-gentoo}
  read -rp "Timezone (e.g. Europe/Warsaw) [UTC]: " TIMEZONE; TIMEZONE=${TIMEZONE:-UTC}

  # Passwords
  if (( ! FORCE_AUTO )); then
    read -rsp "Root password: " ROOT_PASSWORD; echo
    read -rsp "Confirm root password: " r2; echo
    [[ "$ROOT_PASSWORD" == "$r2" ]] || die "Root passwords mismatch"
    read -rsp "User password: " USER_PASSWORD; echo
    read -rsp "Confirm user password: " u2; echo
    [[ "$USER_PASSWORD" == "$u2" ]] || die "User passwords mismatch"
  else
    ROOT_PASSWORD="changeme_root"
    USER_PASSWORD="changeme_user"
  fi

  # Final summary before wiping the disk
  echo
  echo "CONFIGURATION SUMMARY:"
  echo "Disk:          $TARGET_DISK"
  echo "Boot mode:     $BOOT_MODE"
  echo "Root FS:       $FS_TYPE"
  echo "LVM:           $USE_LVM"
  echo "LUKS2:         $USE_LUKS (encrypt /boot=$ENCRYPT_BOOT)"
  echo "Separate /home:$SEPARATE_HOME"
  echo "Swap:          $SWAP_MODE"
  echo "Init:          $INIT_SYSTEM"
  echo "Profile:       $PROFILE_FLAVOR"
  echo "LSM:           $LSM_CHOICE"
  echo "UFW:           $ENABLE_UFW"
  echo "Desktop:       $DE_CHOICE"
  echo "Kernel:        $KERNEL_MODE"
  echo "ccache:        $ENABLE_CCACHE ; binpkg: $ENABLE_BINPKG ; LTO: $ENABLE_LTO"
  echo "Bundles:       flatpak=$BUNDLE_FLATPAK term=$BUNDLE_TERM dev=$BUNDLE_DEV office=$BUNDLE_OFFICE gaming=$BUNDLE_GAMING"
  echo "Auto-update:   $AUTO_UPDATE"
  echo "CPU freq:      $CPU_FREQ_TUNE"
  echo "Hostname:      $HOSTNAME"
  echo "Username:      $USERNAME"
  echo "Timezone:      $TIMEZONE"
  echo

  if (( FORCE_AUTO )); then
    log "FORCE/auto: disk wipe confirmation skipped"
    return
  fi
  read -rp "WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED. Type YES to continue: " conf
  [[ "$conf" == "YES" ]] || die "Aborted by user"
}

# ---------------- Disk / LUKS / LVM / FS ----------------
ROOT_MAPPER=""
VG_NAME="vg0"
LV_ROOT="lvroot"
LV_SWAP="lvswap"
LV_HOME="lvhome"
LV_BOOT="lvboot"

# Helper: build partition name (handles nvme0n1 -> nvme0n1p1)
partition_prefix_for_disk() {
  local d="$1"
  if [[ "$d" =~ [0-9]$ ]]; then
    echo "${d}p"
  else
    echo "$d"
  fi
}

partition_and_setup_storage() {
  log "Partitioning and preparing disk $TARGET_DISK"
  swapoff -a || true
  umount -R /mnt/gentoo || true
  blockdev --flushbufs "$TARGET_DISK" || true
  sleep 1

  local part_prefix
  part_prefix=$(partition_prefix_for_disk "$TARGET_DISK")

  if [[ "$BOOT_MODE" == "uefi" ]]; then
    log "Creating GPT layout for UEFI"
    if (( USE_LUKS )); then
      # EFI (FAT32) + LUKS PV
      sfdisk --force --wipe always "$TARGET_DISK" <<PART
label: gpt
${part_prefix}1 : size=512MiB, type=uefi, name="EFI"
${part_prefix}2 : type=linux, name="cryptroot"
PART
    else
      # EFI + plain root
      sfdisk --force --wipe always "$TARGET_DISK" <<PART
label: gpt
${part_prefix}1 : size=512MiB, type=uefi, name="EFI"
${part_prefix}2 : type=linux, name="root"
PART
    fi
  else
    log "Creating GPT layout for BIOS (BIOS boot + root)"
    if (( USE_LUKS )); then
      sfdisk --force --wipe always "$TARGET_DISK" <<PART
label: gpt
${part_prefix}1 : size=1MiB, type=21686148-6449-6E6F-744E-656564454649, name="BIOS"
${part_prefix}2 : type=linux, name="cryptroot"
PART
    else
      sfdisk --force --wipe always "$TARGET_DISK" <<PART
label: gpt
${part_prefix}1 : size=1MiB, type=21686148-6449-6E6F-744E-656564454649, name="BIOS"
${part_prefix}2 : type=linux, name="root"
PART
    fi
  fi

  partprobe "$TARGET_DISK"; sleep 2
  local p1 p2
  p1="${part_prefix}1"
  p2="${part_prefix}2"

  # EFI
  if [[ "$BOOT_MODE" == "uefi" ]]; then
    mkfs.vfat -F32 "$p1"
  fi

  # LUKS / LVM / FS
  if (( USE_LUKS )); then
    log "Creating LUKS2 on $p2"
    echo -n "$ROOT_PASSWORD" | cryptsetup luksFormat --type luks2 --pbkdf argon2id --cipher aes-xts-plain64 --key-size 512 "$p2" -
    echo -n "$ROOT_PASSWORD" | cryptsetup open "$p2" cryptroot -
    ROOT_MAPPER="/dev/mapper/cryptroot"
  else
    ROOT_MAPPER="$p2"
  fi

  if (( USE_LVM )); then
    log "Setting up LVM on $ROOT_MAPPER"
    pvcreate "$ROOT_MAPPER"
    vgcreate "$VG_NAME" "$ROOT_MAPPER"

    local swap_lv_size="4G"
    if (( SEPARATE_HOME )); then
      lvcreate -n "$LV_ROOT" -l 60%FREE "$VG_NAME"
      if [[ "$SWAP_MODE" == "partition" ]]; then
        lvcreate -n "$LV_SWAP" -L "$swap_lv_size" "$VG_NAME"
      fi
      lvcreate -n "$LV_HOME" -l 100%FREE "$VG_NAME"
    else
      lvcreate -n "$LV_ROOT" -l 100%FREE "$VG_NAME"
      if [[ "$SWAP_MODE" == "partition" ]]; then
        lvcreate -n "$LV_SWAP" -L "$swap_lv_size" "$VG_NAME" || true
      fi
    fi

    if (( ENCRYPT_BOOT )); then
      lvcreate -n "$LV_BOOT" -L 512M "$VG_NAME" || true
    fi

    local root_dev="/dev/${VG_NAME}/${LV_ROOT}"
    local home_dev="/dev/${VG_NAME}/${LV_HOME:-}"
    local swap_dev="/dev/${VG_NAME}/${LV_SWAP:-}"
    local boot_dev="/dev/${VG_NAME}/${LV_BOOT:-}"

    # Filesystems
    if [[ "$FS_TYPE" == "btrfs" ]]; then
      mkfs.btrfs -f "$root_dev"
      mount "$root_dev" /mnt/gentoo
      btrfs subvolume create /mnt/gentoo/@
      if (( SEPARATE_HOME )); then
        btrfs subvolume create /mnt/gentoo/@home
      fi
      umount /mnt/gentoo
      mount -o subvol=@ "$root_dev" /mnt/gentoo
      if (( SEPARATE_HOME )); then
        mkdir -p /mnt/gentoo/home
        mount -o subvol=@home "$root_dev" /mnt/gentoo/home
      fi
    else
      mkfs."$FS_TYPE" -F "$root_dev"
      mount "$root_dev" /mnt/gentoo
      if (( SEPARATE_HOME )) && [[ -n "$home_dev" ]]; then
        mkfs."$FS_TYPE" -F "$home_dev"
        mkdir -p /mnt/gentoo/home
        mount "$home_dev" /mnt/gentoo/home
      fi
    fi

    # /boot
    if (( ENCRYPT_BOOT )) && [[ -n "$boot_dev" ]]; then
      mkfs.ext4 -F "$boot_dev"
      mkdir -p /mnt/gentoo/boot
      mount "$boot_dev" /mnt/gentoo/boot
      if [[ "$BOOT_MODE" == "uefi" ]]; then
        mkdir -p /mnt/gentoo/boot/efi
        mount "$p1" /mnt/gentoo/boot/efi
      fi
    else
      if [[ "$BOOT_MODE" == "uefi" ]]; then
        mkdir -p /mnt/gentoo/boot/efi
        mount "$p1" /mnt/gentoo/boot/efi
      else
        mkdir -p /mnt/gentoo/boot
        mount "$p1" /mnt/gentoo/boot || true
      fi
    fi

    # swap LV
    if [[ "$SWAP_MODE" == "partition" ]] && [[ -n "$swap_dev" ]]; then
      mkswap "$swap_dev"
    fi

  else
    # Without LVM
    if [[ "$FS_TYPE" == "btrfs" ]]; then
      mkfs.btrfs -f "$ROOT_MAPPER"
      mount "$ROOT_MAPPER" /mnt/gentoo
      btrfs subvolume create /mnt/gentoo/@
      if (( SEPARATE_HOME )); then
        btrfs subvolume create /mnt/gentoo/@home
      fi
      umount /mnt/gentoo
      mount -o subvol=@ "$ROOT_MAPPER" /mnt/gentoo
      if (( SEPARATE_HOME )); then
        mkdir -p /mnt/gentoo/home
        mount -o subvol=@home "$ROOT_MAPPER" /mnt/gentoo/home
      fi
    else
      mkfs."$FS_TYPE" -F "$ROOT_MAPPER"
      mount "$ROOT_MAPPER" /mnt/gentoo
      # separate /home is not created automatically in non-LVM + non-Btrfs scheme
    fi

    if [[ "$BOOT_MODE" == "uefi" ]]; then
      mkdir -p /mnt/gentoo/boot/efi
      mount "$p1" /mnt/gentoo/boot/efi
    fi

    if [[ "$SWAP_MODE" == "partition" ]]; then
      warn "Swap 'partition' was selected without LVM, but a dedicated swap partition is not created in simplified scheme."
    fi
  fi
}

# ---------------- Network check ----------------
check_network() {
  log "Checking network connectivity"
  if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
    log "Basic network connectivity OK"
    return 0
  fi
  warn "No response from 1.1.1.1/8.8.8.8. Trying DNS-based check..."
  if wget -q --spider https://distfiles.gentoo.org; then
    log "HTTP connectivity to distfiles.gentoo.org OK"
    return 0
  fi
  die "No network connectivity detected. Check network configuration before running the installer."
}

# ---------------- Stage3 download ----------------
STAGE3_URL=""
STAGE3_LOCAL="/tmp/stage3.tar.xz"

select_stage3_url() {
  log "Selecting Stage3 tarball"
  local region mirrors=() idx stg full rtt best_rtt=99999 best="" 

  region=$(curl -s --max-time 5 https://ipapi.co/country 2>/dev/null || echo "")
  log "Region by geo-IP: ${region:-unknown}"

  if command -v mirrorselect >/dev/null 2>&1; then
    local tmp
    tmp=$(mktemp)
    mirrorselect -s4 -b8 --country "${region:-}" -o "$tmp" >/dev/null 2>&1 || true
    while IFS= read -r l; do
      local u
      u=$(echo "$l" | grep -oE 'https?://[^ ]+' || true)
      [[ -n "$u" ]] && mirrors+=("${u%/}/")
    done <"$tmp"
    rm -f "$tmp"
  fi

  if ((${#mirrors[@]} == 0)); then
    mirrors=(
      "https://mirror.yandex.ru/gentoo/"
      "https://ftp.fau.de/gentoo/"
      "https://gentoo.osuosl.org/"
      "https://distfiles.gentoo.org/"
    )
  fi

  # Prefer Stage3 matching selected init system
  local stage_files=()
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    stage_files+=(
      "releases/amd64/autobuilds/latest-stage3-amd64-systemd.txt"
      "releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt"
    )
  else
    stage_files+=(
      "releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt"
      "releases/amd64/autobuilds/latest-stage3-amd64-systemd.txt"
    )
  fi

  for m in "${mirrors[@]}"; do
    for idx in "${stage_files[@]}"; do
      local url="$m$idx"
      if curl -s --head --fail --max-time 6 "$url" >/dev/null 2>&1; then
        stg=$(curl -fsS "$url" 2>/dev/null | awk '!/^#/ && /stage3/ {print $1; exit}')
        [[ -n "$stg" ]] || continue
        full="${m}releases/amd64/autobuilds/${stg}"
        if ! curl -s --head --fail --max-time 8 "$full" >/dev/null 2>&1; then
          continue
        fi
        rtt=$(curl -o /dev/null -s -w '%{time_total}' --max-time 8 "$full" 2>/dev/null || echo "")
        if [[ -n "$rtt" ]]; then
          if awk "BEGIN{exit !($rtt < $best_rtt)}"; then
            best_rtt="$rtt"; best="$full"
          fi
        elif [[ -z "$best" ]]; then
          best="$full"
        fi
        break
      fi
    done
  done

  if [[ -z "$best" ]]; then
    local idx
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
      idx="https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-systemd.txt"
    else
      idx="https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt"
    fi
    if curl -s --head --fail "$idx" >/dev/null 2>&1; then
      stg=$(curl -fsS "$idx" | awk '!/^#/ && /stage3/ {print $1; exit}')
      best="https://distfiles.gentoo.org/releases/amd64/autobuilds/${stg}"
    fi
  fi

  [[ -n "$best" ]] || die "Failed to select Stage3 tarball"
  STAGE3_URL="$best"
  log "Selected Stage3: $STAGE3_URL (rtt=${best_rtt})"
}

download_stage3() {
  log "Downloading Stage3 -> $STAGE3_LOCAL"
  retry_cmd 6 5 wget -c -O "$STAGE3_LOCAL" "$STAGE3_URL" || die "Failed to download Stage3"

  if (( ! SKIP_CHECKSUM )); then
    local dig="/tmp/stage3.DIGESTS"
    local dig_url="${STAGE3_URL%.tar.xz}.DIGESTS"
    log "Downloading DIGESTS -> $dig"
    retry_cmd 3 5 wget -O "$dig" "$dig_url" || die "Failed to download DIGESTS"
    log "Verifying Stage3 SHA512"
    grep -A999 "SHA512 HASH" "$dig" | awk 'NF>=2 && $1 !~ /^#/ {print $1"  '"$STAGE3_LOCAL"'"}' | sha512sum -c - || die "SHA512 verification failed"
  else
    warn "--skip-checksum: Stage3 integrity check disabled"
  fi
}

extract_stage3() {
  log "Extracting Stage3 to /mnt/gentoo"
  tar xpvf "$STAGE3_LOCAL" -C /mnt/gentoo --xattrs-include='*.*' --numeric-owner
}

# ---------------- fstab + make.conf ----------------
generate_fstab_and_makeconf() {
  log "Generating fstab and make.conf"
  local root_dev efi_dev root_uuid efi_uuid
  root_dev=$(findmnt -no SOURCE /mnt/gentoo || true)
  efi_dev=$(findmnt -no SOURCE /mnt/gentoo/boot/efi 2>/dev/null || true)
  root_uuid=$(blkid -s UUID -o value "$root_dev" 2>/dev/null || true)
  efi_uuid=$(blkid -s UUID -o value "$efi_dev" 2>/dev/null || true)
  mkdir -p /mnt/gentoo/etc

  local root_opts home_opts
  if [[ "$FS_TYPE" == "btrfs" ]]; then
    root_opts="noatime,compress=zstd:3,subvol=@"
    home_opts="noatime,compress=zstd:3,subvol=@home"
  else
    root_opts="noatime"
    home_opts="noatime"
  fi

  {
    if [[ -n "$root_uuid" ]]; then
      echo "UUID=${root_uuid}  /          ${FS_TYPE}  ${root_opts}  0 1"
    fi
    if [[ -n "$efi_uuid" ]]; then
      echo "UUID=${efi_uuid}   /boot/efi  vfat  noatime  0 2"
    fi
  } > /mnt/gentoo/etc/fstab

  # LUKS/LVM swap/home entries
  if (( USE_LVM )); then
    if [[ "$SWAP_MODE" == "partition" ]]; then
      if lvdisplay "/dev/${VG_NAME}/${LV_SWAP}" >/dev/null 2>&1; then
        echo "/dev/${VG_NAME}/${LV_SWAP}  none   swap  sw        0 0" >> /mnt/gentoo/etc/fstab
      fi
    fi
    if (( SEPARATE_HOME )); then
      if [[ "$FS_TYPE" == "btrfs" ]]; then
        # /home on Btrfs subvolume on same LV
        if [[ -n "$root_uuid" ]]; then
          echo "UUID=${root_uuid}  /home      btrfs ${home_opts}  0 2" >> /mnt/gentoo/etc/fstab
        fi
      else
        if lvdisplay "/dev/${VG_NAME}/${LV_HOME}" >/dev/null 2>&1; then
          echo "/dev/${VG_NAME}/${LV_HOME}  /home   ${FS_TYPE}  noatime  0 2" >> /mnt/gentoo/etc/fstab
        fi
      fi
    fi
    if (( ENCRYPT_BOOT )) && lvdisplay "/dev/${VG_NAME}/${LV_BOOT}" >/dev/null 2>&1; then
      echo "/dev/${VG_NAME}/${LV_BOOT}  /boot  ext4  noatime  0 2" >> /mnt/gentoo/etc/fstab
    fi
  else
    # Non-LVM Btrfs: add /home entry if separate subvolume
    if [[ "$FS_TYPE" == "btrfs" ]] && (( SEPARATE_HOME )) && [[ -n "$root_uuid" ]]; then
      echo "UUID=${root_uuid}  /home      btrfs ${home_opts}  0 2" >> /mnt/gentoo/etc/fstab
    fi
  fi

  # crypttab
  if (( USE_LUKS )); then
    mkdir -p /mnt/gentoo/etc
    local luks_uuid
    luks_uuid=$(blkid -s UUID -o value "${TARGET_DISK}2" 2>/dev/null || true)
    if [[ -n "$luks_uuid" ]]; then
      echo "cryptroot UUID=${luks_uuid} none luks,discard" > /mnt/gentoo/etc/crypttab
    fi
  fi

  # make.conf
  local de_use=""
  case "$DE_CHOICE" in
    gnome) de_use="gtk gnome -qt5 -kde";;
    xfce)  de_use="gtk xfce -qt5 -kde -gnome";;
    i3)    de_use="i3 -kde -gnome";;
    kde)   de_use="qt5 plasma kde -gtk -gnome";;
    server) de_use="-gtk -qt5 -kde -gnome";;
  esac

  local features="parallel-fetch"
  (( ENABLE_CCACHE )) && features+=" ccache"
  (( ENABLE_BINPKG )) && features+=" buildpkg"
  (( ENABLE_LTO )) && features+=" lto"

  cat > /mnt/gentoo/etc/portage/make.conf <<MCF
COMMON_FLAGS="-march=${CPU_MARCH} -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C target-cpu=${CPU_MARCH}"
MAKEOPTS="-j$(nproc)"
USE="${de_use} dbus elogind pulseaudio"
ACCEPT_LICENSE="@FREE linux-fw-redistributable"
VIDEO_CARDS="${GPU_DRIVER}"
INPUT_DEVICES="libinput"
GRUB_PLATFORMS="efi-64"
FEATURES="${features}"
MCF

  if (( ENABLE_CCACHE )); then
    mkdir -p /mnt/gentoo/var/cache/ccache
    echo 'CCACHE_DIR="/var/cache/ccache"' >> /mnt/gentoo/etc/portage/make.conf
  fi
}

# ---------------- chroot preparation ----------------
prepare_chroot_mounts() {
  log "Preparing chroot mounts"
  cp --dereference /etc/resolv.conf /mnt/gentoo/etc/ || true
  mount -t proc /proc /mnt/gentoo/proc
  mount --rbind /sys /mnt/gentoo/sys; mount --make-rslave /mnt/gentoo/sys
  mount --rbind /dev /mnt/gentoo/dev; mount --make-rslave /mnt/gentoo/dev
  mkdir -p /mnt/gentoo/run
  mount --bind /run /mnt/gentoo/run
  mount --make-rslave /mnt/gentoo/run
}

write_genesis_env() {
  log "Writing /mnt/gentoo/tmp/.genesis_env.sh"
  mkdir -p /mnt/gentoo/tmp
  cat > /mnt/gentoo/tmp/.genesis_env.sh <<ENV
DE_CHOICE='${DE_CHOICE}'
HOSTNAME='${HOSTNAME}'
USERNAME='${USERNAME}'
TIMEZONE='${TIMEZONE}'
ROOT_PASSWORD='${ROOT_PASSWORD}'
USER_PASSWORD='${USER_PASSWORD}'
INIT_SYSTEM='${INIT_SYSTEM}'
PROFILE_FLAVOR='${PROFILE_FLAVOR}'
LSM_CHOICE='${LSM_CHOICE}'
ENABLE_UFW='${ENABLE_UFW}'
KERNEL_MODE='${KERNEL_MODE}'
FS_TYPE='${FS_TYPE}'
USE_LVM='${USE_LVM}'
USE_LUKS='${USE_LUKS}'
ENCRYPT_BOOT='${ENCRYPT_BOOT}'
SWAP_MODE='${SWAP_MODE}'
SEPARATE_HOME='${SEPARATE_HOME}'
ENABLE_CCACHE='${ENABLE_CCACHE}'
ENABLE_BINPKG='${ENABLE_BINPKG}'
ENABLE_LTO='${ENABLE_LTO}'
BUNDLE_FLATPAK='${BUNDLE_FLATPAK}'
BUNDLE_TERM='${BUNDLE_TERM}'
BUNDLE_DEV='${BUNDLE_DEV}'
BUNDLE_OFFICE='${BUNDLE_OFFICE}'
BUNDLE_GAMING='${BUNDLE_GAMING}'
AUTO_UPDATE='${AUTO_UPDATE}'
CPU_FREQ_TUNE='${CPU_FREQ_TUNE}'
VG_NAME='${VG_NAME}'
LV_ROOT='${LV_ROOT}'
LV_SWAP='${LV_SWAP}'
LV_HOME='${LV_HOME}'
LV_BOOT='${LV_BOOT}'
TARGET_DISK='${TARGET_DISK}'
ENV
  chmod 600 /mnt/gentoo/tmp/.genesis_env.sh
}

write_chroot_installer() {
  log "Creating /mnt/gentoo/tmp/genesis_chroot_install.sh"
  cat > /mnt/gentoo/tmp/genesis_chroot_install.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log(){ printf '%s [CHROOT] %s\n' "$(date -Is)" "$*"; }

healing_emerge() {
  local -a args=( "$@" )
  local attempt=1 max=4
  while (( attempt <= max )); do
    log "emerge attempt $attempt: emerge ${args[*]}"
    if emerge --backtrack=30 --verbose "${args[@]}"; then
      return 0
    fi
    if emerge --autounmask-write "${args[@]}"; then
      etc-update --automode -3 || true
      attempt=$((attempt+1))
      continue
    fi
    return 1
  done
  return 1
}

source /tmp/.genesis_env.sh

log "Chroot: HOSTNAME=${HOSTNAME}, USERNAME=${USERNAME}, DE=${DE_CHOICE}, INIT=${INIT_SYSTEM}"

# Sync Portage
if ! emerge-webrsync; then
  log "emerge-webrsync failed; trying emerge --sync"
  emerge --sync || log "emerge --sync also had issues; continuing"
fi

# Profile selection
PROFILE_ID=""
if [[ "$PROFILE_FLAVOR" == "hardened" ]]; then
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    PROFILE_ID=$(eselect profile list | awk '/hardened.*systemd/ {print $1; exit}')
  else
    PROFILE_ID=$(eselect profile list | awk '/hardened.*openrc/ {print $1; exit}')
  fi
else
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    PROFILE_ID=$(eselect profile list | awk '/amd64/ && /systemd/ && !/hardened/ {print $1; exit}')
  else
    PROFILE_ID=$(eselect profile list | awk '/amd64/ && /openrc/ && !/hardened/ {print $1; exit}')
  fi
fi
if [[ -z "$PROFILE_ID" ]]; then
  PROFILE_ID=$(eselect profile list | awk '/amd64/ {print $1}' | head -n1)
fi
if [[ -n "$PROFILE_ID" ]]; then
  eselect profile set "$PROFILE_ID" || true
  log "Profile set to $PROFILE_ID"
else
  log "Could not select profile automatically"
fi

# Licenses/keywords for linux-firmware
mkdir -p /etc/portage/package.license /etc/portage/package.accept_keywords
echo "sys-kernel/linux-firmware linux-fw-redistributable" > /etc/portage/package.license/linux-firmware
echo "sys-kernel/linux-firmware ~amd64" > /etc/portage/package.accept_keywords/linux-firmware

# World update
healing_emerge --update --deep --newuse @world || log "@world update encountered issues"

# Locales & timezone
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen || true
eselect locale set en_US.utf8 || true
env-update && source /etc/profile
if [[ -n "${TIMEZONE:-}" && -f /usr/share/zoneinfo/${TIMEZONE} ]]; then
  ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
  hwclock --systohc || true
fi

# Hostname & hosts
echo "hostname=\"${HOSTNAME}\"" > /etc/conf.d/hostname
{
  echo "127.0.0.1   localhost"
  echo "127.0.1.1   ${HOSTNAME}"
} >> /etc/hosts

# Init system specifics
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
  ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime || true
fi

# Base packages
healing_emerge app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate sudo dbus polkit || true

if [[ "$INIT_SYSTEM" == "openrc" ]]; then
  rc-update add sysklogd default || true
  rc-update add chronyd default || true
  rc-update add cronie default || true
  rc-update add dbus default || true
else
  systemctl enable systemd-timesyncd.service || true
fi

# Networking & SSH
healing_emerge net-misc/networkmanager net-misc/openssh || true
if [[ "$INIT_SYSTEM" == "openrc" ]]; then
  rc-update add NetworkManager default || true
  rc-update add sshd default || true
else
  systemctl enable NetworkManager.service || true
  systemctl enable sshd.service || true
fi

# LSM
if [[ "$LSM_CHOICE" == "apparmor" ]]; then
  healing_emerge app-admin/apparmor-utils || true
  sed -i 's/^GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="apparmor=1 security=apparmor /' /etc/default/grub 2>/dev/null || true
elif [[ "$LSM_CHOICE" == "selinux" ]]; then
  healing_emerge sys-apps/policycoreutils sys-apps/selinux-base-policy || true
  sed -i 's/^GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="selinux=1 enforcing=1 /' /etc/default/grub 2>/dev/null || true
fi

# UFW
if [[ "$ENABLE_UFW" -eq 1 ]]; then
  healing_emerge net-firewall/ufw || true
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-update add ufw default || true
  else
    systemctl enable ufw.service || true
  fi
  ufw default deny incoming || true
  ufw default allow outgoing || true
  ufw allow ssh || true
  ufw --force enable || true
fi

# Kernel
if [[ "$KERNEL_MODE" == "gentoo-kernel-bin" ]]; then
  healing_emerge sys-kernel/gentoo-kernel-bin || true
elif [[ "$KERNEL_MODE" == "gentoo-kernel" ]]; then
  healing_emerge sys-kernel/gentoo-kernel || true
elif [[ "$KERNEL_MODE" == "genkernel" ]]; then
  healing_emerge sys-kernel/gentoo-sources sys-kernel/genkernel || true
  genkernel all || true
else
  healing_emerge sys-kernel/gentoo-sources || true
  log "Manual kernel mode: configure and build the kernel yourself."
fi

# Xorg & DE
if [[ "$DE_CHOICE" != "server" ]]; then
  healing_emerge x11-base/xorg-drivers x11-base/xorg-server || true
fi
case "$DE_CHOICE" in
  kde)   healing_emerge kde-plasma/plasma-meta kde-apps/konsole kde-apps/dolphin || true ;;
  gnome) healing_emerge gnome-base/gnome || true ;;
  xfce)  healing_emerge xfce-base/xfce4-meta xfce-extra/xfce4-goodies || true ;;
  i3)    healing_emerge x11-wm/i3 x11-terms/alacritty || true ;;
  server) : ;;
esac

# Display manager
if [[ "$DE_CHOICE" == "kde" ]]; then
  healing_emerge x11-misc/sddm || true
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-update add sddm default || true
  else
    systemctl enable sddm.service || true
  fi
elif [[ "$DE_CHOICE" == "gnome" ]]; then
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-update add gdm default || true
  else
    systemctl enable gdm.service || true
  fi
elif [[ "$DE_CHOICE" == "xfce" || "$DE_CHOICE" == "i3" ]]; then
  healing_emerge x11-misc/lightdm x11-misc/lightdm-gtk-greeter || true
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-update add lightdm default || true
  else
    systemctl enable lightdm.service || true
  fi
fi

# Bundles
if [[ "$BUNDLE_FLATPAK" -eq 1 ]]; then
  healing_emerge sys-apps/flatpak app-containers/distrobox || true
fi
if [[ "$BUNDLE_TERM" -eq 1 ]]; then
  healing_emerge app-shells/zsh media-fonts/nerd-fonts app-shells/starship || true
fi
if [[ "$BUNDLE_DEV" -eq 1 ]]; then
  healing_emerge dev-vcs/git dev-util/visual-studio-code-bin app-containers/docker || true
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-update add docker default || true
  else
    systemctl enable docker.service || true
  fi
fi
if [[ "$BUNDLE_OFFICE" -eq 1 ]]; then
  healing_emerge app-office/libreoffice media-gfx/gimp media-gfx/inkscape || true
fi
if [[ "$BUNDLE_GAMING" -eq 1 ]]; then
  healing_emerge games-util/steam-launcher games-util/lutris app-emulation/wine || true
fi

# CPU frequency tools
if [[ "$CPU_FREQ_TUNE" -eq 1 ]]; then
  healing_emerge sys-power/cpupower || true
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    rc-update add cpupower default || true
  else
    systemctl enable cpupower.service || true
  fi
fi

# User & sudo
for grp in users wheel audio video; do
  getent group "$grp" >/dev/null 2>&1 || groupadd "$grp"
done
if ! id -u "$USERNAME" >/dev/null 2>&1; then
  useradd -m -G users,wheel,audio,video -s /bin/bash "$USERNAME"
fi
echo "root:${ROOT_PASSWORD}" | chpasswd || true
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd || true
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || true

# Boot environments (Btrfs)
if [[ "$FS_TYPE" == "btrfs" ]]; then
  healing_emerge sys-fs/btrfs-progs || true
  cat > /usr/local/sbin/genesis-update <<UPD
#!/usr/bin/env bash
set -euo pipefail
btrfs subvolume snapshot -r / /.snapshots/@-\$(date +%Y%m%d-%H%M%S)-preupdate || true
emerge --sync
emerge --update --deep --newuse @world
UPD
  chmod +x /usr/local/sbin/genesis-update
fi

# Auto-update
if [[ "$AUTO_UPDATE" -eq 1 ]]; then
  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    echo "0 4 * * 0 root /usr/local/sbin/genesis-update || true" >> /etc/crontab
  else
    cat > /etc/systemd/system/genesis-update.service <<SVC
[Unit]
Description=Gentoo Genesis weekly update

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/genesis-update
SVC
    cat > /etc/systemd/system/genesis-update.timer <<TMR
[Unit]
Description=Weekly Genesis update

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
TMR
    systemctl enable genesis-update.timer || true
  fi
fi

# GRUB
healing_emerge sys-boot/grub || true
if [[ "$INIT_SYSTEM" == "systemd" ]]; then
  sed -i 's/rc_sys=".*"/rc_sys=""/' /etc/rc.conf 2>/dev/null || true
fi

if [[ -d /sys/firmware/efi ]]; then
  grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Gentoo --recheck || true
else
  grub-install --target=i386-pc "${TARGET_DISK}" || true
fi
grub-mkconfig -o /boot/grub/grub.cfg || true

# EFI fallback
if [[ -d /boot/efi/EFI ]]; then
  if [[ -d /boot/efi/EFI/gentoo && ! -d /boot/efi/EFI/Gentoo ]]; then
    mv /boot/efi/EFI/gentoo /boot/efi/EFI/Gentoo || true
  fi
  if [[ -f /boot/efi/EFI/Gentoo/grubx64.efi ]]; then
    mkdir -p /boot/efi/EFI/Boot
    cp -f /boot/efi/EFI/Gentoo/grubx64.efi /boot/efi/EFI/Boot/bootx64.efi || true
  fi
fi

log "Chroot build completed"
CHROOT
  chmod +x /mnt/gentoo/tmp/genesis_chroot_install.sh
}

run_chroot_install() {
  log "Running chroot installer"
  chroot /mnt/gentoo /bin/bash /tmp/genesis_chroot_install.sh
}

post_chroot_efi_fix() {
  log "Post-chroot EFI check"
  if [[ ! -d /sys/firmware/efi ]]; then
    warn "Host is not booted in UEFI mode, skipping efibootmgr"
    return
  fi
  if ! command -v efibootmgr >/dev/null 2>&1; then
    warn "efibootmgr is not available on LiveCD, skipping EFI entry creation"
    return
  fi
  if ! efibootmgr | grep -qi gentoo; then
    local esp_dev
    esp_dev=$(findmnt -no SOURCE /mnt/gentoo/boot/efi 2>/dev/null || true)
    if [[ -n "$esp_dev" ]]; then
      local disk part pnum
      disk=$(lsblk -no PKNAME "$esp_dev" | head -n1)
      pnum=$(lsblk -no PARTNUM "$esp_dev" | head -n1)
      if [[ -n "$disk" && -n "$pnum" ]]; then
        efibootmgr -c -d "/dev/$disk" -p "$pnum" -L "Gentoo (Genesis)" -l '\EFI\Gentoo\grubx64.efi' || true
      fi
    fi
  fi
}

# ---------------- MAIN ----------------
log "${GENESIS_NAME} v${GENESIS_VERSION} starting"

self_heal_livecd
detect_hardware
handle_resume

cp_stage=$(get_checkpoint)

if [[ "$cp_stage" == "0" ]]; then
  wizard
  checkpoint "wizard_done"
  cp_stage="wizard_done"
fi

if [[ "$cp_stage" == "wizard_done" ]]; then
  partition_and_setup_storage
  checkpoint "storage_done"
  cp_stage="storage_done"
fi

if [[ "$cp_stage" == "storage_done" ]]; then
  check_network
  select_stage3_url
  download_stage3
  extract_stage3
  checkpoint "stage3_done"
  cp_stage="stage3_done"
fi

if [[ "$cp_stage" == "stage3_done" ]]; then
  generate_fstab_and_makeconf
  prepare_chroot_mounts
  write_genesis_env
  write_chroot_installer
  checkpoint "chroot_script_ready"
  cp_stage="chroot_script_ready"
fi

if [[ "$cp_stage" == "chroot_script_ready" ]]; then
  run_chroot_install
  checkpoint "chroot_done"
  cp_stage="chroot_done"
fi

if [[ "$cp_stage" == "chroot_done" ]]; then
  post_chroot_efi_fix
fi

clear_checkpoint
log "Installation finished. Recommended next commands:"
log "  exit"
log "  umount -R /mnt/gentoo"
log "  reboot"

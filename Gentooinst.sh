#!/bin/bash
set -euo pipefail

# gentoo_autobuilder_auto_detect.sh
# Automatic UUID detection + full Gentoo AutoBuilder Pro (built-in kernel)
# - Auto-detect root and EFI partitions and UUIDs (no manual UUID input)
# - Auto-create /boot and /boot/efi mountpoints if missing
# - Update /etc/fstab, attempt mounting, wait for udev
# - Kernel selection, force built-in config (CONFIG_*=y), build, genkernel initramfs
# - GRUB/UEFI update, install XFCE/Xorg & LightDM (OpenRC), XFS/HDD/Power tuning
# - Backups, rollback (best-effort), dry-run (--dry-run) and non-interactive (--auto) modes
# NOTE: Script will NOT install sys-devel/make automatically. Ensure build tools present.

LOG="/var/log/gentoo_autobuilder_auto_detect.log"
: > "$LOG"

# Configuration
BACKUP_DIR="/var/backups/gentoo_autobuilder"
KEEP_BACKUPS=3
KERNEL_CONFIG_STORE="/etc/kernel-configs"
DRY_RUN=false
AUTO_MODE=false
EMERGE_JOBS=""
EMERGE_LOAD=""
EMERGE_BASE_OPTS=(--verbose --quiet-build=y --with-bdeps=y)

# Logging helpers
log(){ printf '[INFO] %s\n' "$*" | tee -a "$LOG"; }
warn(){ printf '[WARN] %s\n' "$*" | tee -a "$LOG" >&2; }
err(){ printf '[ERROR] %s\n' "$*" | tee -a "$LOG" >&2; }
die(){ err "$*"; exit 1; }

usage(){
  cat <<EOF
Usage: $0 [--dry-run] [--auto] [-j N] [-h]
  --dry-run    Show actions without making changes
  --auto       Non-interactive (accept defaults)
  -j N         Set parallel emerge jobs
  -h           Help
EOF
}

# Parse args
while [[ "${1:-}" != "" ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --auto) AUTO_MODE=true; shift ;;
    -j) shift; EMERGE_JOBS="${1:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

get_cpu_cores(){ command -v nproc &>/dev/null && nproc --all || echo 4; }
if [[ -z "$EMERGE_JOBS" ]]; then EMERGE_JOBS="$(get_cpu_cores)"; fi
EMERGE_LOAD="$EMERGE_JOBS"

run_or_dry(){
  if $DRY_RUN; then
    log "DRY-RUN: $*"
  else
    log "RUN: $*"
    eval "$@"
  fi
}

confirm(){
  local prompt="$1"; local default="${2:-n}"
  if $AUTO_MODE; then [[ "$default" == "y" ]] && echo "y" || echo "n"; return; fi
  read -r -p "$prompt" ans
  ans="${ans:-$default}"
  ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
  echo "${ans:0:1}"
}

# Safety: backup and rollback
CURRENT_BACKUP=""
trap 'on_error $?' ERR
on_error(){
  local rc=${1:-1}
  err "Script failed (exit $rc). Attempting rollback if backup exists."
  if [[ -n "$CURRENT_BACKUP" && -f "$CURRENT_BACKUP" ]]; then
    warn "Restoring backup $CURRENT_BACKUP ..."
    if $DRY_RUN; then
      log "DRY-RUN: restore $CURRENT_BACKUP"
    else
      tar -xzf "$CURRENT_BACKUP" -C / || warn "Rollback extraction returned non-zero"
      log "Rollback attempted."
    fi
  else
    warn "No backup available."
  fi
  err "See $LOG for details."
  exit $rc
}

make_backup(){
  mkdir -p "$BACKUP_DIR"
  ts="$(date +%Y%m%d_%H%M%S)"
  backupfile="$BACKUP_DIR/gentoo_autobuilder_backup_${ts}.tar.gz"
  CURRENT_BACKUP="$backupfile"
  files=(/etc/portage/make.conf /etc/fstab /etc/default/grub /etc/conf.d/xdm /etc/local.d /etc/kernel-configs /boot /etc/portage)
  log "Creating backup $backupfile ..."
  if $DRY_RUN; then
    log "DRY-RUN: tar czf $backupfile ${files[*]}"
  else
    tar -czf "$backupfile" --absolute-names "${files[@]}" || warn "tar returned non-zero (some files may be missing)"
    log "Backup created: $backupfile"
    ls -1t "$BACKUP_DIR"/gentoo_autobuilder_backup_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS+1)) | xargs -r rm -f || true
  fi
}

# Portage helpers
is_installed_pkg(){
  local atom="$1"
  if command -v equery &>/dev/null; then equery list "$atom" >/dev/null 2>&1 && return 0; fi
  [[ -d /var/db/pkg ]] && find /var/db/pkg -maxdepth 2 -type d -name "${atom##*/}*" | grep -q . && return 0
  return 1
}

emerge_with_autounmask(){
  local pkg="$1"
  log "Emerge attempt: $pkg"
  if $DRY_RUN; then
    log "DRY-RUN: emerge -j${EMERGE_JOBS} --load-average=${EMERGE_LOAD} ${EMERGE_BASE_OPTS[*]} $pkg"
    return 0
  fi
  if emerge -j"${EMERGE_JOBS}" --load-average="${EMERGE_LOAD}" "${EMERGE_BASE_OPTS[@]}" "$pkg"; then return 0; fi
  warn "Initial emerge failed; trying autounmask-write..."
  if emerge -j"${EMERGE_JOBS}" --load-average="${EMERGE_LOAD}" --autounmask-write=y "$pkg"; then
    command -v etc-update &>/dev/null && etc-update --automode -5 || true
    command -v dispatch-conf &>/dev/null && dispatch-conf --auto-merge || true
    emerge -j"${EMERGE_JOBS}" --load-average="${EMERGE_LOAD}" "${EMERGE_BASE_OPTS[@]}" "$pkg" || return 1
    return 0
  fi
  warn "Could not autounmask/install $pkg automatically."
  return 1
}

# Prechecks
if [[ "$(id -u)" -ne 0 ]]; then die "Run as root"; fi
if ! command -v make &>/dev/null; then die "make not found. Please install build tools (script will not auto-install sys-devel/make)."; fi

check_network(){
  log "Checking network..."
  if ping -c1 -W2 gentoo.org &>/dev/null || ping -c1 -W2 8.8.8.8 &>/dev/null; then log "Network OK"; else warn "Network unreachable"; if [[ "$(confirm 'Continue without network? [y/N] ' 'n')" != "y" ]]; then die "Network required"; fi; fi
}

# Auto-detect partitions and UUIDs
detect_partitions(){
  log "Detecting root and EFI partitions (blkid + findmnt + lsblk heuristics)..."

  # try to get root device from findmnt
  ROOT_DEV="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  if [[ -n "$ROOT_DEV" && -b "$ROOT_DEV" ]]; then
    ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)"
    ROOT_FSTYPE="$(blkid -s TYPE -o value "$ROOT_DEV" 2>/dev/null || true)"
    log "Root device detected: $ROOT_DEV (UUID=${ROOT_UUID}, TYPE=${ROOT_FSTYPE})"
  fi

  # EFI: check mountpoints first
  EFI_DEV="$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)"
  if [[ -n "$EFI_DEV" && -b "$EFI_DEV" ]]; then
    EFI_UUID="$(blkid -s UUID -o value "$EFI_DEV" 2>/dev/null || true)"
    EFI_FSTYPE="$(blkid -s TYPE -o value "$EFI_DEV" 2>/dev/null || true)"
    log "EFI device detected: $EFI_DEV (UUID=${EFI_UUID}, TYPE=${EFI_FSTYPE})"
  fi

  # If not found, search blkid output: prefer vfat with EFIsize (<=1G) or PARTLABEL containing EFI
  if [[ -z "${EFI_UUID:-}" ]]; then
    while IFS= read -r line; do
      dev=$(cut -d: -f1 <<< "$line")
      ftype=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
      label=$(blkid -s PARTLABEL -o value "$dev" 2>/dev/null || true)
      size_kb=$(blockdev --getsize64 "$dev" 2>/dev/null || true)
      # treat small vfat or partlabel containing EFI as EFI partition
      if [[ "$ftype" == "vfat" ]] || [[ "$label" =~ [Ee][Ff][Ii] ]]; then
        EFI_UUID="$(blkid -s UUID -o value "$dev" 2>/dev/null || true)"
        EFI_DEV="$dev"
        EFI_FSTYPE="$ftype"
        log "Selected EFI candidate: $EFI_DEV (UUID=${EFI_UUID}, TYPE=${EFI_FSTYPE}, PARTLABEL=${label})"
        break
      fi
    done < <(blkid -o udev 2>/dev/null | grep -oP '/dev/\S+' | sort -u)
  fi

  # If root device not detected (unusual), try to find largest xfs/ext4 partition or mounted partition candidate
  if [[ -z "${ROOT_UUID:-}" || -z "${ROOT_DEV:-}" ]]; then
    log "Root device not found via findmnt; scanning for likely root (xfs/ext4)..."
    candidate=""
    while IFS= read -r line; do
      dev=$(cut -d: -f1 <<< "$line")
      ftype=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
      if [[ "$ftype" == "xfs" || "$ftype" == "ext4" || "$ftype" == "btrfs" ]]; then
        # choose largest by size
        size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        if [[ -z "$candidate" ]]; then
          candidate="$dev"
          candidate_size="$size"
        else
          if (( size > candidate_size )); then candidate="$dev"; candidate_size="$size"; fi
        fi
      fi
    done < <(blkid -o device 2>/dev/null)
    if [[ -n "$candidate" ]]; then
      ROOT_DEV="$candidate"
      ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)"
      ROOT_FSTYPE="$(blkid -s TYPE -o value "$ROOT_DEV" 2>/dev/null || true)"
      log "Selected root candidate: $ROOT_DEV (UUID=${ROOT_UUID}, TYPE=${ROOT_FSTYPE})"
    fi
  fi

  # Final checks
  if [[ -z "${ROOT_UUID:-}" || -z "${ROOT_DEV:-}" ]]; then
    warn "Could not reliably detect root device/UUID. The script will try to continue but may fail."
  fi
  if [[ -z "${EFI_UUID:-}" || -z "${EFI_DEV:-}" ]]; then
    warn "Could not reliably detect EFI device/UUID. The script will try to continue but UEFI steps may fail."
  fi
}

# Create mountpoints, update /etc/fstab and mount
create_update_mount(){
  log "Ensuring /boot and /boot/efi exist, updating /etc/fstab and mounting by UUID"

  run_or_dry mkdir -p /boot /boot/efi

  # Ensure root entry exists: check by matching UUID or mountpoint '/'
  root_in_fstab=false
  if grep -E '^[[:space:]]*UUID=' /etc/fstab >/dev/null 2>&1; then
    if [[ -n "${ROOT_UUID:-}" ]] && grep -q "UUID=${ROOT_UUID}" /etc/fstab 2>/dev/null; then root_in_fstab=true; fi
  fi
  if ! $root_in_fstab; then
    if $DRY_RUN; then
      log "DRY-RUN: append root UUID ${ROOT_UUID} to /etc/fstab"
    else
      if [[ -n "${ROOT_UUID:-}" ]]; then
        echo "UUID=${ROOT_UUID} / ${ROOT_FSTYPE:-xfs} defaults,noatime,logbufs=8,logbsize=256k 0 1" >> /etc/fstab
        log "Added root entry to /etc/fstab"
      else
        warn "Root UUID unknown; skipping fstab root entry"
      fi
    fi
  else
    log "Root entry already present in /etc/fstab"
  fi

  # Ensure /boot/efi entry exists
  if [[ -n "${EFI_UUID:-}" ]]; then
    if grep -q "UUID=${EFI_UUID}" /etc/fstab 2>/dev/null; then
      log "EFI entry already present in /etc/fstab"
    else
      if $DRY_RUN; then
        log "DRY-RUN: append EFI UUID ${EFI_UUID} to /etc/fstab"
      else
        echo "UUID=${EFI_UUID} /boot/efi vfat umask=0077,noatime 0 2" >> /etc/fstab
        log "Added /boot/efi entry to /etc/fstab"
      fi
    fi
  else
    warn "EFI UUID unknown; /etc/fstab will not be modified for EFI"
  fi

  # ensure udev devices are present
  command -v udevadm &>/dev/null && run_or_dry udevadm settle --timeout=10 || true

  # try mount -a
  if $DRY_RUN; then
    log "DRY-RUN: mount -a"
  else
    run_or_dry mount -a || true
  fi

  # If mounting still missing, mount by /dev/disk/by-uuid
  if ! mountpoint -q /boot/efi 2>/dev/null && [[ -n "${EFI_UUID:-}" ]]; then
    if $DRY_RUN; then
      log "DRY-RUN: mount -t vfat /dev/disk/by-uuid/${EFI_UUID} /boot/efi"
    else
      if [[ -e "/dev/disk/by-uuid/${EFI_UUID}" ]]; then
        mount -t vfat "/dev/disk/by-uuid/${EFI_UUID}" /boot/efi || warn "Mount by UUID for EFI failed"
      else
        warn "Device /dev/disk/by-uuid/${EFI_UUID} not found"
      fi
    fi
  fi

  # If /boot not mounted separately (some systems use root for /boot), warn
  if ! mountpoint -q /boot 2>/dev/null; then
    warn "/boot not a separate mountpoint (may be part of root). Some operations may require /boot mounted explicitly."
  fi
}

validate_fstab(){
  if command -v findmnt &>/dev/null; then
    if ! findmnt --verify >/dev/null 2>&1; then
      warn "/etc/fstab verification failed"
      if [[ "$(confirm 'Attempt to continue? [y/N] ' 'n')" != "y" ]]; then die "Fix /etc/fstab first"; fi
    fi
  fi
}

# Kernel selection
select_kernel(){
  log "Scanning /usr/src for linux-* directories..."
  mapfile -t KLIST < <(find /usr/src -maxdepth 1 -type d -name 'linux-*' -printf '%f\n' 2>/dev/null | sort -V)
  if [[ ${#KLIST[@]} -eq 0 ]]; then die "No kernel sources found in /usr/src"; fi
  echo "Available kernels:"
  for i in "${!KLIST[@]}"; do printf " [%d] %s\n" $((i+1)) "${KLIST[$i]}"; done
  if $AUTO_MODE; then choice=1; log "AUTO_MODE: selecting ${KLIST[0]}"; else read -r -p "Enter kernel number to use: " choice; fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#KLIST[@]} )); then die "Invalid selection"; fi
  TARGET_KERNEL="${KLIST[$((choice-1))]}"
  KERNEL_SRC="/usr/src/${TARGET_KERNEL}"
  log "Selected kernel: ${TARGET_KERNEL}"
}

save_kernel_config(){
  mkdir -p "$KERNEL_CONFIG_STORE"
  if [[ -f "$KERNEL_SRC/.config" ]]; then
    cp -a "$KERNEL_SRC/.config" "$KERNEL_CONFIG_STORE/config-${TARGET_KERNEL}-$(date +%Y%m%d_%H%M%S)"
    log "Saved kernel .config to $KERNEL_CONFIG_STORE"
  fi
}

# Force built-in kernel options
make_all_built_in(){
  log "Forcing key kernel options to built-in (=y)"
  cfg="$KERNEL_SRC/.config"
  if [[ ! -f "$cfg" ]]; then
    warn ".config not found; trying /proc/config.gz or defconfig"
    if [[ -f /proc/config.gz ]]; then zcat /proc/config.gz > "$cfg" || true; else run_or_dry bash -c "cd $KERNEL_SRC && make defconfig"; fi
  fi
  [[ -f "$cfg" ]] && cp -a "$cfg" "${cfg}.autobuilder.bak.$(date +%Y%m%d_%H%M%S)"

  read -r -d '' BUILTIN_SYMBOLS <<'SYMS' || true
DEVTMPFS
DEVTMPFS_MOUNT
TMPFS
TMPFS_POSIX_ACL
EFI_STUB
EFI_MIXED
EFI_PARTITION
FRAMEBUFFER_CONSOLE
FB_EFI
DRM
DRM_AMDGPU
DRM_RADEON
RADEON_DPM
XFS_FS
XFS_POSIX_ACL
XFS_QUOTA
XFS_ONLINE_SCRUB
EXT4_FS
BLK_DEV_INITRD
SCSI
USB
USB_STORAGE
AHCI
PCI
HWMON
POWER_SUPPLY
CPU_FREQ
CPU_IDLE
CPU_FREQ_GOV_ONDEMAND
SYMS

  if [[ -x "$KERNEL_SRC/scripts/config" ]]; then
    log "Using scripts/config to enable symbols"
    while read -r sym; do [[ -z "$sym" ]] && continue; run_or_dry bash -c "cd $KERNEL_SRC && ./scripts/config --enable $sym || true"; done <<< "$BUILTIN_SYMBOLS"
  else
    warn "scripts/config not available; will patch .config directly"
  fi

  if [[ -f "$cfg" ]]; then
    if $DRY_RUN; then log "DRY-RUN: would convert CONFIG_* = m -> = y in $cfg"; else sed -ri 's/^(CONFIG_[A-Za-z0-9_]+=)m$/\1y/' "$cfg" || true; while read -r sym; do [[ -z "$sym" ]] && continue; if ! grep -q "^CONFIG_${sym}=" "$cfg"; then echo "CONFIG_${sym}=y" >> "$cfg"; else sed -i "s/^CONFIG_${sym}=.*/CONFIG_${sym}=y/" "$cfg"; fi; done <<< "$BUILTIN_SYMBOLS"; fi
  fi

  run_or_dry bash -c "cd $KERNEL_SRC && make olddefconfig"
  log "Built-in conversion applied"
}

# Build kernel (no modules_install)
build_kernel(){
  log "Building kernel ${TARGET_KERNEL} with built-in drivers"
  if [[ ! -d "$KERNEL_SRC" ]]; then die "Kernel source $KERNEL_SRC missing"; fi
  save_kernel_config
  make_all_built_in
  if $DRY_RUN; then log "DRY-RUN: make -j${EMERGE_JOBS} in $KERNEL_SRC"; else (cd "$KERNEL_SRC" && make -j"${EMERGE_JOBS}") 2>&1 | tee -a "$LOG"; fi

  if $DRY_RUN; then log "DRY-RUN: copy bzImage to /boot"; else cp -a "$KERNEL_SRC/arch/x86/boot/bzImage" "/boot/vmlinuz-${TARGET_KERNEL}"; cp -a "$KERNEL_SRC/System.map" "/boot/System.map-${TARGET_KERNEL}" 2>/dev/null || true; cp -a "$KERNEL_SRC/.config" "/boot/config-${TARGET_KERNEL}" 2>/dev/null || true; log "Kernel installed to /boot for ${TARGET_KERNEL}"; fi

  if ! command -v genkernel &>/dev/null; then warn "genkernel not installed; attempting to install"; emerge_with_autounmask "sys-kernel/genkernel" || warn "Failed to install genkernel"; fi
  if command -v genkernel &>/dev/null; then run_or_dry genkernel --install --no-mrproper initramfs; else warn "genkernel not available; initramfs not built"; fi
}

# GRUB/UEFI
determine_grub_cfg(){ if [[ -d /boot/efi/EFI/gentoo ]]; then echo "/boot/efi/EFI/gentoo/grub.cfg"; else echo "/boot/grub/grub.cfg"; fi; }
update_grub(){ cfg="$(determine_grub_cfg)"; run_or_dry grub-mkconfig -o "$cfg"; if command -v efibootmgr &>/dev/null && ! $DRY_RUN; then efipart=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true); if [[ -n "$efipart" ]]; then efibootmgr -c -l '\EFI\gentoo\grubx64.efi' -L "Gentoo ${TARGET_KERNEL}" 2>/dev/null || warn "efibootmgr entry creation failed"; fi; fi; }
set_grub_default(){ cfg="$(determine_grub_cfg)"; if $DRY_RUN; then log "DRY-RUN: set grub default for vmlinuz-${TARGET_KERNEL}"; return 0; fi; if [[ ! -f "$cfg" ]]; then warn "grub.cfg not found"; return 1; fi; if ! grep -q "vmlinuz-${TARGET_KERNEL}" "$cfg"; then warn "grub.cfg does not reference vmlinuz-${TARGET_KERNEL}"; return 1; fi; title=$(awk -v pat="vmlinuz-${TARGET_KERNEL}" '/^menuentry /{t=$0} $0 ~ pat {gsub(/^menuentry '\''/,"",t); gsub(/'\''.*/,"",t); print t; exit}' "$cfg" || true); if [[ -n "$title" ]]; then run_or_dry grub-set-default "$title" || warn "grub-set-default failed"; else warn "Could not determine menu title"; fi; }

# make.conf optimize
optimize_makeconf(){
  conf="/etc/portage/make.conf"; bak="/etc/portage/make.conf.autobuilder.bak"
  [[ -f "$conf" ]] || touch "$conf"; [[ -f "$bak" ]] || cp -a "$conf" "$bak"
  cores=$(get_cpu_cores); makeopts="-j$((cores+1)) -l${cores}"; march="-march=bdver4"
  if $DRY_RUN; then log "DRY-RUN: would write optimized /etc/portage/make.conf"; else cat > "$conf" <<EOF
# Auto-generated make.conf
COMMON_FLAGS="${march} -O2 -pipe -fomit-frame-pointer"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="${makeopts}"
VIDEO_CARDS="amdgpu radeonsi radeon"
INPUT_DEVICES="libinput"
USE="X xorg gtk3 dbus pulseaudio vulkan opengl udev drm alsa policykit xfce xfs unicode truetype"
GENTOO_MIRRORS="https://mirror.bytemark.co.uk/gentoo/ https://mirror.eu.oneandone.net/gentoo/"
ACCEPT_LICENSE="*"
FEATURES="parallel-fetch compress-build-logs clean-logs sandbox usersandbox"
EMERGE_DEFAULT_OPTS="--ask=n --verbose --with-bdeps=y --autounmask=y --autounmask-continue=y"
PORTDIR="/var/db/repos/gentoo"
DISTDIR="/var/cache/distfiles"
PKGDIR="/var/cache/binpkgs"
FILE_SYSTEMS="xfs ext4 tmpfs"
EOF
    log "/etc/portage/make.conf written (backup: $bak)"
  fi
}

# HDD/XFS tuning
optimize_hdd_xfs(){
  log "Applying HDD/XFS tuning"
  if $DRY_RUN; then log "DRY-RUN: write sysctl and udev rules"; else cat > /etc/sysctl.d/99-gentoo-hdd.conf <<EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.dirty_expire_centisecs=3000
vm.dirty_writeback_centisecs=1000
EOF
    sysctl --system || true
  fi

  for dev in /sys/block/*; do
    [[ -e "$dev/queue/rotational" ]] || continue
    rot=$(cat "$dev/queue/rotational")
    bname=$(basename "$dev")
    if [[ "$rot" == "1" ]]; then
      run_or_dry bash -c "echo bfq > /sys/block/$bname/queue/scheduler" || true
      if $DRY_RUN; then log "DRY-RUN: create udev rule for $bname"; else echo 'ACTION=="add|change", KERNEL=="'"$bname"'", ATTR{queue/scheduler}="bfq"' > /etc/udev/rules.d/60-io-"$bname".rules; fi
    else
      run_or_dry bash -c "echo mq-deadline > /sys/block/$bname/queue/scheduler" || true
    fi
  done

  if grep -q 'xfs' /etc/fstab 2>/dev/null; then run_or_dry sed -ri 's|(\b[xX][fF][sS]\b[^ ]* )defaults|\1defaults,noatime,logbufs=8,logbsize=256k|' /etc/fstab || true; fi
  if ! grep -q '/var/tmp/portage' /etc/fstab 2>/dev/null; then run_or_dry bash -c 'echo "tmpfs /var/tmp/portage tmpfs size=4G,noatime,nodev,nosuid,mode=1777 0 0" >> /etc/fstab'; fi
  if ! grep -q '/tmp' /etc/fstab 2>/dev/null; then run_or_dry bash -c 'echo "tmpfs /tmp tmpfs size=2G,noatime,nodev,nosuid,mode=1777 0 0" >> /etc/fstab'; fi
}

# Power scripts
install_power_scripts(){
  log "Installing power management script"
  if $DRY_RUN; then log "DRY-RUN: write /etc/local.d/power.start and rc-update add local"; else mkdir -p /etc/local.d; cat > /etc/local.d/power.start <<'EOF'
#!/bin/sh
# Local power tuning (OpenRC local service)
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  if [ -f "$cpu/cpufreq/scaling_governor" ]; then echo ondemand > "$cpu/cpufreq/scaling_governor" || true; fi
done
if [ -d /sys/class/drm/card0/device ]; then
  if [ -w /sys/class/drm/card0/device/power_method ]; then echo auto > /sys/class/drm/card0/device/power_method || true; fi
  if [ -w /sys/class/drm/card0/device/power_dpm_force_performance_level ]; then echo auto > /sys/class/drm/card0/device/power_dpm_force_performance_level || true; fi
fi
for host in /sys/class/scsi_host/host*; do
  if [ -w "$host/link_power_management_policy" ]; then echo powersave > "$host/link_power_management_policy" || true; fi
done
for dev in /sys/bus/pci/devices/*/power/control; do
  if [ -w "$dev" ]; then echo auto > "$dev" || true; fi
done
if [ -w /proc/sys/vm/dirty_writeback_centisecs ]; then echo 1500 > /proc/sys/vm/dirty_writeback_centisecs || true; fi
EOF
    chmod +x /etc/local.d/power.start
    run_or_dry rc-update add local default || true
  fi
}

# XFCE/Xorg install
install_xfce(){
  log "Installing XFCE and Xorg"
  packages=(x11-base/xorg-server x11-base/xorg-drivers x11-misc/lightdm x11-misc/lightdm-gtk-greeter xfce-base/xfce4-meta xfce-extra/xfce4-goodies media-libs/mesa x11-drivers/xf86-video-amdgpu app-admin/eselect-opengl app-misc/pciutils app-misc/usbutils)
  for p in "${packages[@]}"; do
    if is_installed_pkg "$p"; then log "$p already installed"; else emerge_with_autounmask "$p" || warn "Failed to install $p"; fi
  done
  run_or_dry rc-update add lightdm default || warn "rc-update add lightdm failed"
  run_or_dry mkdir -p /etc/lightdm/lightdm.conf.d
  cat > /etc/lightdm/lightdm.conf.d/01-custom.conf <<'EOF'
[LightDM]
minimum-display-server-timeout=10
minimum-vt-timeout=10

[Seat:*]
user-session=xfce
allow-user-switching=true
allow-guest=false
# No autologin
EOF
  log "XFCE and LightDM configured"
}

install_ccache_distcc(){
  log "Installing ccache and distcc (optional)"
  emerge_with_autounmask "dev-util/ccache" || warn "ccache failed"
  emerge_with_autounmask "sys-devel/distcc" || warn "distcc failed"
  if ! grep -q "ccache" /etc/portage/make.conf 2>/dev/null; then run_or_dry bash -c 'echo "FEATURES=\"${FEATURES} ccache\"" >> /etc/portage/make.conf'; fi
}

auto_cleanup(){
  log "Running auto cleanup"
  run_or_dry eclean-kernel -n 2 || true
  run_or_dry eclean-dist --deep || true
  run_or_dry eclean-pkg --deep || true
  run_or_dry rm -rf /var/tmp/portage/* /tmp/* || true
  df -h | tee -a "$LOG"
  log "Cleanup done"
}

install_cron(){
  cronfile="/etc/cron.d/gentoo_autobuilder"
  if $DRY_RUN; then log "DRY-RUN: write $cronfile and enable parallel boot"; else cat > "$cronfile" <<EOF
# Weekly maintenance
0 4 * * 1 root /usr/local/sbin/gentoo_autobuilder_auto_detect.sh --auto >> /var/log/gentoo_autobuilder_cron.log 2>&1
EOF
    chmod 644 "$cronfile"
    if grep -q '^rc_parallel=' /etc/rc.conf 2>/dev/null; then sed -i 's/^rc_parallel=.*/rc_parallel="YES"/' /etc/rc.conf || true; else echo 'rc_parallel="YES"' >> /etc/rc.conf; fi
    log "Cron installed and parallel boot enabled"; fi
}

# Main flow
main(){
  log "Gentoo AutoBuilder Pro (auto-detect) start: $(date --iso-8601=seconds)"
  check_network
  detect_partitions
  create_update_mount
  validate_fstab
  make_backup

  optimize_makeconf
  optimize_hdd_xfs
  install_power_scripts

  select_kernel
  build_kernel

  update_grub
  set_grub_default

  install_xfce

  if [[ "$(confirm 'Install ccache/distcc? [y/N] ' 'n')" == "y" ]]; then install_ccache_distcc; fi

  auto_cleanup
  install_cron

  log "Finished successfully: $(date --iso-8601=seconds)"
}

main "$@"

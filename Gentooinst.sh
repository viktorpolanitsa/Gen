#!/bin/bash
set -euo pipefail

# gentoo_autobuilder_force.sh
# Automatic Gentoo builder (force mode)
# - auto-detect partitions (root, EFI)
# - auto-create and mount /boot and /boot/efi
# - fix /usr/src/linux symlink to newest linux-*
# - force built-in kernel options, build kernel, genkernel initramfs
# - update GRUB/UEFI and set default
# - install XFCE/Xorg/LightDM (OpenRC) and enable autostart (no autologin)
# - XFS/HDD tuning and power scripts
# - backups and best-effort rollback
# - modes: --dry-run, --auto, --force
# NOTE: script WILL NOT auto-install sys-devel/make (must be present).

LOG="/var/log/gentoo_autobuilder_force.log"
: > "$LOG"

# Defaults
DRY_RUN=false
AUTO_MODE=false
FORCE_MODE=false
EMERGE_JOBS=""
EMERGE_LOAD=""
EMERGE_BASE_OPTS=(--verbose --quiet-build=y --with-bdeps=y --ask=n)

BACKUP_DIR="/var/backups/gentoo_autobuilder"
KEEP_BACKUPS=5
KERNEL_CONFIG_STORE="/etc/kernel-configs"

# Logging
log(){ printf '[INFO] %s\n' "$*" | tee -a "$LOG"; }
warn(){ printf '[WARN] %s\n' "$*" | tee -a "$LOG" >&2; }
err(){ printf '[ERROR] %s\n' "$*" | tee -a "$LOG" >&2; }
die(){ err "$*"; exit 1; }

usage(){
  cat <<EOF
Usage: $0 [--dry-run] [--auto] [--force] [-j N] [-h]
  --dry-run    Show actions without making changes
  --auto       Non-interactive (accept defaults)
  --force      Aggressive non-interactive mode (overwrite without prompts)
  -j N         Set parallel emerge jobs
  -h           Help
EOF
}

# parse args
while [[ "${1:-}" != "" ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --auto) AUTO_MODE=true; shift ;;
    --force) FORCE_MODE=true; shift ;;
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

# Non-interactive confirmation (always yes if force or auto)
confirm_noprompt(){
  if $FORCE_MODE || $AUTO_MODE; then
    echo "y"
  else
    # fallback: no prompts in this script unless explicitly required
    echo "y"
  fi
}

# trap and rollback
CURRENT_BACKUP=""
trap 'on_error $?' ERR
on_error(){
  local rc=${1:-1}
  err "Script exited with code $rc. Attempting best-effort rollback..."
  if [[ -n "$CURRENT_BACKUP" && -f "$CURRENT_BACKUP" ]]; then
    warn "Restoring backup $CURRENT_BACKUP ..."
    if $DRY_RUN; then
      log "DRY-RUN: tar -xzf $CURRENT_BACKUP -C /"
    else
      tar -xzf "$CURRENT_BACKUP" -C / || warn "Rollback tar extraction returned non-zero"
      log "Rollback attempted."
    fi
  else
    warn "No backup recorded."
  fi
  err "See $LOG for details."
  exit $rc
}

make_backup(){
  mkdir -p "$BACKUP_DIR"
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  local backupfile="$BACKUP_DIR/gentoo_autobuilder_backup_${ts}.tar.gz"
  CURRENT_BACKUP="$backupfile"
  local files=(/etc/portage/make.conf /etc/fstab /etc/default/grub /etc/local.d /etc/kernel-configs /boot /etc/portage)
  log "Creating backup $backupfile ..."
  if $DRY_RUN; then
    log "DRY-RUN: tar -czf $backupfile ${files[*]}"
  else
    tar -czf "$backupfile" --absolute-names "${files[@]}" || warn "tar returned non-zero (some files may be missing)"
    log "Backup created: $backupfile"
    # rotate old backups
    ls -1t "$BACKUP_DIR"/gentoo_autobuilder_backup_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS+1)) | xargs -r rm -f
  fi
}

# portage helpers
is_installed_pkg(){
  local atom="$1"
  if command -v equery &>/dev/null; then
    equery list "$atom" >/dev/null 2>&1 && return 0
  fi
  [[ -d /var/db/pkg ]] && find /var/db/pkg -maxdepth 2 -type d -name "${atom##*/}*" | grep -q . && return 0
  return 1
}

emerge_with_autounmask(){
  local pkg="$1"
  local extra_flags="${2:-}"
  log "Emerge attempt: $pkg"
  if $DRY_RUN; then
    log "DRY-RUN: emerge -j${EMERGE_JOBS} --load-average=${EMERGE_LOAD} ${EMERGE_BASE_OPTS[*]} ${extra_flags} $pkg"
    return 0
  fi
  # non-interactive emerges: add --autounmask-write and continue if needed
  if emerge -j"${EMERGE_JOBS}" --load-average="${EMERGE_LOAD}" "${EMERGE_BASE_OPTS[@]}" ${extra_flags} "$pkg"; then
    return 0
  fi
  warn "Initial emerge failed; trying --autounmask-write"
  if emerge -j"${EMERGE_JOBS}" --load-average="${EMERGE_LOAD}" --autounmask-write=y ${extra_flags} "$pkg"; then
    command -v etc-update &>/dev/null && etc-update --automode -5 || true
    command -v dispatch-conf &>/dev/null && dispatch-conf --auto-merge || true
    emerge -j"${EMERGE_JOBS}" --load-average="${EMERGE_LOAD}" "${EMERGE_BASE_OPTS[@]}" ${extra_flags} "$pkg" || {
      warn "Emerges failed after autounmask"
      return 1
    }
    return 0
  fi
  warn "Could not autounmask/install $pkg automatically"
  return 1
}

# prechecks
if [[ "$(id -u)" -ne 0 ]]; then die "Run as root"; fi
if ! command -v make &>/dev/null; then die "make not found. Please install build tools manually (script will not auto-install sys-devel/make)."; fi

check_network(){
  log "Checking network..."
  if ping -c1 -W2 gentoo.org &>/dev/null || ping -c1 -W2 8.8.8.8 &>/dev/null; then
    log "Network OK"
  else
    warn "Network unreachable (continuing due to non-interactive mode)"
  fi
}

# ensure /usr/src/linux -> newest linux-*
ensure_usr_src_symlink(){
  log "Ensuring /usr/src/linux points to newest linux-*"
  if [[ ! -d /usr/src ]]; then die "/usr/src missing"; fi
  pushd /usr/src >/dev/null 2>&1
  local latest
  latest="$(ls -d linux-* 2>/dev/null | sort -V | tail -n1 || true)"
  if [[ -z "$latest" ]]; then die "No linux-* found under /usr/src"; fi
  if [[ -L linux ]]; then
    local curr
    curr="$(readlink -f linux)"
    if [[ "$(basename "$curr")" != "$latest" ]]; then
      run_or_dry ln -sf "$latest" linux
      log "Updated /usr/src/linux -> $latest"
    else
      log "/usr/src/linux already -> $latest"
    fi
  else
    if [[ -d linux ]]; then
      run_or_dry mv linux "linux.backup.$(date +%Y%m%d_%H%M%S)" || true
      log "Backed up existing /usr/src/linux directory"
    fi
    run_or_dry ln -sf "$latest" linux
    log "Created /usr/src/linux symlink -> $latest"
  fi
  popd >/dev/null 2>&1
}

# partition detection (auto detect root and EFI)
detect_partitions(){
  log "Detecting root and EFI partitions"
  ROOT_DEV="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  if [[ -n "$ROOT_DEV" && -b "$ROOT_DEV" ]]; then
    ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)"
    ROOT_FSTYPE="$(blkid -s TYPE -o value "$ROOT_DEV" 2>/dev/null || true)"
    log "Detected root: $ROOT_DEV UUID=$ROOT_UUID TYPE=$ROOT_FSTYPE"
  fi

  EFI_DEV="$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)"
  if [[ -n "$EFI_DEV" && -b "$EFI_DEV" ]]; then
    EFI_UUID="$(blkid -s UUID -o value "$EFI_DEV" 2>/dev/null || true)"
    EFI_FSTYPE="$(blkid -s TYPE -o value "$EFI_DEV" 2>/dev/null || true)"
    log "Detected EFI mount: $EFI_DEV UUID=$EFI_UUID TYPE=$EFI_FSTYPE"
  fi

  # if EFI not found, scan blkid for vfat or PARTLABEL containing EFI
  if [[ -z "${EFI_UUID:-}" ]]; then
    while IFS= read -r dev; do
      ftype="$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)"
      label="$(blkid -s PARTLABEL -o value "$dev" 2>/dev/null || true)"
      if [[ "$ftype" == "vfat" ]] || [[ "$label" =~ [Ee][Ff][Ii] ]]; then
        EFI_DEV="$dev"
        EFI_UUID="$(blkid -s UUID -o value "$dev" 2>/dev/null || true)"
        EFI_FSTYPE="$ftype"
        log "Selected EFI candidate: $EFI_DEV UUID=$EFI_UUID TYPE=$EFI_FSTYPE"
        break
      fi
    done < <(blkid -o device 2>/dev/null)
  fi

  # if root not found, pick largest xfs/ext4/btrfs
  if [[ -z "${ROOT_UUID:-}" || -z "${ROOT_DEV:-}" ]]; then
    log "Root not detected by findmnt; scanning for candidate partitions..."
    candidate=""
    candidate_size=0
    while IFS= read -r dev; do
      ftype="$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)"
      if [[ "$ftype" == "xfs" || "$ftype" == "ext4" || "$ftype" == "btrfs" ]]; then
        size=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)
        if (( size > candidate_size )); then
          candidate="$dev"
          candidate_size="$size"
        fi
      fi
    done < <(blkid -o device 2>/dev/null)
    if [[ -n "$candidate" ]]; then
      ROOT_DEV="$candidate"
      ROOT_UUID="$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)"
      ROOT_FSTYPE="$(blkid -s TYPE -o value "$ROOT_DEV" 2>/dev/null || true)"
      log "Selected root candidate: $ROOT_DEV UUID=$ROOT_UUID TYPE=$ROOT_FSTYPE"
    fi
  fi

  [[ -n "${ROOT_UUID:-}" ]] || warn "Root UUID not detected (script will continue but may fail)"
  [[ -n "${EFI_UUID:-}" ]] || warn "EFI UUID not detected (UEFI steps may fail)"
}

# create mountpoints, update fstab and mount (force/non-interactive)
create_mounts_and_update_fstab(){
  log "Creating /boot and /boot/efi if missing, updating /etc/fstab, attempting mount"
  run_or_dry mkdir -p /boot /boot/efi

  # root entry
  if [[ -n "${ROOT_UUID:-}" ]]; then
    if grep -q "UUID=${ROOT_UUID}" /etc/fstab 2>/dev/null; then
      log "Root UUID already in /etc/fstab"
    else
      if $DRY_RUN; then
        log "DRY-RUN: append root UUID ${ROOT_UUID} to /etc/fstab"
      else
        echo "UUID=${ROOT_UUID} / ${ROOT_FSTYPE:-xfs} defaults,noatime,logbufs=8,logbsize=256k 0 1" >> /etc/fstab
        log "Added root entry to /etc/fstab"
      fi
    fi
  else
    warn "Skipping root fstab entry (ROOT_UUID unknown)"
  fi

  # EFI entry
  if [[ -n "${EFI_UUID:-}" ]]; then
    if grep -q "UUID=${EFI_UUID}" /etc/fstab 2>/dev/null; then
      log "EFI UUID already in /etc/fstab"
    else
      if $DRY_RUN; then
        log "DRY-RUN: append EFI UUID ${EFI_UUID} to /etc/fstab"
      else
        echo "UUID=${EFI_UUID} /boot/efi vfat umask=0077,noatime 0 2" >> /etc/fstab
        log "Added /boot/efi entry to /etc/fstab"
      fi
    fi
  else
    warn "EFI UUID unknown; skipping /etc/fstab EFI entry"
  fi

  # udev settle
  command -v udevadm &>/dev/null && run_or_dry udevadm settle --timeout=10 || true

  # mount all
  if $DRY_RUN; then
    log "DRY-RUN: mount -a"
  else
    run_or_dry mount -a || true
  fi

  # if mount failed for EFI, attempt to mount by /dev/disk/by-uuid
  if [[ -n "${EFI_UUID:-}" ]] && ! mountpoint -q /boot/efi 2>/dev/null; then
    if [[ -e "/dev/disk/by-uuid/${EFI_UUID}" ]]; then
      run_or_dry mount -t vfat "/dev/disk/by-uuid/${EFI_UUID}" /boot/efi || warn "Mount by UUID for EFI failed"
    else
      warn "/dev/disk/by-uuid/${EFI_UUID} not present"
    fi
  fi

  # final check
  if ! mountpoint -q /boot 2>/dev/null && ! mountpoint -q /boot/efi 2>/dev/null; then
    warn "Neither /boot nor /boot/efi mounted. GRUB steps may fail."
    if ! $FORCE_MODE; then
      die "Boot mounts required. Rerun with --force to override."
    else
      warn "Continuing due to --force"
    fi
  fi
}

validate_fstab(){
  if command -v findmnt &>/dev/null; then
    if ! findmnt --verify >/dev/null 2>&1; then
      warn "/etc/fstab verification failed (continuing due to non-interactive/force)"
    fi
  fi
}

# kernel selection and symlink repair is separate function
select_and_prepare_kernel(){
  ensure_usr_src_symlink
  log "Selecting kernel (newest available in /usr/src)"
  mapfile -t KLIST < <(find /usr/src -maxdepth 1 -type d -name 'linux-*' -printf '%f\n' 2>/dev/null | sort -V)
  if [[ ${#KLIST[@]} -eq 0 ]]; then die "No kernel sources found under /usr/src"; fi
  # choose newest
  TARGET_KERNEL="${KLIST[-1]}"
  KERNEL_SRC="/usr/src/${TARGET_KERNEL}"
  log "Target kernel: ${TARGET_KERNEL}"
}

# Save .config
save_kernel_config(){
  mkdir -p "$KERNEL_CONFIG_STORE"
  if [[ -f "$KERNEL_SRC/.config" ]]; then
    cp -a "$KERNEL_SRC/.config" "$KERNEL_CONFIG_STORE/config-${TARGET_KERNEL}-$(date +%Y%m%d_%H%M%S)"
    log "Saved kernel .config to store"
  fi
}

# Force built-in options (uses scripts/config if available)
make_all_built_in(){
  log "Converting selected options to built-in (=y)"
  local cfg="$KERNEL_SRC/.config"
  if [[ ! -f "$cfg" ]]; then
    warn ".config missing; attempt to create from /proc/config.gz or defconfig"
    if [[ -f /proc/config.gz ]]; then
      if $DRY_RUN; then
        log "DRY-RUN: zcat /proc/config.gz > $cfg"
      else
        zcat /proc/config.gz > "$cfg" || true
      fi
    else
      run_or_dry bash -c "cd $KERNEL_SRC && make defconfig"
    fi
  fi
  [[ -f "$cfg" ]] && run_or_dry cp -a "$cfg" "${cfg}.autobuilder.bak.$(date +%Y%m%d_%H%M%S)"

  read -r -d '' BUILTIN_SYMBOLS <<'SYMS' || true
DEVTMPFS
DEVTMPFS_MOUNT
TMPFS
TMPFS_POSIX_ACL
EFI_STUB
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
    while read -r sym; do
      [[ -z "$sym" ]] && continue
      run_or_dry bash -c "cd $KERNEL_SRC && ./scripts/config --enable $sym || true"
    done <<< "$BUILTIN_SYMBOLS"
  else
    warn "scripts/config not found; will patch .config directly (try to convert =m -> =y)"
  fi

  if [[ -f "$cfg" ]]; then
    if $DRY_RUN; then
      log "DRY-RUN: sed -ri to convert CONFIG_*=m -> =y and enforce symbols"
    else
      sed -ri 's/^(CONFIG_[A-Za-z0-9_]+=)m$/\1y/' "$cfg" || true
      while read -r sym; do
        [[ -z "$sym" ]] && continue
        if ! grep -q "^CONFIG_${sym}=" "$cfg"; then
          echo "CONFIG_${sym}=y" >> "$cfg"
        else
          sed -i "s/^CONFIG_${sym}=.*/CONFIG_${sym}=y/" "$cfg"
        fi
      done <<< "$BUILTIN_SYMBOLS"
    fi
  fi

  # olddefconfig fallback
  if $DRY_RUN; then
    log "DRY-RUN: make olddefconfig || make defconfig"
  else
    pushd "$KERNEL_SRC" >/dev/null 2>&1
    if make olddefconfig 2>/dev/null; then
      log "make olddefconfig succeeded"
    else
      warn "make olddefconfig failed; trying make defconfig"
      make defconfig
    fi
    popd >/dev/null 2>&1
  fi
}

# build kernel and install artifacts
build_kernel(){
  log "Building kernel ${TARGET_KERNEL}"
  if [[ ! -d "$KERNEL_SRC" ]]; then die "Kernel source $KERNEL_SRC missing"; fi
  save_kernel_config
  make_all_built_in

  if $DRY_RUN; then
    log "DRY-RUN: make -j${EMERGE_JOBS} in $KERNEL_SRC"
  else
    pushd "$KERNEL_SRC" >/dev/null 2>&1
    make -j"${EMERGE_JOBS}" 2>&1 | tee -a "$LOG"
    popd >/dev/null 2>&1
  fi

  # copy images to /boot
  run_or_dry mkdir -p /boot
  if $DRY_RUN; then
    log "DRY-RUN: copy kernel image and System.map/.config to /boot"
  else
    if [[ -f "$KERNEL_SRC/arch/x86/boot/bzImage" ]]; then
      cp -a "$KERNEL_SRC/arch/x86/boot/bzImage" "/boot/vmlinuz-${TARGET_KERNEL}"
    elif [[ -f "$KERNEL_SRC/arch/x86/boot/vmlinuz" ]]; then
      cp -a "$KERNEL_SRC/arch/x86/boot/vmlinuz" "/boot/vmlinuz-${TARGET_KERNEL}"
    else
      warn "Kernel image not found in expected locations"
    fi
    cp -a "$KERNEL_SRC/System.map" "/boot/System.map-${TARGET_KERNEL}" 2>/dev/null || true
    cp -a "$KERNEL_SRC/.config" "/boot/config-${TARGET_KERNEL}" 2>/dev/null || true
    log "Kernel artifacts copied to /boot"
  fi

  # genkernel initramfs
  if ! command -v genkernel &>/dev/null; then
    warn "genkernel not installed; attempting to emerge genkernel (non-interactive)"
    emerge_with_autounmask "sys-kernel/genkernel" || warn "Failed to install genkernel"
  fi
  if command -v genkernel &>/dev/null; then
    run_or_dry genkernel --install --no-mrproper initramfs
  else
    warn "genkernel unavailable; initramfs not created"
  fi
}

# GRUB/UEFI update and set default
determine_grub_cfg(){ if [[ -d /boot/efi/EFI/gentoo ]]; then echo "/boot/efi/EFI/gentoo/grub.cfg"; else echo "/boot/grub/grub.cfg"; fi; }
update_grub(){
  local cfg
  cfg="$(determine_grub_cfg)"
  run_or_dry grub-mkconfig -o "$cfg"
  if command -v efibootmgr &>/dev/null && ! $DRY_RUN; then
    efipart=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)
    if [[ -n "$efipart" ]]; then
      efibootmgr -c -l '\EFI\gentoo\grubx64.efi' -L "Gentoo ${TARGET_KERNEL}" 2>/dev/null || warn "efibootmgr entry creation failed"
    fi
  fi
}

set_grub_default(){
  local cfg title
  cfg="$(determine_grub_cfg)"
  if $DRY_RUN; then
    log "DRY-RUN: grub-set-default for vmlinuz-${TARGET_KERNEL}"
    return 0
  fi
  if [[ ! -f "$cfg" ]]; then warn "grub.cfg not found"; return 1; fi
  if ! grep -q "vmlinuz-${TARGET_KERNEL}" "$cfg"; then warn "grub.cfg does not reference vmlinuz-${TARGET_KERNEL}"; return 1; fi
  title=$(awk -v pat="vmlinuz-${TARGET_KERNEL}" '/^menuentry /{t=$0} $0 ~ pat {gsub(/^menuentry '\''/,"",t); gsub(/'\''.*/,"",t); print t; exit}' "$cfg" || true)
  if [[ -n "$title" ]]; then
    run_or_dry grub-set-default "$title" || warn "grub-set-default failed"
  else
    warn "Could not determine grub menu title"
  fi
}

# make.conf optimize
optimize_makeconf(){
  log "Optimizing /etc/portage/make.conf for AMD A10"
  local conf="/etc/portage/make.conf"
  local bak="/etc/portage/make.conf.autobuilder.bak"
  [[ -f "$conf" ]] || touch "$conf"
  [[ -f "$bak" ]] || cp -a "$conf" "$bak"
  local cores
  cores="$(get_cpu_cores)"
  local makeopts="-j$((cores+1)) -l${cores}"
  local march="-march=bdver4"
  if $DRY_RUN; then
    log "DRY-RUN: write optimized /etc/portage/make.conf"
  else
    cat > "$conf" <<EOF
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
  if $DRY_RUN; then
    log "DRY-RUN: write sysctl and udev rules"
  else
    cat > /etc/sysctl.d/99-gentoo-hdd.conf <<EOF
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
      if ! $DRY_RUN; then
        echo 'ACTION=="add|change", KERNEL=="'"$bname"'", ATTR{queue/scheduler}="bfq"' > /etc/udev/rules.d/60-io-"$bname".rules
      fi
    else
      run_or_dry bash -c "echo mq-deadline > /sys/block/$bname/queue/scheduler" || true
    fi
  done

  if grep -q 'xfs' /etc/fstab 2>/dev/null; then
    run_or_dry sed -ri 's|(\b[xX][fF][sS]\b[^ ]* )defaults|\1defaults,noatime,logbufs=8,logbsize=256k|' /etc/fstab || true
  fi

  if ! grep -q '/var/tmp/portage' /etc/fstab 2>/dev/null; then
    run_or_dry bash -c 'echo "tmpfs /var/tmp/portage tmpfs size=4G,noatime,nodev,nosuid,mode=1777 0 0" >> /etc/fstab'
  fi
  if ! grep -q '/tmp' /etc/fstab 2>/dev/null; then
    run_or_dry bash -c 'echo "tmpfs /tmp tmpfs size=2G,noatime,nodev,nosuid,mode=1777 0 0" >> /etc/fstab'
  fi
}

# local power script
install_power_scripts(){
  log "Installing power management script (OpenRC local.d)"
  if $DRY_RUN; then
    log "DRY-RUN: create /etc/local.d/power.start and rc-update add local"
  else
    mkdir -p /etc/local.d
    cat > /etc/local.d/power.start <<'EOF'
#!/bin/sh
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
EOF
    chmod +x /etc/local.d/power.start
    run_or_dry rc-update add local default || true
  fi
}

# install xfce & enable lightdm
install_xfce(){
  log "Installing XFCE/Xorg/LightDM (non-interactive)"
  local packages=(x11-base/xorg-server x11-base/xorg-drivers x11-misc/lightdm x11-misc/lightdm-gtk-greeter xfce-base/xfce4-meta xfce-extra/xfce4-goodies media-libs/mesa x11-drivers/xf86-video-amdgpu app-admin/eselect-opengl app-misc/pciutils app-misc/usbutils)
  for p in "${packages[@]}"; do
    if is_installed_pkg "$p"; then
      log "$p already installed"
    else
      emerge_with_autounmask "$p" || warn "Failed to install $p (continuing)"
    fi
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
  log "XFCE and LightDM configured (no autologin)"
}

# cleanup and cron
auto_cleanup(){
  log "Auto cleanup"
  run_or_dry eclean-kernel -n 2 || true
  run_or_dry eclean-dist --deep || true
  run_or_dry eclean-pkg --deep || true
  run_or_dry rm -rf /var/tmp/portage/* /tmp/* || true
  df -h | tee -a "$LOG"
  log "Cleanup complete"
}

install_cron(){
  local cronfile="/etc/cron.d/gentoo_autobuilder_force"
  if $DRY_RUN; then
    log "DRY-RUN: create cron job"
  else
    cat > "$cronfile" <<EOF
# Weekly maintenance (non-interactive)
0 4 * * 1 root /usr/local/sbin/gentoo_autobuilder_force.sh --force >> /var/log/gentoo_autobuilder_cron.log 2>&1
EOF
    chmod 644 "$cronfile"
    if grep -q '^rc_parallel=' /etc/rc.conf 2>/dev/null; then sed -i 's/^rc_parallel=.*/rc_parallel="YES"/' /etc/rc.conf || true; else echo 'rc_parallel="YES"' >> /etc/rc.conf; fi
    log "Cron installed and parallel boot enabled"
  fi
}

# main
main(){
  log "Gentoo AutoBuilder Force start: $(date --iso-8601=seconds)"
  check_network
  make_backup
  ensure_usr_src_symlink
  detect_partitions
  create_mounts_and_update_fstab
  validate_fstab
  select_and_prepare_kernel
  build_kernel
  update_grub
  set_grub_default
  optimize_makeconf
  optimize_hdd_xfs
  install_power_scripts
  install_xfce
  auto_cleanup
  install_cron
  log "Completed successfully: $(date --iso-8601=seconds)"
}

main "$@"

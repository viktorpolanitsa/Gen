#!/bin/bash
set -euo pipefail

# gentoo_autobuilder_pro_builtin_final.sh
# Full Gentoo AutoBuilder Pro (built-in kernel) final script
# - OpenRC + UEFI + XFS + XFCE
# - Kernel selection, force built-in config, genkernel initramfs, GRUB update
# - make.conf optimization for AMD A10, HDD/XFS/PWR tuning
# - Backups, rollback (best-effort), dry-run and auto modes
# - DOES NOT install sys-devel/make automatically (user requested)

LOG="/var/log/gentoo_autobuilder_pro_builtin_final.log"
: > "$LOG"

# === Default partition UUIDs (override if needed) ===
EFI_UUID="${EFI_UUID:-CD9F-1D11}"                          # /dev/sda1 vfat
ROOT_UUID="${ROOT_UUID:-a13ed2b3-12b6-45a3-8076-4d275a46c0b5}"  # /dev/sda2 xfs

# === Configurable variables ===
BACKUP_DIR="/var/backups/gentoo_autobuilder"
KEEP_BACKUPS=3
KERNEL_CONFIG_STORE="/etc/kernel-configs"
DRY_RUN=false
AUTO_MODE=false
EMERGE_JOBS=""
EMERGE_LOAD=""

# === Emergence base opts (do not include --ask to allow non-interactive) ===
EMERGE_BASE_OPTS=(--verbose --quiet-build=y --with-bdeps=y)

# === Logging helpers ===
log()   { printf '[INFO] %s\n' "$*" | tee -a "$LOG"; }
warn()  { printf '[WARN] %s\n' "$*" | tee -a "$LOG" >&2; }
err()   { printf '[ERROR] %s\n' "$*" | tee -a "$LOG" >&2; }
die()   { err "$*"; exit 1; }

usage(){
  cat <<EOF
Usage: $0 [--dry-run] [--auto] [-j N] [-h]
  --dry-run    Show actions without making changes
  --auto       Non-interactive (accept defaults)
  -j N         Set parallel emerge jobs
  -h           Help
EOF
}

# === Args ===
while [[ "${1:-}" != "" ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --auto) AUTO_MODE=true; shift ;;
    -j) shift; EMERGE_JOBS="${1:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

get_cpu_cores(){
  if command -v nproc &>/dev/null; then nproc --all; else echo 4; fi
}
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
  if $AUTO_MODE; then
    [[ "$default" == "y" ]] && echo "y" || echo "n"
    return
  fi
  read -r -p "$prompt" ans
  ans="${ans:-$default}"
  ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
  echo "${ans:0:1}"
}

# === Safety: trap and rollback ===
CURRENT_BACKUP=""
trap 'on_error $?' ERR
on_error(){
  local rc=${1:-1}
  err "Script failed (exit $rc). Attempting rollback if backup exists."
  if [[ -n "$CURRENT_BACKUP" && -f "$CURRENT_BACKUP" ]]; then
    warn "Restoring backup $CURRENT_BACKUP ..."
    if $DRY_RUN; then
      log "DRY-RUN: restore from $CURRENT_BACKUP"
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
    # rotate
    ls -1t "$BACKUP_DIR"/gentoo_autobuilder_backup_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS+1)) | xargs -r rm -f
  fi
}

# === Portage helpers ===
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
  log "Emerge attempt: $pkg"
  if $DRY_RUN; then
    log "DRY-RUN: emerge -j${EMERGE_JOBS} --load-average=${EMERGE_LOAD} ${EMERGE_BASE_OPTS[*]} $pkg"
    return 0
  fi
  if emerge -j"${EMERGE_JOBS}" --load-average="${EMERGE_LOAD}" "${EMERGE_BASE_OPTS[@]}" "$pkg"; then return 0; fi
  warn "Initial emerge failed; trying autounmask-write..."
  if emerge -j"${EMERGE_JOBS}" --load-average="${EMERGE_LOAD}" --autounmask-write=y "$pkg"; then
    if command -v etc-update &>/dev/null; then etc-update --automode -5 || true; fi
    if command -v dispatch-conf &>/dev/null; then dispatch-conf --auto-merge || true; fi
    emerge -j"${EMERGE_JOBS}" --load-average="${EMERGE_LOAD}" "${EMERGE_BASE_OPTS[@]}" "$pkg" || return 1
    return 0
  fi
  warn "Could not autounmask/install $pkg automatically."
  return 1
}

# === Prechecks ===
if [[ "$(id -u)" -ne 0 ]]; then die "Run as root"; fi
if ! command -v make &>/dev/null; then die "make not found. Please install build tools (user requested not to auto-install sys-devel/make)"; fi

check_network(){
  log "Checking network..."
  if ping -c1 -W2 gentoo.org &>/dev/null || ping -c1 -W2 8.8.8.8 &>/dev/null; then
    log "Network OK"
  else
    warn "Network unreachable"
    if [[ "$(confirm 'Continue without network? [y/N] ' 'n')" != "y" ]]; then die "Network required"; fi
  fi
}

check_and_mount_boots(){
  # Ensure /boot and /boot/efi entries exist in /etc/fstab; if not, add them using provided UUIDs.
  log "Ensuring / and /boot/efi entries in /etc/fstab"
  # Root (xfs)
  if ! grep -q ' / ' /etc/fstab 2>/dev/null; then
    log "/etc/fstab missing root entry; adding using ROOT_UUID"
    if $DRY_RUN; then
      log "DRY-RUN: echo 'UUID=${ROOT_UUID} / xfs defaults,noatime,logbufs=8,logbsize=256k 0 1' >> /etc/fstab"
    else
      echo "UUID=${ROOT_UUID} / xfs defaults,noatime,logbufs=8,logbsize=256k 0 1" >> /etc/fstab
    fi
  fi

  # EFI mount (common path /boot/efi)
  if ! grep -q '/boot/efi' /etc/fstab 2>/dev/null; then
    log "/etc/fstab missing /boot/efi entry; adding using EFI_UUID"
    if $DRY_RUN; then
      log "DRY-RUN: echo 'UUID=${EFI_UUID} /boot/efi vfat umask=0077,noatime 0 2' >> /etc/fstab"
    else
      echo "UUID=${EFI_UUID} /boot/efi vfat umask=0077,noatime 0 2" >> /etc/fstab
    fi
  fi

  # Ensure /boot exists and mount it: if EFI uses /boot/efi, we still ensure /boot exists
  if [[ ! -d /boot ]]; then
    run_or_dry mkdir -p /boot
  fi
  if ! mountpoint -q /boot; then
    # Try mounting /boot (will mount /boot/efi when fstab has /boot/efi)
    if $DRY_RUN; then
      log "DRY-RUN: mount -a"
    else
      run_or_dry mount -a || true
      if ! mountpoint -q /boot; then
        warn "/boot still not mounted after mount -a; attempt to mount /boot/efi specifically"
        if $DRY_RUN; then
          log "DRY-RUN: mount /boot/efi"
        else
          mount /boot/efi >/dev/null 2>&1 || warn "mount /boot/efi failed"
        fi
      fi
    fi
  fi

  # Check /boot space
  if mountpoint -q /boot; then
    avail_kb=$(df --output=avail -k /boot | tail -n1)
    if [[ -n "$avail_kb" && "$avail_kb" -lt $((50*1024)) ]]; then
      warn "/boot available space <50MB ($avail_kb KB)"
      if [[ "$(confirm 'Continue despite small /boot? [y/N] ' 'n')" != "y" ]]; then die "/boot too small"; fi
    fi
  else
    warn "/boot not mounted - some operations (grub update) may fail"
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

# === Kernel selection ===
select_kernel(){
  log "Scanning /usr/src for linux-* directories..."
  mapfile -t KLIST < <(find /usr/src -maxdepth 1 -type d -name 'linux-*' -printf '%f\n' 2>/dev/null | sort -V)
  if [[ ${#KLIST[@]} -eq 0 ]]; then die "No kernel sources found in /usr/src"; fi
  echo "Available kernels:"
  for i in "${!KLIST[@]}"; do
    printf " [%d] %s\n" $((i+1)) "${KLIST[$i]}"
  done
  if $AUTO_MODE; then
    choice=1
    log "AUTO_MODE: selecting ${KLIST[0]}"
  else
    read -r -p "Enter kernel number to use: " choice
  fi
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

# === Force built-in ===
make_all_built_in(){
  log "Forcing key kernel options to built-in (=y)"
  cfg="$KERNEL_SRC/.config"
  if [[ ! -f "$cfg" ]]; then
    warn ".config not found; attempting to create from running kernel or defconfig"
    if [[ -f /proc/config.gz ]]; then
      zcat /proc/config.gz > "$cfg" || true
    else
      run_or_dry bash -c "cd $KERNEL_SRC && make defconfig"
    fi
  fi
  # backup
  if [[ -f "$cfg" ]]; then cp -a "$cfg" "${cfg}.autobuilder.bak.$(date +%Y%m%d_%H%M%S)"; fi

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

  # Use scripts/config if present
  if [[ -x "$KERNEL_SRC/scripts/config" ]]; then
    log "Using scripts/config to enable symbols"
    while read -r sym; do
      [[ -z "$sym" ]] && continue
      run_or_dry bash -c "cd $KERNEL_SRC && ./scripts/config --enable $sym || true"
    done <<< "$BUILTIN_SYMBOLS"
  else
    warn "scripts/config not available; will patch .config directly"
  fi

  # replace CONFIG_FOO=m -> CONFIG_FOO=y
  if [[ -f "$cfg" ]]; then
    if $DRY_RUN; then
      log "DRY-RUN: would convert CONFIG_* = m to = y in $cfg"
    else
      sed -ri 's/^(CONFIG_[A-Za-z0-9_]+=)m$/\1y/' "$cfg" || true
      while read -r sym; do
        [[ -z "$sym" ]] && continue
        if ! grep -q "^CONFIG_${sym}=" "$cfg"; then echo "CONFIG_${sym}=y" >> "$cfg"; else sed -i "s/^CONFIG_${sym}=.*/CONFIG_${sym}=y/" "$cfg"; fi
      done <<< "$BUILTIN_SYMBOLS"
    fi
  fi

  run_or_dry bash -c "cd $KERNEL_SRC && make olddefconfig"
  log "Built-in conversion applied"
}

# === Build kernel (no modules_install) ===
build_kernel(){
  log "Building kernel ${TARGET_KERNEL} with built-in drivers"
  if [[ ! -d "$KERNEL_SRC" ]]; then die "Kernel source $KERNEL_SRC missing"; fi
  save_kernel_config
  make_all_built_in
  if $DRY_RUN; then
    log "DRY-RUN: make -j${EMERGE_JOBS} in $KERNEL_SRC"
  else
    (cd "$KERNEL_SRC" && make -j"${EMERGE_JOBS}") 2>&1 | tee -a "$LOG"
  fi

  # copy kernel artifacts
  if $DRY_RUN; then
    log "DRY-RUN: copy bzImage to /boot/vmlinuz-${TARGET_KERNEL}"
  else
    cp -a "$KERNEL_SRC/arch/x86/boot/bzImage" "/boot/vmlinuz-${TARGET_KERNEL}"
    cp -a "$KERNEL_SRC/System.map" "/boot/System.map-${TARGET_KERNEL}" 2>/dev/null || true
    cp -a "$KERNEL_SRC/.config" "/boot/config-${TARGET_KERNEL}" 2>/dev/null || true
    log "Kernel installed to /boot for ${TARGET_KERNEL}"
  fi

  # ensure genkernel
  if ! command -v genkernel &>/dev/null; then
    warn "genkernel not installed; attempting to install"
    emerge_with_autounmask "sys-kernel/genkernel" || warn "Failed to install genkernel"
  fi
  if command -v genkernel &>/dev/null; then
    run_or_dry genkernel --install --no-mrproper initramfs
  else
    warn "genkernel not available; initramfs not built"
  fi
}

# === GRUB/UEFI handling ===
determine_grub_cfg(){
  if [[ -d /boot/efi/EFI/gentoo ]]; then echo "/boot/efi/EFI/gentoo/grub.cfg"; else echo "/boot/grub/grub.cfg"; fi
}
update_grub(){
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
  cfg="$(determine_grub_cfg)"
  if $DRY_RUN; then
    log "DRY-RUN: set grub default for vmlinuz-${TARGET_KERNEL}"
    return 0
  fi
  if [[ ! -f "$cfg" ]]; then warn "grub.cfg not found"; return 1; fi
  if ! grep -q "vmlinuz-${TARGET_KERNEL}" "$cfg"; then warn "grub.cfg does not reference vmlinuz-${TARGET_KERNEL}"; return 1; fi
  local title
  title=$(awk -v pat="vmlinuz-${TARGET_KERNEL}" '
    /^menuentry /{title_line=$0}
    $0 ~ pat { gsub(/^menuentry '\''/,"",title_line); gsub(/'\''.*/,"",title_line); print title_line; exit }
  ' "$cfg" || true)
  if [[ -n "$title" ]]; then
    run_or_dry grub-set-default "$title" || warn "grub-set-default failed"
  else
    warn "Could not determine menu title; leaving default"
  fi
}

# === make.conf optimization ===
optimize_makeconf(){
  conf="/etc/portage/make.conf"
  backup="/etc/portage/make.conf.autobuilder.bak"
  [[ -f "$conf" ]] || touch "$conf"
  [[ -f "$backup" ]] || cp -a "$conf" "$backup"
  cores=$(get_cpu_cores)
  makeopts="-j$((cores+1)) -l${cores}"
  march="-march=bdver4"
  if $DRY_RUN; then
    log "DRY-RUN: would write optimized /etc/portage/make.conf"
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
    log "/etc/portage/make.conf written (backup: $backup)"
  fi
}

# === HDD/XFS tuning ===
optimize_hdd_xfs(){
  log "Applying HDD and XFS tuning"
  if $DRY_RUN; then
    log "DRY-RUN: write /etc/sysctl.d/99-gentoo-hdd.conf"
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

  # set scheduler per block device
  for dev in /sys/block/*; do
    [[ -e "$dev/queue/rotational" ]] || continue
    rot=$(cat "$dev/queue/rotational")
    bname=$(basename "$dev")
    if [[ "$rot" == "1" ]]; then
      run_or_dry bash -c "echo bfq > /sys/block/$bname/queue/scheduler" || warn "Cannot set scheduler for $bname"
      if $DRY_RUN; then
        log "DRY-RUN: create /etc/udev/rules.d/60-io-$bname.rules"
      else
        echo 'ACTION=="add|change", KERNEL=="'"$bname"'", ATTR{queue/scheduler}="bfq"' > /etc/udev/rules.d/60-io-"$bname".rules
      fi
    else
      run_or_dry bash -c "echo mq-deadline > /sys/block/$bname/queue/scheduler" || true
    fi
  done

  # XFS mount options in fstab
  if grep -q 'xfs' /etc/fstab 2>/dev/null; then
    run_or_dry sed -ri 's|(\b[xX][fF][sS]\b[^ ]* )defaults|\1defaults,noatime,logbufs=8,logbsize=256k|' /etc/fstab || true
  fi

  # tmpfs for portage and tmp
  if ! grep -q '/var/tmp/portage' /etc/fstab 2>/dev/null; then
    run_or_dry bash -c 'echo "tmpfs /var/tmp/portage tmpfs size=4G,noatime,nodev,nosuid,mode=1777 0 0" >> /etc/fstab'
  fi
  if ! grep -q '/tmp' /etc/fstab 2>/dev/null; then
    run_or_dry bash -c 'echo "tmpfs /tmp tmpfs size=2G,noatime,nodev,nosuid,mode=1777 0 0" >> /etc/fstab'
  fi
}

# === Power scripts (local.d) ===
install_power_scripts(){
  log "Installing power management script"
  if $DRY_RUN; then
    log "DRY-RUN: write /etc/local.d/power.start and rc-update add local"
  else
    mkdir -p /etc/local.d
    cat > /etc/local.d/power.start <<'EOF'
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

# === XFCE/XORG installation & enable LightDM ===
install_xfce(){
  log "Installing XFCE and Xorg"
  packages=(x11-base/xorg-server x11-base/xorg-drivers x11-misc/lightdm x11-misc/lightdm-gtk-greeter xfce-base/xfce4-meta xfce-extra/xfce4-goodies media-libs/mesa x11-drivers/xf86-video-amdgpu app-admin/eselect-opengl app-misc/pciutils app-misc/usbutils)
  for p in "${packages[@]}"; do
    if is_installed_pkg "$p"; then
      log "$p already installed"
    else
      emerge_with_autounmask "$p" || warn "Failed to install $p"
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
  log "XFCE and LightDM configured"
}

# === ccache/distcc optional ===
install_ccache_distcc(){
  log "Installing ccache and distcc (optional)"
  emerge_with_autounmask "dev-util/ccache" || warn "ccache failed"
  emerge_with_autounmask "sys-devel/distcc" || warn "distcc failed"
  if ! grep -q "ccache" /etc/portage/make.conf 2>/dev/null; then
    run_or_dry bash -c 'echo "FEATURES=\"${FEATURES} ccache\"" >> /etc/portage/make.conf'
  fi
}

# === cleanup ===
auto_cleanup(){
  log "Running auto cleanup (eclean-kernel, eclean-dist, eclean-pkg)"
  run_or_dry eclean-kernel -n 2 || true
  run_or_dry eclean-dist --deep || true
  run_or_dry eclean-pkg --deep || true
  run_or_dry rm -rf /var/tmp/portage/* /tmp/* || true
  df -h | tee -a "$LOG"
  log "Cleanup done"
}

# === cron & parallel boot ===
install_cron(){
  cronfile="/etc/cron.d/gentoo_autobuilder"
  if $DRY_RUN; then
    log "DRY-RUN: write $cronfile and enable parallel boot"
  else
    cat > "$cronfile" <<EOF
# Weekly maintenance
0 4 * * 1 root /usr/local/sbin/gentoo_autobuilder_pro_builtin_final.sh --auto >> /var/log/gentoo_autobuilder_cron.log 2>&1
EOF
    chmod 644 "$cronfile"
    if grep -q '^rc_parallel=' /etc/rc.conf 2>/dev/null; then
      sed -i 's/^rc_parallel=.*/rc_parallel="YES"/' /etc/rc.conf || true
    else
      echo 'rc_parallel="YES"' >> /etc/rc.conf
    fi
    log "Cron installed and parallel boot enabled"
  fi
}

# === Main flow ===
main(){
  log "Gentoo AutoBuilder Pro (built-in) start: $(date --iso-8601=seconds)"
  check_network
  check_and_mount_boots
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

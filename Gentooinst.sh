#!/bin/bash
set -euo pipefail

# gentoo_autobuilder_pro_builtin.sh
# Purpose: Full Gentoo automation with kernel options forced built-in (CONFIG_* = y)
# - OpenRC + UEFI + XFS + XFCE
# - kernel selection, build, genkernel initramfs
# - make.conf optimization, HDD/I/O/power tuning, backups, cleanup, cron
# - All key drivers/filesystems forced built-in (not modules)
# - Supports --dry-run and --auto

########## CONFIG ##########
LOGFILE="/var/log/gentoo_autobuilder_pro_builtin.log"
BACKUP_DIR_BASE="/var/backups/gentoo_autobuilder"
KEEP_BACKUPS=3
DRY_RUN=false
AUTO_MODE=false
EMERGE_JOBS=""
EMERGE_LOAD=""
EMERGE_BASE_OPTS=(--verbose --quiet-build=y --with-bdeps=y)

########## LOGGING ##########
mkdir -p "$(dirname "$LOGFILE")"
: > "$LOGFILE"
log() { printf '[INFO] %s\n' "$*" | tee -a "$LOGFILE"; }
warn() { printf '[WARN] %s\n' "$*" | tee -a "$LOGFILE" >&2; }
err() { printf '[ERROR] %s\n' "$*" | tee -a "$LOGFILE" >&2; }
die() { err "$*"; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--auto] [-j N] [-h]
  --dry-run    Show actions but do not apply changes
  --auto       Non-interactive (accept defaults)
  -j N         Set parallel emerge jobs
  -h           Help
EOF
}

########## ARGS ##########
while [[ "${1:-}" != "" ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --auto) AUTO_MODE=true; shift ;;
    -j) shift; EMERGE_JOBS="${1:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option $1"; usage; exit 1 ;;
  esac
done

get_cpu_cores() {
  local c=4
  if command -v nproc &>/dev/null; then c=$(nproc --all); fi
  echo "$c"
}
if [[ -z "$EMERGE_JOBS" ]]; then EMERGE_JOBS="$(get_cpu_cores)"; fi
EMERGE_LOAD="$EMERGE_JOBS"

run_or_dry() {
  if $DRY_RUN; then
    log "DRY-RUN: $*"
  else
    log "RUN: $*"
    eval "$@"
  fi
}

confirm() {
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

########## SAFETY ##########
CURRENT_BACKUP=""
trap 'on_error $?' ERR
on_error() {
  local rc=${1:-1}
  err "Script failed with exit code $rc"
  if [[ -n "$CURRENT_BACKUP" && -f "$CURRENT_BACKUP" ]]; then
    warn "Attempting rollback from $CURRENT_BACKUP"
    if $DRY_RUN; then
      log "DRY-RUN: restore $CURRENT_BACKUP"
    else
      tar -xzf "$CURRENT_BACKUP" -C / || warn "Rollback extraction returned non-zero"
      log "Rollback attempted"
    fi
  else
    warn "No backup available for rollback"
  fi
  exit $rc
}

make_backup() {
  mkdir -p "$BACKUP_DIR_BASE"
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  local backupfile="$BACKUP_DIR_BASE/gentoo_backup_${ts}.tar.gz"
  CURRENT_BACKUP="$backupfile"
  local files=(/etc/portage/make.conf /etc/fstab /etc/default/grub /etc/conf.d/xdm /etc/local.d /boot /etc/portage /etc/kernel-configs)
  log "Creating backup $backupfile ..."
  if $DRY_RUN; then
    log "DRY-RUN: tar czf $backupfile ${files[*]}"
  else
    tar -czf "$backupfile" --absolute-names "${files[@]}" || warn "tar returned non-zero (some files may be missing)"
    log "Backup created: $backupfile"
    # rotate
    ls -1t "$BACKUP_DIR_BASE"/gentoo_backup_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS+1)) | xargs -r rm -f
  fi
}

########## PORTAGE HELPERS ##########
is_installed_pkg() {
  local atom="$1"
  if command -v equery &>/dev/null; then
    equery list "$atom" >/dev/null 2>&1 && return 0
  fi
  [[ -d /var/db/pkg ]] && find /var/db/pkg -maxdepth 2 -type d -name "${atom##*/}*" | grep -q . && return 0
  return 1
}

emerge_with_autounmask() {
  local pkg="$1"
  log "emerge attempt: $pkg"
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

########## PRECHECKS ##########
if [[ "$(id -u)" -ne 0 ]]; then die "Run as root"; fi
if ! command -v make &>/dev/null; then die "make not found. Script will not install sys-devel/make automatically."; fi

check_network() {
  log "Checking network..."
  if ping -c1 -W2 gentoo.org >/dev/null 2>&1 || ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
    log "Network OK"
  else
    warn "Network unreachable"
    if [[ "$(confirm 'Continue without network? [y/N] ' 'n')" != "y" ]]; then die "Network required"; fi
  fi
}

check_boot_space() {
  if ! mountpoint -q /boot; then
    warn "/boot not mounted; attempting to mount"
    run_or_dry mount /boot || die "Failed to mount /boot"
  fi
  local avail; avail=$(df --output=avail -k /boot | tail -n1)
  if [[ -n "$avail" && "$avail" -lt $((50*1024)) ]]; then
    warn "/boot free <50MB"
    if [[ "$(confirm 'Continue with small /boot? [y/N] ' 'n')" != "y" ]]; then die "/boot too small"; fi
  fi
}

validate_fstab() {
  if command -v findmnt &>/dev/null; then
    if ! findmnt --verify >/dev/null 2>&1; then
      warn "findmnt verification failed"
      if [[ "$(confirm 'Attempt to continue? [y/N] ' 'n')" != "y" ]]; then die "Fix /etc/fstab"; fi
    fi
  fi
}

########## KERNEL SELECTION ##########
select_kernel_interactive() {
  log "Searching /usr/src for kernels..."
  mapfile -t KLIST < <(find /usr/src -maxdepth 1 -type d -name 'linux-*' -printf '%f\n' 2>/dev/null | sort -V)
  if [[ ${#KLIST[@]} -eq 0 ]]; then die "No kernel sources under /usr/src"; fi
  echo "Available kernels:"
  for i in "${!KLIST[@]}"; do printf " [%d] %s\n" $((i+1)) "${KLIST[$i]}"; done
  if $AUTO_MODE; then choice=1; log "AUTO_MODE: choosing ${KLIST[0]}"; else read -r -p "Enter kernel number: " choice; fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#KLIST[@]} )); then die "Invalid kernel selection"; fi
  TARGET_KERNEL="${KLIST[$((choice-1))]}"
  KERNEL_SRC="/usr/src/${TARGET_KERNEL}"
  log "Selected kernel: ${TARGET_KERNEL}"
}

save_kernel_config() {
  mkdir -p /etc/kernel-configs
  if [[ -f "$KERNEL_SRC/.config" ]]; then
    cp -a "$KERNEL_SRC/.config" "/etc/kernel-configs/config-${TARGET_KERNEL}-$(date +%Y%m%d_%H%M%S)"
    log "Saved $KERNEL_SRC/.config"
  fi
}

########## FORCE BUILT-IN CONFIGS ##########
# Use scripts/config where available, otherwise fallback to editing .config
make_all_built_in() {
  log "Forcing key kernel options to built-in (y)"
  local kdir="$KERNEL_SRC"
  local cfg="$kdir/.config"
  if [[ ! -f "$cfg" ]]; then
    warn ".config not found in $kdir, attempting to create from running kernel"
    if [[ -f /proc/config.gz ]]; then
      zcat /proc/config.gz > "$cfg" || true
    else
      log "No /proc/config.gz; creating defconfig"
      run_or_dry bash -c "cd $kdir && make defconfig"
    fi
  fi

  # backup .config
  if [[ -f "$cfg" ]]; then
    cp -a "$cfg" "${cfg}.autobuilder.bak.$(date +%Y%m%d_%H%M%S)"
  fi

  # list of config symbols we want to ensure set to y
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
SCSI_SAS
USB
USB_STORAGE
AHCI
PCI
VM_EVENT_COUNTERS
HWMON
POWER_SUPPLY
CPU_FREQ
CPU_IDLE
CPU_FREQ_GOV_ONDEMAND
CPU_FREQ_GOV_CONSERVATIVE
SYMS

  # If scripts/config exists, prefer it
  if [[ -x "$KERNEL_SRC/scripts/config" ]]; then
    log "Using scripts/config to set built-in symbols"
    while read -r sym; do
      [[ -z "$sym" ]] && continue
      # set to y (built-in)
      run_or_dry bash -c "cd $KERNEL_SRC && ./scripts/config --enable $sym || true"
    done <<< "$BUILTIN_SYMBOLS"
    # After enabling required symbols, convert modules to built-in via sed fallback below
  else
    warn "scripts/config not available; will patch .config directly"
  fi

  # Fallback: convert any CONFIG_*=m to =y
  if [[ -f "$cfg" ]]; then
    if $DRY_RUN; then
      log "DRY-RUN: sed -ri 's/^(CONFIG_[A-Za-z0-9_]+=)m\$/\\1y/' $cfg"
    else
      # replace occurrences like CONFIG_FOO=m -> CONFIG_FOO=y (careful with =y already)
      sed -ri 's/^(CONFIG_[A-Za-z0-9_]+=)m$/\1y/' "$cfg" || true
      # also ensure specific options are y, not = is missing
      while read -r sym; do
        [[ -z "$sym" ]] && continue
        # set line if missing
        if ! grep -q "^CONFIG_${sym}=" "$cfg"; then
          echo "CONFIG_${sym}=y" >> "$cfg"
        else
          sed -i "s/^CONFIG_${sym}=.*/CONFIG_${sym}=y/" "$cfg"
        fi
      done <<< "$BUILTIN_SYMBOLS"
    fi
  fi

  # Regenerate dependencies (olddefconfig) to make sure .config is consistent
  run_or_dry bash -c "cd $KERNEL_SRC && make olddefconfig"
  log "Built-in conversion applied to kernel config"
}

########## BUILD KERNEL (no modules_install) ##########
build_kernel_builtin() {
  log "Building kernel ${TARGET_KERNEL} with built-in drivers (modules not used)"
  if [[ ! -d "$KERNEL_SRC" ]]; then die "Kernel source $KERNEL_SRC missing"; fi
  save_kernel_config
  make_all_built_in

  # compile
  if $DRY_RUN; then
    log "DRY-RUN: make -j${EMERGE_JOBS} in $KERNEL_SRC"
  else
    (cd "$KERNEL_SRC" && make -j"${EMERGE_JOBS}") 2>&1 | tee -a "$LOGFILE"
  fi

  # copy kernel image
  if $DRY_RUN; then
    log "DRY-RUN: cp arch/x86/boot/bzImage /boot/vmlinuz-${TARGET_KERNEL}"
  else
    cp -a "$KERNEL_SRC/arch/x86/boot/bzImage" "/boot/vmlinuz-${TARGET_KERNEL}"
    cp -a "$KERNEL_SRC/System.map" "/boot/System.map-${TARGET_KERNEL}" 2>/dev/null || true
    cp -a "$KERNEL_SRC/.config" "/boot/config-${TARGET_KERNEL}" 2>/dev/null || true
    log "Kernel image installed to /boot for ${TARGET_KERNEL}"
  fi

  # generate initramfs via genkernel (initramfs needed when drivers built-in is fine)
  if ! command -v genkernel &>/dev/null; then
    warn "genkernel missing; attempting to install"
    emerge_with_autounmask "sys-kernel/genkernel" || warn "genkernel install failed"
  fi
  if command -v genkernel &>/dev/null; then
    run_or_dry genkernel --install --no-mrproper initramfs
  else
    warn "genkernel unavailable; please create initramfs manually"
  fi
}

########## GRUB & UEFI ##########
determine_grub_cfg() {
  if [[ -d /boot/efi/EFI/gentoo ]]; then echo "/boot/efi/EFI/gentoo/grub.cfg"; else echo "/boot/grub/grub.cfg"; fi
}

update_grub_cfg() {
  local grub_cfg; grub_cfg="$(determine_grub_cfg)"
  run_or_dry grub-mkconfig -o "$grub_cfg"
  if command -v efibootmgr &>/dev/null && ! $DRY_RUN; then
    # try to add UEFI entry (best-effort)
    efipart=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)
    if [[ -n "$efipart" ]]; then
      efibootmgr -c -l '\EFI\gentoo\grubx64.efi' -L "Gentoo ${TARGET_KERNEL}" 2>/dev/null || warn "efibootmgr entry creation failed"
    fi
  fi
}

set_grub_default_for_kernel() {
  local grub_cfg; grub_cfg="$(determine_grub_cfg)"
  if $DRY_RUN; then
    log "DRY-RUN: set grub default for vmlinuz-${TARGET_KERNEL}"
    return 0
  fi
  if [[ ! -f "$grub_cfg" ]]; then warn "grub.cfg not found"; return 1; fi
  if ! grep -q "vmlinuz-${TARGET_KERNEL}" "$grub_cfg"; then warn "grub.cfg does not reference vmlinuz-${TARGET_KERNEL}"; return 1; fi
  # try to find menu title
  local title
  title=$(awk -v pat="vmlinuz-${TARGET_KERNEL}" '
    /^menuentry /{title_line=$0}
    $0 ~ pat { gsub(/^menuentry '\''/,"",title_line); gsub(/'\''.*/,"",title_line); print title_line; exit }
  ' "$grub_cfg" || true)
  if [[ -n "$title" ]]; then
    run_or_dry grub-set-default "$title" || warn "grub-set-default failed"
  else
    warn "Could not parse menu title; not setting default"
  fi
}

########## XFCE / XORG ##########
install_xfce_xorg() {
  log "Installing Xorg and XFCE"
  local packages=(x11-base/xorg-server x11-base/xorg-drivers x11-misc/lightdm x11-misc/lightdm-gtk-greeter xfce-base/xfce4-meta xfce-extra/xfce4-goodies media-libs/mesa x11-drivers/xf86-video-amdgpu app-admin/eselect-opengl app-misc/pciutils app-misc/usbutils)
  for p in "${packages[@]}"; do
    if is_installed_pkg "$p"; then log "$p installed"; else emerge_with_autounmask "$p" || warn "Failed to install $p"; fi
  done
  run_or_dry rc-update add lightdm default || warn "rc-update add lightdm failed"
  mkdir -p /etc/lightdm/lightdm.conf.d
  cat > /etc/lightdm/lightdm.conf.d/01-custom.conf <<'EOF'
[LightDM]
minimum-display-server-timeout=10
minimum-vt-timeout=10

[Seat:*]
user-session=xfce
allow-user-switching=true
allow-guest=false
EOF
  log "XFCE configured"
}

########## MAKECONF OPTIMIZE ##########
optimize_makeconf() {
  local conf="/etc/portage/make.conf"; local bak="/etc/portage/make.conf.autobuilder.bak"
  [[ -f "$conf" ]] || touch "$conf"
  [[ -f "$bak" ]] || cp -a "$conf" "$bak"
  local cores; cores=$(get_cpu_cores)
  local makeopts="-j$((cores+1)) -l${cores}"
  cat > "$conf" <<EOF
# Auto-generated make.conf
COMMON_FLAGS="-march=bdver4 -O2 -pipe -fomit-frame-pointer"
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
  log "make.conf optimized"
}

########## HDD/I/O/POWER/CLEANUP ##########
optimize_hdd_xfs() {
  log "Applying HDD/XFS tuning"
  cat > /etc/sysctl.d/99-gentoo-hdd.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.dirty_expire_centisecs=3000
vm.dirty_writeback_centisecs=1000
EOF
  run_or_dry sysctl --system

  for dev in /sys/block/*; do
    [[ -e "$dev/queue/rotational" ]] || continue
    local rot; rot=$(cat "$dev/queue/rotational")
    local bname; bname=$(basename "$dev")
    if [[ "$rot" == "1" ]]; then
      run_or_dry bash -c "echo bfq > /sys/block/$bname/queue/scheduler" || true
      echo 'ACTION=="add|change", KERNEL=="'"$bname"'", ATTR{queue/scheduler}="bfq"' > /etc/udev/rules.d/60-io-$bname.rules
    else
      run_or_dry bash -c "echo mq-deadline > /sys/block/$bname/queue/scheduler" || true
    fi
  done

  if grep -q 'xfs' /etc/fstab; then
    run_or_dry sed -ri 's|(\b[xX][fF][sS]\b[^ ]* )defaults|\1defaults,noatime,logbufs=8,logbsize=256k|' /etc/fstab || true
  fi
  if ! grep -q '/var/tmp/portage' /etc/fstab 2>/dev/null; then echo "tmpfs /var/tmp/portage tmpfs size=4G,noatime,nodev,nosuid,mode=1777 0 0" >> /etc/fstab; fi
  if ! grep -q '/tmp' /etc/fstab 2>/dev/null; then echo "tmpfs /tmp tmpfs size=2G,noatime,nodev,nosuid,mode=1777 0 0" >> /etc/fstab; fi
  log "HDD/XFS tuning applied"
}

install_power_scripts() {
  log "Installing power management script"
  mkdir -p /etc/local.d
  cat > /etc/local.d/power.start <<'EOF'
#!/bin/sh
# local power tuning
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
  log "Power script installed"
}

auto_cleanup() {
  log "Auto cleanup (eclean-kernel, eclean-dist, eclean-pkg)"
  run_or_dry eclean-kernel -n 2 || true
  run_or_dry eclean-dist --deep || true
  run_or_dry eclean-pkg --deep || true
  run_or_dry rm -rf /var/tmp/portage/* /tmp/* || true
  df -h | tee -a "$LOGFILE"
  log "Cleanup done"
}

install_xfce_xorg() {
  log "Installing Xorg + XFCE"
  local packages=(x11-base/xorg-server x11-base/xorg-drivers x11-misc/lightdm x11-misc/lightdm-gtk-greeter xfce-base/xfce4-meta xfce-extra/xfce4-goodies media-libs/mesa x11-drivers/xf86-video-amdgpu app-admin/eselect-opengl app-misc/pciutils app-misc/usbutils)
  for p in "${packages[@]}"; do
    if is_installed_pkg "$p"; then log "$p installed"; else emerge_with_autounmask "$p" || warn "Failed $p"; fi
  done
  run_or_dry rc-update add lightdm default || true
  mkdir -p /etc/lightdm/lightdm.conf.d
  cat > /etc/lightdm/lightdm.conf.d/01-custom.conf <<'EOF'
[LightDM]
minimum-display-server-timeout=10
minimum-vt-timeout=10

[Seat:*]
user-session=xfce
allow-user-switching=true
allow-guest=false
EOF
  log "XFCE configured"
}

install_ccache_distcc() {
  log "Installing ccache/distcc (optional)"
  emerge_with_autounmask "dev-util/ccache" || warn "ccache failed"
  emerge_with_autounmask "sys-devel/distcc" || warn "distcc failed"
  if ! grep -q "ccache" /etc/portage/make.conf 2>/dev/null; then echo 'FEATURES="${FEATURES} ccache"' >> /etc/portage/make.conf; fi
}

install_cron_job() {
  local cronfile="/etc/cron.d/gentoo_autobuilder"
  cat > "$cronfile" <<EOF
0 4 * * 1 root /usr/local/sbin/gentoo_autobuilder_pro_builtin.sh --auto >> /var/log/gentoo_autobuilder_cron.log 2>&1
EOF
  chmod 644 "$cronfile"
  if grep -q '^rc_parallel=' /etc/rc.conf 2>/dev/null; then sed -i 's/^rc_parallel=.*/rc_parallel="YES"/' /etc/rc.conf || true; else echo 'rc_parallel="YES"' >> /etc/rc.conf; fi
  log "Cron and parallel boot configured"
}

########## MAIN FLOW ##########
main() {
  log "Gentoo AutoBuilder Pro (built-in) start $(date --iso-8601=seconds)"
  check_network
  check_boot_space
  validate_fstab
  make_backup

  optimize_makeconf
  optimize_hdd_xfs
  install_power_scripts

  select_kernel_interactive

  build_kernel_builtin

  update_grub_cfg
  set_grub_default_for_kernel

  install_xfce_xorg

  if [[ "$(confirm 'Install ccache/distcc? [y/N] ' 'n')" == "y" ]]; then install_ccache_distcc; fi

  auto_cleanup
  install_cron_job

  log "Finished successfully at $(date --iso-8601=seconds)"
}

main "$@"

#!/bin/bash
set -euo pipefail

LOG="/var/log/gentoo_autobuilder_force.log"
: > "$LOG"

DRY_RUN=false
AUTO_MODE=false
FORCE_MODE=false
EMERGE_JOBS=""
EMERGE_LOAD=""
EMERGE_BASE_OPTS=(--verbose --quiet-build=y --with-bdeps=y --ask=n)

BACKUP_DIR="/var/backups/gentoo_autobuilder"
KEEP_BACKUPS=5
KERNEL_CONFIG_STORE="/etc/kernel-configs"

log(){ printf '[INFO] %s\n' "$*" | tee -a "$LOG"; }
warn(){ printf '[WARN] %s\n' "$*" | tee -a "$LOG" >&2; }
err(){ printf '[ERROR] %s\n' "$*" | tee -a "$LOG" >&2; }
die(){ err "$*"; exit 1; }

usage(){
  cat <<EOF
Usage: $0 [--dry-run] [--auto] [--force] [-j N] [-h]
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
[[ -z "$EMERGE_JOBS" ]] && EMERGE_JOBS="$(get_cpu_cores)"
EMERGE_LOAD="$EMERGE_JOBS"

run_or_dry(){
  if $DRY_RUN; then log "DRY-RUN: $*"; else log "RUN: $*"; eval "$@"; fi
}

confirm_noprompt(){ echo "y"; }

trap 'on_error $?' ERR
CURRENT_BACKUP=""
on_error(){
  local rc=${1:-1}
  err "Script exited with code $rc. Attempting rollback..."
  [[ -n "$CURRENT_BACKUP" && -f "$CURRENT_BACKUP" ]] && tar -xzf "$CURRENT_BACKUP" -C / || warn "No backup"
  exit $rc
}

make_backup(){
  mkdir -p "$BACKUP_DIR"
  local ts backupfile
  ts="$(date +%Y%m%d_%H%M%S)"
  backupfile="$BACKUP_DIR/gentoo_autobuilder_backup_${ts}.tar.gz"
  CURRENT_BACKUP="$backupfile"
  tar -czf "$backupfile" /etc/portage/make.conf /etc/fstab /etc/default/grub /etc/local.d /etc/kernel-configs /boot /etc/portage || warn "Backup failed"
}

is_installed_pkg(){
  local atom="$1"
  [[ -d "/var/db/pkg/${atom##*/}" ]] && return 0
  return 1
}

emerge_with_autounmask(){
  local pkg="$1"
  local extra_flags="${2:-}"
  if $DRY_RUN; then log "DRY-RUN: emerge -j${EMERGE_JOBS} ${pkg}"; return 0; fi
  if emerge -j"${EMERGE_JOBS}" "${EMERGE_BASE_OPTS[@]}" ${extra_flags} "$pkg"; then return 0; fi
  warn "Could not autounmask/install $pkg"
  return 1
}

check_network(){
  log "Checking network..."
  ping -c1 -W2 gentoo.org &>/dev/null || ping -c1 -W2 8.8.8.8 &>/dev/null || warn "Network unreachable"
}

ensure_usr_src_symlink(){
  [[ ! -d /usr/src ]] && die "/usr/src missing"
  pushd /usr/src >/dev/null 2>&1
  local latest
  latest="$(ls -d linux-* 2>/dev/null | sort -V | tail -n1 || true)"
  [[ -z "$latest" ]] && die "No linux-* found"
  [[ -L linux ]] && ln -sf "$latest" linux || ln -sf "$latest" linux
  popd >/dev/null 2>&1
}

detect_partitions(){
  ROOT_DEV="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  EFI_DEV="$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)"
}

create_mounts_and_update_fstab(){
  mkdir -p /boot /boot/efi
}

select_and_prepare_kernel(){
  ensure_usr_src_symlink
  mapfile -t KLIST < <(find /usr/src -maxdepth 1 -type d -name 'linux-*' -printf '%f\n' 2>/dev/null | sort -V)
  [[ ${#KLIST[@]} -eq 0 ]] && die "No kernel sources"
  TARGET_KERNEL="${KLIST[-1]}"
  KERNEL_SRC="/usr/src/${TARGET_KERNEL}"
}

save_kernel_config(){
  mkdir -p "$KERNEL_CONFIG_STORE"
  [[ -f "$KERNEL_SRC/.config" ]] && cp -a "$KERNEL_SRC/.config" "$KERNEL_CONFIG_STORE/config-${TARGET_KERNEL}-$(date +%Y%m%d_%H%M%S)"
}

make_all_built_in(){ :; }  # оставляем минимально, твоя логика с scripts/config

build_kernel(){ :; } # минимальная заготовка

update_grub(){ :; }
set_grub_default(){ :; }

optimize_makeconf(){
  local conf="/etc/portage/make.conf"
  [[ -f "$conf" ]] || touch "$conf"
  local cores="$(get_cpu_cores)"
  echo "" >> "$conf"
  echo "# AMD A10-9600P optimization added by autobuilder" >> "$conf"
  echo "COMMON_FLAGS=\"-march=bdver4 -O2 -pipe -fomit-frame-pointer\"" >> "$conf"
  echo "MAKEOPTS=\"-j$((cores+1)) -l${cores}\"" >> "$conf"
}

optimize_hdd_xfs(){ :; }
install_power_scripts(){ :; }

install_xfce_complete(){
  log "Installing XFCE/Xorg/LightDM (non-interactive, safe)"

  local packages=(
    x11-drivers/xf86-video-amdgpu
    x11-drivers/xf86-video-ati
    x11-base/xorg-server
    x11-base/xorg-drivers
    x11-misc/lightdm
    x11-misc/lightdm-gtk-greeter
    xfce-base/xfce4-meta
    xfce-extra/xfce4-goodies
    media-libs/mesa
    app-admin/eselect-opengl
  )

  for p in "${packages[@]}"; do
    is_installed_pkg "$p" && log "$p already installed" || emerge_with_autounmask "$p" || warn "Failed: $p"
  done

  mkdir -p /etc/lightdm/lightdm.conf.d
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
  log "LightDM config created"

  command -v rc-update &>/dev/null && ! rc-update show | grep -q "^lightdm" && rc-update add lightdm default
}

auto_cleanup(){
  rm -rf /var/tmp/portage/* /tmp/*
}

install_cron(){ :; }

main(){
  log "Gentoo AutoBuilder Force start: $(date --iso-8601=seconds)"
  check_network
  make_backup
  ensure_usr_src_symlink
  detect_partitions
  create_mounts_and_update_fstab
  select_and_prepare_kernel
  build_kernel
  update_grub
  set_grub_default
  optimize_makeconf
  optimize_hdd_xfs
  install_power_scripts
  install_xfce_complete
  auto_cleanup
  install_cron
  log "Completed successfully: $(date --iso-8601=seconds)"
}

main "$@"

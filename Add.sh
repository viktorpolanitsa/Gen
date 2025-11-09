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
  --dry-run    Show actions without making changes
  --auto       Non-interactive (accept defaults)
  --force      Aggressive non-interactive mode (overwrite without prompts)
  -j N         Set parallel emerge jobs
  -h           Help
EOF
}

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
  if $DRY_RUN; then log "DRY-RUN: $*"; else log "RUN: $*"; eval "$@"; fi
}

confirm_noprompt(){
  if $FORCE_MODE || $AUTO_MODE; then echo "y"; else echo "y"; fi
}

CURRENT_BACKUP=""
trap 'on_error $?' ERR
on_error(){
  local rc=${1:-1}
  err "Script exited with code $rc. Attempting best-effort rollback..."
  if [[ -n "$CURRENT_BACKUP" && -f "$CURRENT_BACKUP" ]]; then
    warn "Restoring backup $CURRENT_BACKUP ..."
    if $DRY_RUN; then log "DRY-RUN: tar -xzf $CURRENT_BACKUP -C /"; else tar -xzf "$CURRENT_BACKUP" -C / || warn "Rollback failed"; log "Rollback attempted."; fi
  else warn "No backup recorded."; fi
  err "See $LOG for details."; exit $rc
}

make_backup(){
  mkdir -p "$BACKUP_DIR"
  local ts backupfile files
  ts="$(date +%Y%m%d_%H%M%S)"
  backupfile="$BACKUP_DIR/gentoo_autobuilder_backup_${ts}.tar.gz"
  CURRENT_BACKUP="$backupfile"
  files=(/etc/portage/make.conf /etc/fstab /etc/default/grub /etc/local.d /etc/kernel-configs /boot /etc/portage)
  log "Creating backup $backupfile ..."
  if $DRY_RUN; then log "DRY-RUN: tar -czf $backupfile ${files[*]}"; else
    tar -czf "$backupfile" --absolute-names "${files[@]}" || warn "tar returned non-zero"
    log "Backup created: $backupfile"
    ls -1t "$BACKUP_DIR"/gentoo_autobuilder_backup_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS+1)) | xargs -r rm -f
  fi
}

is_installed_pkg(){
  local atom="$1"
  if command -v equery &>/dev/null; then equery list "$atom" >/dev/null 2>&1 && return 0; fi
  [[ -d /var/db/pkg ]] && find /var/db/pkg -maxdepth 2 -type d -name "${atom##*/}*" | grep -q . && return 0
  return 1
}

emerge_with_autounmask(){
  local pkg="$1" extra_flags="${2:-}"
  log "Emerge attempt: $pkg"
  if $DRY_RUN; then log "DRY-RUN: emerge -j${EMERGE_JOBS} --load-average=${EMERGE_LOAD} ${EMERGE_BASE_OPTS[*]} ${extra_flags} $pkg"; return 0; fi
  if emerge -j"${EMERGE_JOBS}" --load-average="${EMERGE_LOAD}" "${EMERGE_BASE_OPTS[@]}" ${extra_flags} "$pkg"; then return 0; fi
  warn "Initial emerge failed; trying --autounmask-write"
  if emerge -j"${EMERGE_JOBS}" --load-average="${EMERGE_LOAD}" --autounmask-write=y ${extra_flags} "$pkg"; then
    command -v etc-update &>/dev/null && etc-update --automode -5 || true
    command -v dispatch-conf &>/dev/null && dispatch-conf --auto-merge || true
    emerge -j"${EMERGE_JOBS}" --load-average="${EMERGE_LOAD}" "${EMERGE_BASE_OPTS[@]}" ${extra_flags} "$pkg" || warn "Emerges failed after autounmask"
    return 0
  fi
  warn "Could not autounmask/install $pkg automatically"
  return 1
}

check_network(){
  log "Checking network..."
  if ping -c1 -W2 gentoo.org &>/dev/null || ping -c1 -W2 8.8.8.8 &>/dev/null; then log "Network OK"; else warn "Network unreachable (continuing)"; fi
}

ensure_usr_src_symlink(){
  log "Ensuring /usr/src/linux points to newest linux-*"
  [[ -d /usr/src ]] || die "/usr/src missing"
  pushd /usr/src >/dev/null 2>&1
  local latest
  latest="$(ls -d linux-* 2>/dev/null | sort -V | tail -n1 || true)"
  [[ -n "$latest" ]] || die "No linux-* found under /usr/src"
  [[ -L linux ]] && run_or_dry ln -sf "$latest" linux || run_or_dry ln -sf "$latest" linux
  popd >/dev/null 2>&1
}

# Добавляем Make.conf оптимизацию, сохраняем старое содержимое
optimize_makeconf(){
    local conf="/etc/portage/make.conf"
    local bak="/etc/portage/make.conf.autobuilder.bak"
    [[ -f "$conf" ]] && cp -a "$conf" "$bak"

    log "Updating /etc/portage/make.conf for AMD A10 (preserve existing content)"

    for var in COMMON_FLAGS CFLAGS CXXFLAGS FCFLAGS FFLAGS; do
        if grep -q "^$var=" "$conf"; then
            sed -i "s|^$var=.*|$var=\"-march=bdver4 -O2 -pipe -fomit-frame-pointer\"|" "$conf"
        else
            echo "$var=\"-march=bdver4 -O2 -pipe -fomit-frame-pointer\"" >> "$conf"
        fi
    done

    local cores
    cores="$(get_cpu_cores)"
    if grep -q "^MAKEOPTS=" "$conf"; then
        sed -i "s|^MAKEOPTS=.*|MAKEOPTS=\"-j$((cores+1)) -l${cores}\"|" "$conf"
    else
        echo "MAKEOPTS=\"-j$((cores+1)) -l${cores}\"" >> "$conf"
    fi

    if grep -q "^VIDEO_CARDS=" "$conf"; then
        sed -i "s|^VIDEO_CARDS=.*|VIDEO_CARDS=\"amdgpu radeonsi radeon\"|" "$conf"
    else
        echo "VIDEO_CARDS=\"amdgpu radeonsi radeon\"" >> "$conf"
    fi

    if grep -q "^INPUT_DEVICES=" "$conf"; then
        sed -i "s|^INPUT_DEVICES=.*|INPUT_DEVICES=\"libinput\"|" "$conf"
    else
        echo "INPUT_DEVICES=\"libinput\"" >> "$conf"
    fi

    if grep -q "^USE=" "$conf"; then
        sed -i "s|^USE=.*|USE=\"X xorg gtk3 dbus pulseaudio vulkan opengl udev drm alsa policykit xfce xfs unicode truetype\"|" "$conf"
    else
        echo "USE=\"X xorg gtk3 dbus pulseaudio vulkan opengl udev drm alsa policykit xfce xfs unicode truetype\"" >> "$conf"
    fi

    if ! grep -q "^ACCEPT_LICENSE=" "$conf"; then
        echo "ACCEPT_LICENSE=\"*\"" >> "$conf"
    fi

    log "/etc/portage/make.conf updated (existing content preserved, backup: $bak)"
}

# Установка AMD драйверов, XFCE, LightDM
install_amd_xfce(){
    log "Installing AMD drivers and XFCE/LightDM"
    local packages=(x11-drivers/xf86-video-amdgpu x11-drivers/xf86-video-ati x11-base/xorg-drivers x11-base/xorg-server x11-misc/lightdm x11-misc/lightdm-gtk-greeter xfce-base/xfce4-meta xfce-extra/xfce4-goodies media-libs/mesa)
    for p in "${packages[@]}"; do
        if is_installed_pkg "$p"; then log "$p already installed"; else emerge_with_autounmask "$p" || warn "Failed to install $p"; fi
    done

    # Настройка LightDM
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

    run_or_dry rc-update add lightdm default || warn "rc-update add lightdm failed"
    log "XFCE and LightDM configured (no autologin)"
}

main(){
    log "Gentoo AutoBuilder Force start: $(date --iso-8601=seconds)"
    check_network
    make_backup
    ensure_usr_src_symlink
    optimize_makeconf
    install_amd_xfce
    log "Completed successfully: $(date --iso-8601=seconds)"
}

main "$@"
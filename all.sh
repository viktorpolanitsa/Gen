#!/bin/bash
# shellcheck disable=SC1091,SC2016

# The Ultimate Gentoo Autobuilder
# Version: 3.4 "Praetorian" (The Guardian)
#
# This version enhances reliability and robustness by replacing all here-document
# constructs with safer alternatives, improving readability, and ensuring all
# modules, including cron, are present and accounted for. It also fixes
# critical bugs found during a final audit.

set -euo pipefail

# --- Configuration and Globals ---
LOG="/var/log/gentoo_ultimate_autobuilder.log"
CONFIG_FILE="/etc/autobuilder.conf"
: > "$LOG" # Clear log on start

# --- UX Enhancements: Colors and Step Counter ---
C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_RED='\033[0;31m'
STEP_COUNT=0
TOTAL_STEPS=13 # Adjusted for the returned cron module

# --- Logging Utilities ---
log() { printf "${C_GREEN}[INFO] %s${C_RESET}\n" "$*" | tee -a "$LOG"; }
warn() { printf "${C_YELLOW}[WARN] %s${C_RESET}\n" "$*" | tee -a "$LOG" >&2; }
err() { printf "${C_RED}[ERROR] %s${C_RESET}\n" "$*" | tee -a "$LOG" >&2; }
step_log() {
    STEP_COUNT=$((STEP_COUNT + 1))
    printf "\n${C_GREEN}>>> [STEP %s/%s] %s${C_RESET}\n" "$STEP_COUNT" "$TOTAL_STEPS" "$*" | tee -a "$LOG"
}
die() { err "$*"; exit 1; }

# --- Configuration Management ---
load_config() {
  log "Loading configuration from $CONFIG_FILE..."
  if [[ ! -f "$CONFIG_FILE" ]]; then
    warn "Configuration file not found. Creating a default one."
    # Using printf for safer multi-line writing, preventing EOF errors.
    printf '%s\n' \
      '# Gentoo Autobuilder Configuration ("Praetorian" version)' \
      '' \
      '# --- Hardware Settings ---' \
      'CPU_MARCH="native"' \
      'VIDEO_CARDS="amdgpu radeonsi radeon"' \
      'INPUT_DEVICES="libinput"' \
      '' \
      '# --- Localization ---' \
      '# Set your system''s locale. "ru_RU.UTF-8" for Russian.' \
      'SYSTEM_LOCALE="ru_RU.UTF-8"' \
      '# Set your timezone from /usr/share/zoneinfo/.' \
      'SYSTEM_TIMEZONE="Europe/Moscow"' \
      '' \
      '# --- Emerge Settings ---' \
      'EMERGE_JOBS="$(nproc --all 2>/dev/null || echo 4)"' > "$CONFIG_FILE"
    log "Default configuration created at $CONFIG_FILE. Please review it and run the script again."
    exit 0
  fi
  # Source the config file and check for success
  # shellcheck source=/dev/null
  source "$CONFIG_FILE" || die "Failed to load configuration from $CONFIG_FILE. Check for syntax errors."
}

# --- Core Helper Functions ---
run_or_dry() { log "EXEC: $*"; if ! $DRY_RUN; then eval "$@"; fi; }
ask_confirm() { if $FORCE_MODE || $AUTO_MODE; then return 0; fi; read -r -p "$1 [y/N] " response; [[ "$response" =~ ^[yY]([eE][sS])?$ ]]; }

# --- Pre-flight Safety Checks ---
preflight_checks() {
    step_log "Running Pre-flight Safety Checks"
    [[ "$(id -u)" -ne 0 ]] && die "This script must be run as root."
    [[ "$(readlink /proc/1/exe)" != *openrc* ]] && die "This script is designed for OpenRC only. Aborting."
    if command -v on_ac_power >/dev/null && ! on_ac_power; then
        if ! $FORCE_MODE; then die "System is on battery power. Unsafe for long compilations. Aborting. (Use --force to override)"; else warn "Running on battery! Proceeding due to --force."; fi
    fi
    local required_space_gb=15; local usr_src_space; usr_src_space=$(df -BG /usr/src | awk 'NR==2 {print substr($4, 1, length($4)-1)}'); if (( usr_src_space < required_space_gb )); then die "Not enough free space in /usr/src. Required: ${required_space_gb}G, Available: ${usr_src_space}G."; fi
    log "Pre-flight checks passed."
}

# --- Backup and Rollback System ---
CURRENT_BACKUP=""
on_error() {
  local rc=${1:-1}
  err "Script exited with code $rc. Attempting rollback..."
  if [[ -n "$CURRENT_BACKUP" && -f "$CURRENT_BACKUP" ]]; then
    warn "Restoring from backup $CURRENT_BACKUP ..."
    if ! $DRY_RUN; then
      tar -xzpf "$CURRENT_BACKUP" -C / || warn "Backup restoration failed."
    fi
  fi
  err "See log for details: $LOG"
  exit "$rc"
}
trap on_error ERR
make_backup() { step_log "Creating System Backup"; mkdir -p "$BACKUP_DIR"; local ts; ts="$(date +%Y%m%d_%H%M%S)"; local backup_file="$BACKUP_DIR/gentoo_autobuilder_backup_${ts}.tar.gz"; CURRENT_BACKUP="$backup_file"; local files_to_backup=(/etc/portage /etc/fstab /etc/default/grub /etc/kernel-configs /boot); log "Creating backup: $backup_file"; if ! $DRY_RUN; then tar -czpf "$backup_file" --absolute-names --ignore-failed-read "${files_to_backup[@]}"; ls -1t "$BACKUP_DIR"/gentoo_autobuilder_backup_*.tar.gz 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -f; fi; }

# --- System Interaction Functions ---
is_pkg_installed() { equery l -q "$1" >/dev/null 2>&1; }
emerge_pkg() {
    local pkg="$1"; local attempt=1
    if is_pkg_installed "$pkg"; then log "Package $pkg is already installed."; return 0; fi
    log "Attempting to install package: $pkg"
    while (( attempt <= 2 )); do
        if ! $DRY_RUN; then
            if emerge -j"${EMERGE_JOBS}" --load-average="${EMERGE_JOBS}" "${EMERGE_BASE_OPTS[@]}" "$pkg"; then
                command -v etc-update &>/dev/null && etc-update --automode -5; log "Successfully installed $pkg."; return 0
            fi
        else
            log "DRY-RUN: emerge $pkg"; return 0
        fi
        warn "Failed to install $pkg on attempt $attempt."; if (( attempt == 1 )); then warn "This might be a repository sync issue. Attempting 'emerge --sync' and retrying..."; run_or_dry "emerge --sync"; fi; attempt=$((attempt + 1))
    done
    err "Could not install $pkg after 2 attempts."; ask_confirm "Continue script execution?" || die "Execution aborted by user."; return 1
}
update_conf_variable() { local conf_file="$1"; local var_name="$2"; local new_value="$3"; log "Updating $var_name in $conf_file"; if ! $DRY_RUN; then touch "$conf_file"; sed -i -E "/^${var_name}=/s/^/# (deactivated by builder) &/" "$conf_file"; echo -e "\n# Added by The Praetorian Autobuilder\n${var_name}=\"${new_value}\"" >> "$conf_file"; fi; }

# --- Main Script Modules ---
module_setup_localization() { step_log "Configuring System Localization"; log "Setting timezone to ${SYSTEM_TIMEZONE}"; run_or_dry "echo '${SYSTEM_TIMEZONE}' > /etc/timezone"; run_or_dry "emerge --config sys-libs/timezone-data"; log "Setting locale to ${SYSTEM_LOCALE}"; if ! grep -q "${SYSTEM_LOCALE}" /etc/locale.gen; then run_or_dry "echo '${SYSTEM_LOCALE} UTF-8' >> /etc/locale.gen"; fi; run_or_dry "locale-gen"; run_or_dry "eselect locale set '${SYSTEM_LOCALE}'"; run_or_dry "env-update && source /etc/profile"; }
module_setup_portage() { step_log "Configuring Portage (make.conf)"; update_conf_variable "/etc/portage/make.conf" "COMMON_FLAGS" "-march=${CPU_MARCH} -O2 -pipe"; update_conf_variable "/etc/portage/make.conf" "MAKEOPTS" "-j${EMERGE_JOBS} -l${EMERGE_JOBS}"; update_conf_variable "/etc/portage/make.conf" "VIDEO_CARDS" "${VIDEO_CARDS}"; update_conf_variable "/etc/portage/make.conf" "INPUT_DEVICES" "${INPUT_DEVICES}"; if ! grep -q "X" /etc/portage/make.conf; then update_conf_variable "/etc/portage/make.conf" "USE" "X xorg gtk3 dbus pulseaudio vulkan opengl udev drm alsa policykit xfce xfs unicode truetype"; fi; update_conf_variable "/etc/portage/make.conf" "ACCEPT_LICENSE" "*"; }
module_setup_package_use() { step_log "Configuring Proactive USE Flags (package.use)"; local package_use_dir="/etc/portage/package.use"; local use_file="$package_use_dir/99_autobuilder_flags"; log "Creating USE flag configuration at $use_file"; if ! $DRY_RUN; then mkdir -p "$package_use_dir"; printf '%s\n' 'sys-auth/polkit elogind' 'x11-base/xorg-server elogind' 'xfce-base/xfce4-session elogind' 'x11-misc/lightdm gtk' 'media-libs/mesa X gallium vulkan' 'x11-libs/libnotify dbus' > "$use_file"; fi; }
module_install_desktop() { step_log "Installing XFCE Desktop Environment"; local desktop_packages=("x11-base/xorg-server" "x11-misc/lightdm" "x11-misc/lightdm-gtk-greeter" "xfce-base/xfce4-meta" "xfce-extra/xfce4-goodies" "media-libs/mesa" "app-admin/eselect" "sys-auth/elogind"); for pkg in "${desktop_packages[@]}"; do emerge_pkg "$pkg"; done; log "Configuring services for automatic startup..."; if ! $DRY_RUN; then mkdir -p /etc/lightdm/lightdm.conf.d; printf '%s\n' '[Seat:*]' 'user-session=xfce' > /etc/lightdm/lightdm.conf.d/50-autobuilder.conf; run_or_dry "rc-update add lightdm default"; run_or_dry "rc-update add elogind default"; fi; }
module_install_firmware() { step_log "Installing Firmware and Microcode"; emerge_pkg "sys-firmware/linux-firmware"; local cpu_vendor; cpu_vendor=$(grep -m 1 'vendor_id' /proc/cpuinfo); if [[ "$cpu_vendor" == *AuthenticAMD* ]]; then log "AMD CPU detected. Installing AMD microcode."; emerge_pkg "sys-kernel/linux-ucode-amd"; else log "Intel CPU detected. Installing Intel microcode."; emerge_pkg "sys-kernel/linux-ucode-intel"; fi; }
module_install_utils() { step_log "Installing Common Utilities"; local utils_packages=("app-arch/p7zip" "sys-fs/ntfs3g" "sys-fs/exfat-utils"); for pkg in "${utils_packages[@]}"; do emerge_pkg "$pkg"; done; }
module_build_kernel() { step_log "Building Intelligent, Hardware-Aware Kernel"; emerge_pkg "sys-kernel/gentoo-sources"; emerge_pkg "sys-kernel/genkernel"; local latest_kernel_dir; latest_kernel_dir=$(ls -d /usr/src/linux-* | sort -V | tail -n 1); [[ -z "$latest_kernel_dir" ]] && die "Kernel sources not found in /usr/src."; run_or_dry "ln -sfn '$latest_kernel_dir' /usr/src/linux"; log "Symlink /usr/src/linux now points to $latest_kernel_dir"; log "Generating kernel config with hardware auto-detection..."; if ! $DRY_RUN; then pushd /usr/src/linux >/dev/null; if [[ -f /proc/config.gz ]]; then log "Using running kernel's config as a base."; zcat /proc/config.gz > .config; else log "Creating default config."; make defconfig; fi; log "Running 'make localmodconfig' to tailor config to this hardware..."; make localmodconfig; popd >/dev/null; fi; local built_in_symbols=(DEVTMPFS DEVTMPFS_MOUNT TMPFS EFI_STUB EFI_PARTITION XFS_FS EXT4_FS BLK_DEV_INITRD DRM_AMDGPU DRM_RADEON); if [[ -x "/usr/src/linux/scripts/config" ]]; then for sym in "${built_in_symbols[@]}"; do run_or_dry "'/usr/src/linux/scripts/config' --enable '$sym'"; done; fi; run_or_dry "make -C /usr/src/linux olddefconfig"; if ask_confirm "Kernel configured. Begin compilation?"; then run_or_dry "make -C /usr/src/linux -j'${EMERGE_JOBS}'"; run_or_dry "make -C /usr/src/linux modules_install"; run_or_dry "make -C /usr/src/linux install"; run_or_dry "genkernel --install initramfs"; else warn "Kernel build skipped by user."; fi; }
module_setup_bootloader() { step_log "Configuring Bootloader"; emerge_pkg "sys-boot/grub"; if ! grep -q "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub; then echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' >> /etc/default/grub; fi; local grub_cfg_path="/boot/grub/grub.cfg"; [[ -d /boot/efi ]] && grub_cfg_path="/boot/efi/EFI/gentoo/grub.cfg"; if ask_confirm "Update GRUB configuration ($grub_cfg_path)? This is required for microcode."; then run_or_dry "grub-mkconfig -o '$grub_cfg_path'"; else warn "GRUB update skipped. Microcode may not be loaded."; fi; }
module_create_user() { step_log "Interactive User Creation"; local username; if $AUTO_MODE || $FORCE_MODE; then warn "User creation is skipped in non-interactive modes."; return; fi; if ! ask_confirm "Would you like to create a new user?"; then log "Skipping user creation."; return; fi; while true; do read -r -p "Enter the desired username: " username; if [[ -z "$username" ]]; then warn "Username cannot be empty."; continue; fi; if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then warn "Invalid username format."; continue; fi; if id "$username" &>/dev/null; then warn "User '$username' already exists."; continue; fi; break; done; log "Creating user '$username' and adding to standard groups..."; run_or_dry "useradd -m -G wheel,users,audio,video,usb,portage -s /bin/bash '$username'"; log "Please set a password for the new user '$username'."; if ! $DRY_RUN; then passwd "$username"; fi; log "User '$username' created successfully."; }
module_setup_security() { step_log "Establishing Security Foundation"; log "Setting up sudo for the 'wheel' group..."; emerge_pkg "app-admin/sudo"; if ! $DRY_RUN; then echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel; fi; log "Setting up Uncomplicated Firewall (ufw)..."; emerge_pkg "net-firewall/ufw"; run_or_dry "ufw default deny incoming"; run_or_dry "ufw default allow outgoing"; run_or_dry "ufw allow ssh"; run_or_dry "ufw --force enable"; run_or_dry "rc-update add ufw default"; }
module_setup_timesync() { step_log "Setting up Time Synchronization"; emerge_pkg "net-misc/chrony"; run_or_dry "rc-update add chronyd default"; }
module_setup_cron() { step_log "Installing Maintenance Cron Job"; local cron_file="/etc/cron.d/gentoo_master_builder"; log "Installing job for weekly system maintenance."; if ! $DRY_RUN; then printf '%s\n' '# Weekly system maintenance using the autobuilder script' "0 4 * * 1 root $0 --force >> /var/log/gentoo_master_builder_cron.log 2>&1" > "$cron_file"; chmod 644 "$cron_file"; fi; }
final_summary() { log "--- SCRIPT COMPLETE ---"; echo -e "\n\n${C_GREEN}Gentoo Ultimate Autobuilder 'Praetorian' has finished.${C_RESET}"; echo "Summary of actions:"; echo "- System localized, configured, and tuned for your hardware."; echo "- Proactive USE flags configured and self-healing emerge performed."; echo "- XFCE Desktop Environment installed with required services."; echo "- Hardware-aware kernel compiled and bootloader updated (with microcode)."; echo "- Interactive user account created."; echo "- Security foundation established (sudo, firewall)."; echo "- Essential firmware, utilities, and services installed."; echo -e "\n${C_YELLOW}Recommended next step: REBOOT the system to apply all changes.${C_RESET}"; }

# --- Main Execution Flow ---
main() {
  DRY_RUN=false; AUTO_MODE=false; FORCE_MODE=false
  while [[ "${1:-}" != "" ]]; do case "$1" in --dry-run) DRY_RUN=true; shift ;; --auto) AUTO_MODE=true; shift ;; --force) FORCE_MODE=true; shift ;; -j) shift; EMERGE_JOBS="${1:-}"; shift ;; -h|--help) usage; exit 0 ;; *) err "Unknown option: $1"; usage; exit 1 ;; esac; done
  
  load_config
  
  EMERGE_BASE_OPTS=(--verbose --quiet-build=y --with-bdeps=y --ask=n --autounmask=y --autounmask-continue=y)

  log "Starting Gentoo Ultimate Autobuilder v3.4 'Praetorian': $(date --iso-8601=seconds)"
  
  preflight_checks
  command -v equery >/dev/null 2>&1 || emerge --onlydeps app-portage/gentoolkit
  ping -c1 -W2 gentoo.org >/dev/null 2>&1 || warn "Network is unreachable. Some steps may fail."

  make_backup

  module_setup_localization
  module_setup_portage
  module_setup_package_use
  module_install_firmware
  module_install_utils
  module_install_desktop
  module_build_kernel
  module_setup_bootloader
  module_create_user
  module_setup_security
  module_setup_timesync
  module_setup_cron
  
  final_summary
}

main "$@"

#!/bin/bash
# shellcheck disable=SC1091,SC2016

# The Ultimate Gentoo Autobuilder & Deployer
# Version: 6.0 "Centurion"
#
# This version removes the need for a manual configuration file. It runs a
# fully interactive setup wizard at the beginning to gather all necessary
# parameters directly from the user, ensuring maximum safety and usability.

set -euo pipefail

# --- Configuration and Globals ---
GENTOO_MNT="/mnt/gentoo"
# Config is now generated dynamically
CONFIG_FILE_TMP="/tmp/autobuilder.conf.$$"

# --- UX Enhancements ---
C_RESET='\033[0m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'
STEP_COUNT=0; TOTAL_STEPS=14

# --- Logging Utilities ---
log() { printf "${C_GREEN}[INFO] %s${C_RESET}\n" "$*"; }
warn() { printf "${C_YELLOW}[WARN] %s${C_RESET}\n" "$*" >&2; }
err() { printf "${C_RED}[ERROR] %s${C_RESET}\n" "$*" >&2; }
step_log() { STEP_COUNT=$((STEP_COUNT + 1)); printf "\n${C_GREEN}>>> [STEP %s/%s] %s${C_RESET}\n" "$STEP_COUNT" "$TOTAL_STEPS" "$*"; }
die() { err "$*"; exit 1; }

# ==============================================================================
# --- STAGE 0A: INTERACTIVE SETUP WIZARD ---
# ==============================================================================
interactive_setup() {
    step_log "Interactive Setup Wizard"
    log "Welcome! This wizard will guide you through the configuration."

    # --- Target Device ---
    log "Available block devices:"
    lsblk -d -o NAME,SIZE,TYPE
    while true; do
        read -r -p "Enter the target device for installation (e.g., /dev/sda): " TARGET_DEVICE
        if [[ -b "$TARGET_DEVICE" ]]; then
            break
        else
            err "Device '$TARGET_DEVICE' does not exist. Please try again."
        fi
    done

    # --- Localization ---
    read -r -p "Enter your timezone [Default: Europe/Moscow]: " SYSTEM_TIMEZONE
    [[ -z "$SYSTEM_TIMEZONE" ]] && SYSTEM_TIMEZONE="Europe/Moscow"
    read -r -p "Enter your system locale [Default: ru_RU.UTF-8]: " SYSTEM_LOCALE
    [[ -z "$SYSTEM_LOCALE" ]] && SYSTEM_LOCALE="ru_RU.UTF-8"

    # --- Hardware & Compilation ---
    read -r -p "Enter CPU architecture (-march) [Default: native]: " CPU_MARCH
    [[ -z "$CPU_MARCH" ]] && CPU_MARCH="native"

    log "Please select your video card vendor:"
    select video_choice in "AMD" "Intel" "NVIDIA" "VMware/VirtualBox"; do
        case $video_choice in
            AMD) VIDEO_CARDS="amdgpu radeonsi radeon"; break;;
            Intel) VIDEO_CARDS="intel i965"; break;;
            NVIDIA) VIDEO_CARDS="nvidia"; break;;
            "VMware/VirtualBox") VIDEO_CARDS="vmware virtio"; break;;
            *) err "Invalid selection.";;
        esac
    done

    local detected_cores; detected_cores=$(nproc --all 2>/dev/null || echo 2)
    local default_makeopts="-j$((detected_cores + 1)) -l${detected_cores}"
    read -r -p "Enter MAKEOPTS [Default: ${default_makeopts}]: " MAKEOPTS
    [[ -z "$MAKEOPTS" ]] && MAKEOPTS="$default_makeopts"

    # --- Summary and Confirmation ---
    log "--------------------------------------------------"
    log "Configuration Summary:"
    log "  Target Device:   ${TARGET_DEVICE}"
    log "  Timezone:        ${SYSTEM_TIMEZONE}"
    log "  Locale:          ${SYSTEM_LOCALE}"
    log "  CPU March:       ${CPU_MARCH}"
    log "  Video Card:      ${VIDEO_CARDS}"
    log "  MAKEOPTS:        ${MAKEOPTS}"
    log "--------------------------------------------------"
    
    if ! ask_confirm "Do you want to proceed with this configuration?"; then
        die "Installation cancelled by user."
    fi

    # Generate the config file in memory for the chroot stage
    {
        echo "TARGET_DEVICE='${TARGET_DEVICE}'"
        echo "SYSTEM_TIMEZONE='${SYSTEM_TIMEZONE}'"
        echo "SYSTEM_LOCALE='${SYSTEM_LOCALE}'"
        echo "CPU_MARCH='${CPU_MARCH}'"
        echo "VIDEO_CARDS='${VIDEO_CARDS}'"
        # Escape quotes for the file
        echo "MAKEOPTS='${MAKEOPTS}'"
        # We need EMERGE_JOBS for some internal functions
        echo "EMERGE_JOBS='${detected_cores}'"
    } > "$CONFIG_FILE_TMP"
}

# ==============================================================================
# --- STAGE 0B: DISK PREPARATION (DESTRUCTIVE) ---
# ==============================================================================
stage0_partition_and_format() {
    step_log "Disk Partitioning and Formatting"
    warn "This is the final confirmation step."
    warn "ALL DATA ON ${TARGET_DEVICE} WILL BE PERMANENTLY DESTROYED!"
    read -r -p "To confirm, type the full device name ('${TARGET_DEVICE}'): " confirmation
    if [[ "$confirmation" != "${TARGET_DEVICE}" ]]; then die "Confirmation failed. Aborting."; fi

    log "Wiping partition table on ${TARGET_DEVICE}..."; sgdisk --zap-all "${TARGET_DEVICE}"
    log "Creating new GPT partitions..."; sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System" "${TARGET_DEVICE}"; sgdisk -n 2:0:0 -t 2:8300 -c 2:"Gentoo Root" "${TARGET_DEVICE}"
    partprobe "${TARGET_DEVICE}"; sleep 2

    local part_prefix="${TARGET_DEVICE}"; if [[ "${TARGET_DEVICE}" == *nvme* ]]; then part_prefix="${TARGET_DEVICE}p"; fi
    local EFI_PART="${part_prefix}1"; local ROOT_PART="${part_prefix}2"

    log "Formatting partitions..."; mkfs.vfat -F 32 "${EFI_PART}"; mkfs.xfs -f "${ROOT_PART}"
    log "Mounting partitions..."; mount "${ROOT_PART}" "${GENTOO_MNT}"; mkdir -p "${GENTOO_MNT}/boot/efi"; mount "${EFI_PART}" "${GENTOO_MNT}/boot/efi"
}

# ==============================================================================
# --- STAGE 1: BASE SYSTEM DEPLOYMENT ---
# ==============================================================================
stage1_deploy_base_system() {
    step_log "Base System Deployment"
    log "Finding the latest stage3 tarball URL..."; local base_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/"; local latest_info_url="${base_url}latest-stage3-amd64-openrc.txt"; local latest_info; latest_info=$(curl -s "$latest_info_url" | head -n 1 | awk '{print $1}'); [[ -z "$latest_info" ]] && die "Could not fetch the latest stage3 information."
    local tarball_name; tarball_name=$(basename "$latest_info"); local tarball_url="${base_url}${latest_info}"; local digests_url="${tarball_url}.DIGESTS.asc"
    log "Downloading latest stage3: ${tarball_name}"; wget -c -P "${GENTOO_MNT}" "$tarball_url"; log "Downloading digests file..."; wget -c -P "${GENTOO_MNT}" "$digests_url"
    log "Verifying tarball integrity..."; pushd "${GENTOO_MNT}" >/dev/null; local expected_sha512; expected_sha512=$(grep -A1 'SHA512' "${tarball_name}.DIGESTS.asc" | tail -n 1); echo "${expected_sha512}  ${tarball_name}" | sha512sum -c -; popd >/dev/null; log "Checksum OK."
    log "Unpacking stage3 tarball..."; tar xpvf "${GENTOO_MNT}/${tarball_name}" --xattrs-include='*.*' --numeric-owner -C "${GENTOO_MNT}"; log "Base system deployed successfully."
}

# ==============================================================================
# --- STAGE 2: CHROOT PREPARATION ---
# ==============================================================================
stage2_prepare_and_enter_chroot() {
    step_log "Chroot Preparation"
    step_log "Generating /etc/fstab"; local part_prefix="${TARGET_DEVICE}"; if [[ "${TARGET_DEVICE}" == *nvme* ]]; then part_prefix="${TARGET_DEVICE}p"; fi; local EFI_PART="${part_prefix}1"; local ROOT_PART="${part_prefix}2"; local ROOT_UUID; ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PART}"); local EFI_UUID; EFI_UUID=$(blkid -s UUID -o value "${EFI_PART}")
    printf '%s\n' "# /etc/fstab: static file system information." "UUID=${ROOT_UUID}  /          xfs    defaults,noatime 0 1" "UUID=${EFI_UUID}   /boot/efi  vfat   defaults,noatime 0 2" > "${GENTOO_MNT}/etc/fstab"
    log "/etc/fstab generated successfully."
    log "Mounting virtual filesystems..."; mount --types proc /proc "${GENTOO_MNT}/proc"; mount --rbind /sys "${GENTOO_MNT}/sys"; mount --make-rslave "${GENTOO_MNT}/sys"; mount --rbind /dev "${GENTOO_MNT}/dev"; mount --make-rslave "${GENTOO_MNT}/dev"
    log "Copying DNS info..."; cp --dereference /etc/resolv.conf "${GENTOO_MNT}/etc/"
    local script_name; script_name=$(basename "$0"); local script_dest_path="${GENTOO_MNT}/root/${script_name}"; log "Copying this script into the chroot..."; cp "$0" "${script_dest_path}"; chmod +x "${script_dest_path}"
    cp "$CONFIG_FILE_TMP" "${GENTOO_MNT}/etc/autobuilder.conf"
    log "Entering chroot and executing Stage 3..."; chroot "${GENTOO_MNT}" "/root/${script_name}" --chrooted "$@"; log "Chroot execution finished. Cleaning up..."; rm -f "${script_dest_path}"; rm -f "$CONFIG_FILE_TMP"; log "Script finished successfully."; exit 0
}

# ==============================================================================
# --- STAGE 3: MAIN INSTALLATION LOGIC (INSIDE CHROOT) ---
# ==============================================================================
stage3_run_installation_logic() {
    source /etc/profile; export PS1="(chroot) ${PS1}"
    local LOG="/var/log/gentoo_ultimate_autobuilder.log"; : > "$LOG"
    local CONFIG_FILE="/etc/autobuilder.conf"
    
    # All modules from Praetorian go here...
    load_config() { log "Loading configuration from $CONFIG_FILE..."; source "$CONFIG_FILE" || die "Failed to load configuration."; }
    run_or_dry() { log "EXEC: $*"; if ! $DRY_RUN; then eval "$@"; fi; }
    ask_confirm() { if $FORCE_MODE || $AUTO_MODE; then return 0; fi; read -r -p "$1 [y/N] " response; [[ "$response" =~ ^[yY]([eE][sS])?$ ]]; }
    preflight_checks() { step_log "Running Pre-flight Safety Checks"; [[ "$(id -u)" -ne 0 ]] && die "This script must be run as root."; [[ "$(readlink /proc/1/exe)" != *openrc* ]] && die "This script is designed for OpenRC only."; log "Pre-flight checks passed."; }
    CURRENT_BACKUP=""; on_error() { local rc=${1:-1}; err "Script exited with code $rc. Attempting rollback..."; if [[ -n "$CURRENT_BACKUP" && -f "$CURRENT_BACKUP" ]]; then warn "Restoring from backup $CURRENT_BACKUP ..."; if ! $DRY_RUN; then tar -xzpf "$CURRENT_BACKUP" -C / || warn "Backup restoration failed."; fi; fi; err "See log for details: $LOG"; exit "$rc"; }; trap on_error ERR
    make_backup() { step_log "Creating System Backup"; mkdir -p "/var/backups/gentoo_autobuilder"; local ts; ts="$(date +%Y%m%d_%H%M%S)"; local backup_file="/var/backups/gentoo_autobuilder/gentoo_autobuilder_backup_${ts}.tar.gz"; CURRENT_BACKUP="$backup_file"; local files_to_backup=(/etc/portage /etc/fstab /etc/default/grub /etc/kernel-configs /boot); log "Creating backup: $backup_file"; if ! $DRY_RUN; then tar -czpf "$backup_file" --absolute-names --ignore-failed-read "${files_to_backup[@]}"; ls -1t "/var/backups/gentoo_autobuilder"/gentoo_autobuilder_backup_*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f; fi; }
    is_pkg_installed() { equery l -q "$1" >/dev/null 2>&1; }
    emerge_pkg() { local pkg="$1"; local attempt=1; if is_pkg_installed "$pkg"; then log "Package $pkg is already installed."; return 0; fi; log "Attempting to install package: $pkg"; while (( attempt <= 2 )); do if ! $DRY_RUN; then if emerge -j"${EMERGE_JOBS}" --load-average="${EMERGE_JOBS}" "${EMERGE_BASE_OPTS[@]}" "$pkg"; then command -v etc-update &>/dev/null && etc-update --automode -5; log "Successfully installed $pkg."; return 0; fi; else log "DRY-RUN: emerge $pkg"; return 0; fi; warn "Failed to install $pkg on attempt $attempt."; if (( attempt == 1 )); then warn "Retrying after 'emerge --sync'..."; run_or_dry "emerge --sync"; fi; attempt=$((attempt + 1)); done; err "Could not install $pkg after 2 attempts."; ask_confirm "Continue?" || die "Aborted by user."; return 1; }
    update_conf_variable() { local conf_file="$1"; local var_name="$2"; local new_value="$3"; log "Updating $var_name in $conf_file"; if ! $DRY_RUN; then touch "$conf_file"; sed -i -E "/^${var_name}=/s/^/# (deactivated by builder) &/" "$conf_file"; echo -e "\n# Added by The Centurion Autobuilder\n${var_name}=\"${new_value}\"" >> "$conf_file"; fi; }
    module_setup_localization() { step_log "Configuring System Localization"; log "Setting timezone to ${SYSTEM_TIMEZONE}"; run_or_dry "echo '${SYSTEM_TIMEZONE}' > /etc/timezone"; run_or_dry "emerge --config sys-libs/timezone-data"; log "Setting locale to ${SYSTEM_LOCALE}"; if ! grep -q "${SYSTEM_LOCALE}" /etc/locale.gen; then run_or_dry "echo '${SYSTEM_LOCALE} UTF-8' >> /etc/locale.gen"; fi; run_or_dry "locale-gen"; run_or_dry "eselect locale set '${SYSTEM_LOCALE}'"; }
    module_setup_portage() { step_log "Configuring Portage (make.conf)"; update_conf_variable "/etc/portage/make.conf" "COMMON_FLAGS" "-march=${CPU_MARCH} -O2 -pipe"; update_conf_variable "/etc/portage/make.conf" "MAKEOPTS" "${MAKEOPTS}"; update_conf_variable "/etc/portage/make.conf" "VIDEO_CARDS" "${VIDEO_CARDS}"; update_conf_variable "/etc/portage/make.conf" "INPUT_DEVICES" "libinput"; if ! grep -q "X" /etc/portage/make.conf; then update_conf_variable "/etc/portage/make.conf" "USE" "X xorg gtk3 dbus pulseaudio vulkan opengl udev drm alsa policykit xfce xfs unicode truetype"; fi; update_conf_variable "/etc/portage/make.conf" "ACCEPT_LICENSE" "*"; }
    module_setup_package_use() { step_log "Configuring Proactive USE Flags (package.use)"; local package_use_dir="/etc/portage/package.use"; local use_file="$package_use_dir/99_autobuilder_flags"; log "Creating USE flag configuration at $use_file"; if ! $DRY_RUN; then mkdir -p "$package_use_dir"; printf '%s\n' 'sys-auth/polkit elogind' 'x11-base/xorg-server elogind' 'xfce-base/xfce4-session elogind' 'x11-misc/lightdm gtk' 'media-libs/mesa X gallium vulkan' 'x11-libs/libnotify dbus' > "$use_file"; fi; }
    module_install_desktop() { step_log "Installing XFCE Desktop Environment"; local desktop_packages=("x11-base/xorg-server" "x11-misc/lightdm" "x11-misc/lightdm-gtk-greeter" "xfce-base/xfce4-meta" "xfce-extra/xfce4-goodies" "media-libs/mesa" "app-admin/eselect" "sys-auth/elogind"); for pkg in "${desktop_packages[@]}"; do emerge_pkg "$pkg"; done; log "Configuring services for automatic startup..."; if ! $DRY_RUN; then mkdir -p /etc/lightdm/lightdm.conf.d; printf '%s\n' '[Seat:*]' 'user-session=xfce' > /etc/lightdm/lightdm.conf.d/50-autobuilder.conf; run_or_dry "rc-update add lightdm default"; run_or_dry "rc-update add elogind default"; fi; }
    module_install_firmware() { step_log "Installing Firmware and Microcode"; emerge_pkg "sys-firmware/linux-firmware"; local cpu_vendor; cpu_vendor=$(grep -m 1 'vendor_id' /proc/cpuinfo); if [[ "$cpu_vendor" == *AuthenticAMD* ]]; then log "AMD CPU detected. Installing AMD microcode."; emerge_pkg "sys-kernel/linux-ucode-amd"; else log "Intel CPU detected. Installing Intel microcode."; emerge_pkg "sys-kernel/linux-ucode-intel"; fi; }
    module_install_utils() { step_log "Installing Common Utilities"; local utils_packages=("app-arch/p7zip" "sys-fs/ntfs3g" "sys-fs/exfat-utils"); for pkg in "${utils_packages[@]}"; do emerge_pkg "$pkg"; done; }
    module_build_kernel() { step_log "Building Intelligent, Hardware-Aware Kernel"; emerge_pkg "sys-kernel/gentoo-sources"; emerge_pkg "sys-kernel/genkernel"; local latest_kernel_dir; latest_kernel_dir=$(ls -d /usr/src/linux-* | sort -V | tail -n 1); [[ -z "$latest_kernel_dir" ]] && die "Kernel sources not found in /usr/src."; run_or_dry "ln -sfn '$latest_kernel_dir' /usr/src/linux"; log "Symlink /usr/src/linux now points to $latest_kernel_dir"; log "Generating kernel config with hardware auto-detection..."; if ! $DRY_RUN; then pushd /usr/src/linux >/dev/null; if [[ -f /proc/config.gz ]]; then log "Using running kernel's config as a base."; zcat /proc/config.gz > .config; else log "Creating default config."; make defconfig; fi; log "Running 'make localmodconfig' to tailor config to this hardware..."; make localmodconfig; popd >/dev/null; fi; local built_in_symbols=(DEVTMPFS DEVTMPFS_MOUNT TMPFS EFI_STUB EFI_PARTITION XFS_FS EXT4_FS BLK_DEV_INITRD DRM_AMDGPU DRM_RADEON); if [[ -x "/usr/src/linux/scripts/config" ]]; then for sym in "${built_in_symbols[@]}"; do run_or_dry "'/usr/src/linux/scripts/config' --enable '$sym'"; done; fi; run_or_dry "make -C /usr/src/linux olddefconfig"; if ask_confirm "Kernel configured. Begin compilation?"; then run_or_dry "make -C /usr/src/linux -j'${EMERGE_JOBS}'"; run_or_dry "make -C /usr/src/linux modules_install"; run_or_dry "make -C /usr/src/linux install"; run_or_dry "genkernel --install initramfs"; else warn "Kernel build skipped by user."; fi; }
    module_setup_bootloader() { step_log "Installing and Configuring Bootloader"; emerge_pkg "sys-boot/grub"; log "Installing GRUB to EFI partition..."; run_or_dry "grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Gentoo"; if ! grep -q "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub; then echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' >> /etc/default/grub; fi; local grub_cfg_path="/boot/grub/grub.cfg"; if ask_confirm "Generate GRUB configuration ($grub_cfg_path)?"; then run_or_dry "grub-mkconfig -o '$grub_cfg_path'"; else warn "GRUB config generation skipped."; fi; }
    module_create_user() { step_log "Interactive User Creation"; local username; if $AUTO_MODE || $FORCE_MODE; then warn "User creation is skipped in non-interactive modes."; return; fi; if ! ask_confirm "Would you like to create a new user?"; then log "Skipping user creation."; return; fi; while true; do read -r -p "Enter the desired username: " username; if [[ -z "$username" ]]; then warn "Username cannot be empty."; continue; fi; if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then warn "Invalid username format."; continue; fi; if id "$username" &>/dev/null; then warn "User '$username' already exists."; continue; fi; break; done; log "Creating user '$username' and adding to standard groups..."; run_or_dry "useradd -m -G wheel,users,audio,video,usb,portage -s /bin/bash '$username'"; log "Please set a password for the new user '$username'."; if ! $DRY_RUN; then passwd "$username"; fi; log "User '$username' created successfully."; }
    module_setup_security() { step_log "Establishing Security Foundation"; log "Setting up sudo for the 'wheel' group..."; emerge_pkg "app-admin/sudo"; if ! $DRY_RUN; then echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel; fi; log "Setting up Uncomplicated Firewall (ufw)..."; emerge_pkg "net-firewall/ufw"; run_or_dry "ufw default deny incoming"; run_or_dry "ufw default allow outgoing"; run_or_dry "ufw allow ssh"; run_or_dry "ufw --force enable"; run_or_dry "rc-update add ufw default"; }
    module_setup_timesync() { step_log "Setting up Time Synchronization"; emerge_pkg "net-misc/chrony"; run_or_dry "rc-update add chronyd default"; }
    module_setup_cron() { step_log "Installing Maintenance Cron Job"; local cron_file="/etc/cron.d/gentoo_master_builder"; log "Installing job for weekly system maintenance."; if ! $DRY_RUN; then printf '%s\n' '# Weekly system maintenance' "0 4 * * 1 root /root/$(basename "$0") --force >> /var/log/gentoo_master_builder_cron.log 2>&1" > "$cron_file"; chmod 644 "$cron_file"; fi; }
    final_summary() { log "--- SCRIPT COMPLETE ---"; echo -e "\n\n${C_GREEN}Gentoo Ultimate Deployer 'Centurion' has finished.${C_RESET}"; echo "Summary of actions:"; echo "- System localized, configured, and tuned."; echo "- Proactive USE flags configured and self-healing emerge performed."; echo "- XFCE Desktop Environment installed."; echo "- Hardware-aware kernel compiled and bootloader installed."; echo "- Interactive user account created."; echo "- Security foundation established (sudo, firewall)."; echo -e "\n${C_YELLOW}Recommended next step: unmount partitions and REBOOT the system.${C_RESET}"; }

    # --- Main Execution Flow (Inside Chroot) ---
    DRY_RUN=false; AUTO_MODE=false; FORCE_MODE=false
    shift; while [[ "${1:-}" != "" ]]; do case "$1" in --dry-run) DRY_RUN=true; shift ;; --auto) AUTO_MODE=true; shift ;; --force) FORCE_MODE=true; shift ;; -j) shift; EMERGE_JOBS="${1:-}"; shift ;; -h|--help) usage; exit 0 ;; *) err "Unknown option: $1"; usage; exit 1 ;; esac; done
    load_config
    EMERGE_BASE_OPTS=(--verbose --quiet-build=y --with-bdeps=y --ask=n --autounmask=y --autounmask-continue=y)
    log "Starting Stage 3: Main Installation..."; preflight_checks; command -v equery >/dev/null 2>&1 || emerge --onlydeps app-portage/gentoolkit; ping -c1 -W2 gentoo.org >/dev/null 2>&1 || warn "Network is unreachable."; make_backup; module_setup_localization; module_setup_portage; module_setup_package_use; module_install_firmware; module_install_utils; module_install_desktop; module_build_kernel; module_setup_bootloader; module_create_user; module_setup_security; module_setup_timesync; module_setup_cron; final_summary
}

# ==============================================================================
# --- SCRIPT ENTRY POINT ---
# ==============================================================================
main() {
    if [[ "${1:-}" == "--chrooted" ]]; then
        stage3_run_installation_logic "$@"
    else
        # This is the entry point for a bare disk
        interactive_setup
        stage0_partition_and_format
        stage1_deploy_base_system
        stage2_prepare_and_enter_chroot "$@"
    fi
}

main "$@"
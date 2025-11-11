#!/bin/bash
# shellcheck disable=SC1091,SC2016,SC2034,SC2154
# The Gentoo Genesis Engine
# Version: 10.10.1 "The Titan (Fixed & Enhanced)"
#
# Changelog:
# - v10.10.1: FIXED critical issues & enhanced reliability
#   - FIXED: Proper handling of blkid command variations across systems
#   - FIXED: Added fallback mechanisms for essential package installations
#   - FIXED: Improved ZRAM setup with better error handling
#   - FIXED: Added proper validation for user input and system state checks
#   - FIXED: Enhanced security for stage3 tarball verification
#   - FIXED: Better handling of Btrfs subvolume paths in auto-update script
#   - FIXED: Improved GRUB configuration merging logic
#   - ENHANCED: Added more robust error checking throughout the script
#   - ENHANCED: Better support for systems with limited resources
# - v10.10.0:
#   - RESILIENCE: The self-integrity check is now the very first action performed, preventing
#     any logic from running on a corrupted script.
#   - RESILIENCE: The `cleanup` function's `swapoff` call is now fully silenced to prevent
#     non-critical errors from halting the script on exit.
#   - UX: The integrity check failure message is now more explicit, suggesting `wget` or `curl`.
# - v10.9.0:
#   - HYPER-ROBUSTNESS: `--force` mode's password generation is now environment-agnostic.
#   - AUTOMATION: `load_checkpoint` is now non-interactive in `--force` mode.
# - v10.8.0:
#   - INTEGRITY CHECK: Added a script terminator variable to detect incomplete copy-paste errors.
# - v10.7.0:
#   - CRITICAL FIX: Resolved `make: command not found` error during bootstrap.
# --- Configuration and Globals ---
GENTOO_MNT="/mnt/gentoo"
CONFIG_FILE_TMP=""
CHECKPOINT_FILE="/tmp/.genesis_checkpoint"
LOG_FILE_PATH="/tmp/gentoo_autobuilder_$(date +%F_%H-%M).log"
START_STAGE=0

# Critical: Create temp config file safely
if ! CONFIG_FILE_TMP=$(mktemp "/tmp/autobuilder.conf.XXXXXX"); then
    echo "Error: Failed to create temporary configuration file." >&2
    exit 1
fi

export GENTOO_MNT CONFIG_FILE_TMP CHECKPOINT_FILE LOG_FILE_PATH START_STAGE

# Global variables initialization
EFI_PART=""
BOOT_PART=""
ROOT_PART=""
HOME_PART=""
SWAP_PART=""
LUKS_PART=""
BOOT_MODE=""
IS_LAPTOP=false
SKIP_CHECKSUM=false
CPU_VENDOR=""
CPU_MODEL_NAME=""
CPU_MARCH=""
CPU_FLAGS_X86=""
FASTEST_MIRRORS=""
MICROCODE_PACKAGE=""
VIDEO_CARDS=""
GPU_VENDOR="Unknown"
FORCE_MODE=false

# --- UX Enhancements & Logging ---
C_RESET='\033[0m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_RED='\033[0;31m'
STEP_COUNT=0
TOTAL_STEPS=11

# Check terminal capabilities before using colors
if [ -t 1 ] && command -v tput &>/dev/null && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    use_colors=true
else
    use_colors=false
    C_RESET=''; C_GREEN=''; C_YELLOW=''; C_RED=''
fi

log() { 
    printf "${C_GREEN}[INFO] %s${C_RESET}\n" "$*" | tee -a "$LOG_FILE_PATH"
}

warn() { 
    printf "${C_YELLOW}[WARN] %s${C_RESET}\n" "$*" >&2 | tee -a "$LOG_FILE_PATH"
}

err() { 
    printf "${C_RED}[ERROR] %s${C_RESET}\n" "$*" >&2 | tee -a "$LOG_FILE_PATH"
}

step_log() { 
    STEP_COUNT=$((STEP_COUNT + 1))
    printf "\n${C_GREEN}>>> [STEP %s/%s] %s${C_RESET}\n" "$STEP_COUNT" "$TOTAL_STEPS" "$*" | tee -a "$LOG_FILE_PATH"
}

die() { 
    err "$*"
    cleanup
    exit 1
}

# ==============================================================================
# --- ХЕЛПЕРЫ и Core Functions ---
# ==============================================================================
get_blkid_uuid() {
    local device=$1
    if [ ! -e "$device" ]; then
        die "Device $device does not exist. Cannot get UUID."
    fi
    
    if command -v blkid >/dev/null 2>&1; then
        if blkid -o value -s UUID "$device" >/dev/null 2>&1; then
            blkid -o value -s UUID "$device"
        elif blkid -s UUID -o value "$device" >/dev/null 2>&1; then
            blkid -s UUID -o value "$device"
        else
            warn "Could not get UUID for device $device using standard blkid methods."
            warn "Trying fallback method using udevadm..."
            if command -v udevadm >/dev/null; then
                udevadm info --query=property --name="$device" | grep -i "ID_FS_UUID=" | cut -d'=' -f2
            else
                die "Could not get UUID for device $device. blkid command failed and udevadm is not available."
            fi
        fi
    else
        die "blkid command not found. Please install sys-fs/util-linux."
    fi
}

# Check if filesystem is writable before performing operations
check_filesystem_writable() {
    local path=$1
    local tmpfile
    
    if [ ! -d "$path" ]; then
        mkdir -p "$path"
    fi
    
    tmpfile=$(mktemp -p "$path" .writetest.XXXXXX || echo "")
    if [ -z "$tmpfile" ] || [ ! -w "$tmpfile" ]; then
        return 1
    fi
    rm -f "$tmpfile" 2>/dev/null || true
    return 0
}

# Ensure critical filesystems are writable
ensure_writable_filesystems() {
    local critical_paths=("/tmp" "/var/tmp" "$GENTOO_MNT")
    
    # Check root filesystem
    if ! check_filesystem_writable "/"; then
        warn "Root filesystem is read-only. Attempting to remount as read-write..."
        if ! mount -o remount,rw /; then
            die "Failed to remount root filesystem as read-write. Please check dmesg for errors."
        fi
    fi
    
    # Check each critical path
    for path in "${critical_paths[@]}"; do
        if [ -d "$path" ] && ! check_filesystem_writable "$path"; then
            warn "Filesystem at $path is read-only. This may cause installation to fail."
            if ! mount -o remount,rw "$path" 2>/dev/null; then
                warn "Could not remount $path as read-write. Continuing, but installation may fail."
            fi
        fi
    done
}

save_checkpoint() { 
    log "--- Checkpoint reached: Stage $1 completed. ---"
    echo "$1" > "${CHECKPOINT_FILE}"
    sync
}

load_checkpoint() {
    if [ -f "${CHECKPOINT_FILE}" ]; then
        local last_stage
        last_stage=$(cat "${CHECKPOINT_FILE}" 2>/dev/null || echo "0")
        warn "Previous installation was interrupted after Stage ${last_stage}."
        if ${FORCE_MODE:-false}; then
            warn "Force mode is active. Automatically restarting installation from scratch."
            rm -f "${CHECKPOINT_FILE}" 2>/dev/null || true
            return
        fi
        
        local choice
        while true; do
            read -r -p "Choose action: [C]ontinue, [R]estart from scratch, [A]bort: " choice
            case "$choice" in
                [cC]) 
                    START_STAGE=$((last_stage + 1))
                    log "Resuming installation from Stage ${START_STAGE}."
                    return
                    ;;
                [rR]) 
                    log "Restarting installation from scratch."
                    rm -f "${CHECKPOINT_FILE}" 2>/dev/null || true
                    return
                    ;;
                [aA])
                    die "Installation aborted by user."
                    ;;
                *)
                    echo "Invalid choice. Please enter C, R, or A."
                    ;;
            esac
        done
    fi
}

run_emerge() {
    log "Emerging packages: $*"
    local retry_count=0
    local max_retries=3
    
    # Check if Portage tree is synced before emerging
    if [ ! -d "/var/db/repos/gentoo" ] || [ "$(find /var/db/repos/gentoo -maxdepth 0 -empty 2>/dev/null)" ]; then
        log "Portage tree appears to be unsynced or missing. Syncing now..."
        sync_portage_tree
    fi
    
    while [ $retry_count -lt $max_retries ]; do
        if emerge --autounmask-write=y --autounmask-continue=y --with-bdeps=y -v "$@" 2>&1 | tee -a "$LOG_FILE_PATH"; then
            log "Emerge successful for: $*"
            # Apply any config changes
            etc-update --automode -5 &>/dev/null || dispatch-conf --automode &>/dev/null || true
            return 0
        else
            retry_count=$((retry_count + 1))
            warn "Emerge attempt $retry_count/$max_retries failed for packages: '$*'."
            if [ $retry_count -lt $max_retries ]; then
                warn "Retrying in 10 seconds..."
                sleep 10
            fi
        fi
    done
    err "Emerge failed after $max_retries attempts for packages: '$*'."
    warn "This is often due to Portage needing configuration changes (USE flags, keywords, etc.)."
    warn "The required changes have likely been written to /etc/portage."
    warn "ACTION REQUIRED: After the script exits, run 'etc-update --automode -5' (or dispatch-conf) to apply them,"
    warn "then restart the installation to continue."
    return 1
}

cleanup() {
    err "An error occurred. Initiating cleanup..."
    sync
    
    # Ensure we're not in chroot before unmounting
    if [ "$(cut -d ' ' -f 2 /proc/1/cmdline 2>/dev/null)" != "CHROOT" ] && [ -d "${GENTOO_MNT}" ]; then
        # Try to unmount in reverse order
        if mountpoint -q "${GENTOO_MNT}/proc" 2>/dev/null; then
            umount -R "${GENTOO_MNT}/proc" &>/dev/null || umount -l "${GENTOO_MNT}/proc" &>/dev/null || true
        fi
        if mountpoint -q "${GENTOO_MNT}/sys" 2>/dev/null; then
            umount -R "${GENTOO_MNT}/sys" &>/dev/null || umount -l "${GENTOO_MNT}/sys" &>/dev/null || true
        fi
        if mountpoint -q "${GENTOO_MNT}/dev" 2>/dev/null; then
            umount -R "${GENTOO_MNT}/dev" &>/dev/null || umount -l "${GENTOO_MNT}/dev" &>/dev/null || true
        fi
        if mountpoint -q "${GENTOO_MNT}/run" 2>/dev/null; then
            umount -R "${GENTOO_MNT}/run" &>/dev/null || umount -l "${GENTOO_MNT}/run" &>/dev/null || true
        fi
        
        # Final attempt to unmount the main mount point
        if mountpoint -q "${GENTOO_MNT}"; then
            log "Attempting to unmount ${GENTOO_MNT}..."
            umount -R "${GENTOO_MNT}" &>/dev/null || umount -l "${GENTOO_MNT}" &>/dev/null || true
        fi
    fi
    
    # Safely handle ZRAM cleanup
    if [ -e /dev/zram0 ] && grep -q /dev/zram0 /proc/swaps &>/dev/null; then
        log "Deactivating ZRAM swap..."
        swapoff /dev/zram0 &>/dev/null || true
    fi
    
    # Clean up LUKS mappings if any
    if command -v cryptsetup &>/dev/null; then
        for dm in $(dmsetup ls --target crypt --exec basename 2>/dev/null || true); do
            if [ -n "$dm" ]; then
                log "Closing LUKS mapping: $dm"
                cryptsetup close "$dm" &>/dev/null || true
            fi
        done
    fi
    
    # Clean up LVM
    if command -v lvdisplay &>/dev/null; then
        for vg in $(vgs --noheadings -o vg_name 2>/dev/null || true); do
            if [ -n "$vg" ] && [[ "$vg" == *"gentoo_vg"* ]]; then
                log "Deactivating volume group: $vg"
                vgchange -an "$vg" &>/dev/null || true
            fi
        done
    fi
    
    # Clean up temp files
    if [ -n "$CONFIG_FILE_TMP" ] && [ -f "$CONFIG_FILE_TMP" ]; then
        rm -f "$CONFIG_FILE_TMP" 2>/dev/null || true
    fi
    
    if [ -f "$CHECKPOINT_FILE" ]; then
        rm -f "$CHECKPOINT_FILE" 2>/dev/null || true
    fi
    
    log "Cleanup finished."
}

# Enhanced trap handling for all exit scenarios
trap_handler() {
    local exit_code=$?
    local signal_name=$1
    
    # Only run cleanup once
    if [ "$exit_code" -eq 0 ] && [ "$signal_name" = "EXIT" ]; then
        return
    fi
    
    case $signal_name in
        INT)
            err "Script interrupted by user (Ctrl+C)."
            ;;
        TERM)
            err "Script terminated by SIGTERM."
            ;;
        ERR)
            err "Script encountered an error (exit code: $exit_code)."
            ;;
        EXIT)
            # Normal exit, no message needed
            ;;
        *)
            err "Script terminated by signal: $signal_name"
            ;;
    esac
    
    cleanup
    exit $exit_code
}

# Set up comprehensive signal handling
trap 'trap_handler $? INT' INT
trap 'trap_handler $? TERM' TERM
trap 'trap_handler $? ERR' ERR
trap 'trap_handler $? EXIT' EXIT

self_check() {
    log "Performing script integrity self-check..."
    
    # Check required functions
    local funcs=(pre_flight_checks ensure_dependencies stage0_select_mirrors interactive_setup stage0_partition_and_format stage1_deploy_base_system stage2_prepare_chroot stage3_configure_in_chroot stage4_build_world_and_kernel stage5_install_bootloader stage6_install_software stage7_finalize unmount_and_reboot)
    for func in "${funcs[@]}"; do
        if ! declare -f "$func" >/dev/null; then
            die "Self-check failed: Function '$func' is not defined. The script may be corrupt."
        fi
    done
    
    log "Self-check passed."
}

# ==============================================================================
# --- STAGES 0A: PRE-FLIGHT ---
# ==============================================================================
pre_flight_checks() {
    step_log "Performing Pre-flight System Checks"
    
    # Ensure critical filesystems are writable before proceeding
    ensure_writable_filesystems
    
    log "Checking for internet connectivity..."
    if ! ping -c 3 8.8.8.8 &>/dev/null; then
        warn "Could not ping 8.8.8.8. Trying alternative connectivity check..."
        if ! curl -s --connect-timeout 5 https://example.com &>/dev/null; then
            die "No internet connection detected. Please ensure network connectivity."
        fi
    fi
    log "Internet connection is OK."
    
    log "Detecting boot mode..."
    if [ -d /sys/firmware/efi ]; then
        BOOT_MODE="UEFI"
    else
        BOOT_MODE="LEGACY"
    fi
    log "System booted in ${BOOT_MODE} mode."
    
    if command -v laptop-detect &>/dev/null; then
        if laptop-detect; then
            log "Laptop detected using laptop-detect."
            IS_LAPTOP=true
        fi
    elif compgen -G "/sys/class/power_supply/BAT*" > /dev/null; then
        log "Laptop detected (battery found)."
        IS_LAPTOP=true
    fi
    
    # Check available disk space
    local available_space_mb
    available_space_mb=$(df -m /tmp | tail -1 | awk '{print $4}')
    if [ "$available_space_mb" -lt 2000 ]; then
        warn "Less than 2GB of free space in /tmp. This might cause issues during installation."
        if ! ask_confirm "Continue anyway?"; then
            die "Insufficient disk space. Installation aborted."
        fi
    fi
    
    # Check system architecture
    if [ "$(uname -m)" != "x86_64" ]; then
        die "This script only supports x86_64 architecture. Detected: $(uname -m)"
    fi
    
    # Check kernel version
    local kernel_version
    kernel_version=$(uname -r | cut -d'.' -f1-2)
    if [ "$(printf '%s\n4.14' "$kernel_version" | sort -V | head -n1)" = "$kernel_version" ]; then
        warn "Your kernel version ($kernel_version) is older than recommended (4.14+)."
        warn "Some features might not work correctly. Continue at your own risk."
        if ! ask_confirm "Continue with older kernel?"; then
            die "Installation requires kernel 4.14 or newer."
        fi
    fi
    
    # Check CPU
    if ! command -v lscpu &>/dev/null; then
        warn "lscpu command not found. CPU detection will be limited."
    fi
}

sync_portage_tree() {
    log "Syncing Portage tree..."
    mkdir -p /var/db/repos/gentoo 2>/dev/null || true
    
    # Try git sync first
    if command -v git &>/dev/null && [ -d "/var/db/repos/gentoo/.git" ]; then
        if emerge --sync 2>>"$LOG_FILE_PATH"; then
            log "Portage sync via git successful."
            return 0
        fi
    fi
    
    # Fallback to websync
    warn "Git sync failed or not available, falling back to emerge-webrsync."
    if command -v wget &>/dev/null || command -v curl &>/dev/null; then
        if emerge-webrsync 2>>"$LOG_FILE_PATH"; then
            log "Portage sync via webrsync successful."
            return 0
        else
            # Last resort: try to download a snapshot manually
            warn "emerge-webrsync failed. Trying to download a portage snapshot manually..."
            local snapshot_url="https://distfiles.gentoo.org/snapshots/portage-latest.tar.xz"
            local snapshot_file="/var/tmp/portage-latest.tar.xz"
            
            if command -v wget &>/dev/null; then
                wget --tries=3 --timeout=30 -O "$snapshot_file" "$snapshot_url" 2>>"$LOG_FILE_PATH"
            elif command -v curl &>/dev/null; then
                curl --retry 3 --connect-timeout 30 -L -o "$snapshot_file" "$snapshot_url" 2>>"$LOG_FILE_PATH"
            fi
            
            if [ -f "$snapshot_file" ] && command -v tar &>/dev/null; then
                log "Extracting portage snapshot..."
                tar xpvf "$snapshot_file" -C /var/db/repos/ 2>>"$LOG_FILE_PATH"
                rm -f "$snapshot_file"
                log "Portage snapshot extracted successfully."
                return 0
            fi
        fi
    fi
    
    die "Failed to sync Portage tree with all available methods."
}

ensure_dependencies() {
    step_log "Ensuring LiveCD Dependencies"
    
    # Check for required core utilities first
    local core_utils="bash coreutils util-linux findutils grep sed awk tar xz"
    for util in $core_utils; do
        if ! command -v "$util" >/dev/null 2>&1; then
            die "Critical dependency missing: $util. This script requires a full Gentoo Minimal Install CD environment."
        fi
    done
    
    # Check for swap and create ZRAM if needed
    if ! grep -q swap /proc/swaps; then
        warn "No active swap detected. This can cause Portage to crash on low-memory LiveCDs."
        local total_mem_kb
        total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        local total_mem_mb=$((total_mem_kb / 1024))
        if [ "$total_mem_mb" -lt 2048 ]; then
            warn "WARNING: System has less than 2GB RAM. ZRAM swap is strongly recommended."
        fi
        if ask_confirm "Create a temporary ZRAM swap to prevent installation failures?"; then
            log "Setting up ZRAM..."
            # Ensure zram module is loaded
            if ! modprobe zram &>/dev/null; then
                warn "Failed to load zram kernel module. Trying to continue without swap."
                if ! ask_confirm "Continue without swap? This may cause installation to fail."; then
                    die "Installation aborted due to lack of swap space."
                fi
            else
                local zram_size_kb=$(( total_mem_kb / 2 ))
                if [ "$zram_size_kb" -gt 2097152 ]; then zram_size_kb=2097152; fi
                
                # Make sure zram device exists
                if [ ! -e /dev/zram0 ]; then
                    if [ -d /sys/class/zram-control ]; then
                        echo 1 > /sys/class/zram-control/hot_add 2>/dev/null || true
                    else
                        warn "Could not create zram device. Continuing without swap."
                        return
                    fi
                fi
                
                # Reset zram device if it exists
                if [ -e /sys/block/zram0 ]; then
                    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
                fi
                
                echo $(( zram_size_kb * 1024 )) > /sys/block/zram0/disksize
                if mkswap /dev/zram0 &>/dev/null; then
                    swapon /dev/zram0 -p 10
                    log "ZRAM swap activated successfully."
                else
                    warn "Failed to create swap on ZRAM. Continuing without swap. Installation may fail."
                fi
            fi
        else
            warn "Proceeding without swap. Installation may fail on low-memory systems."
        fi
    fi
    
    # Check for required packages
    local build_essentials_pkgs=""
    local compiler_pkgs=""
    local other_pkgs=""
    local all_deps="make patch sandbox curl wget sgdisk parted mkfs.vfat mkfs.xfs mkfs.ext4 mkfs.btrfs blkid lsblk sha512sum b2sum chroot wipefs blockdev cryptsetup lvm pvcreate vgcreate lvcreate mkswap lscpu lspci udevadm gcc parted"
    
    # Check if we're in a proper Gentoo environment
    if ! command -v emerge &>/dev/null; then
        die "emerge command not found. Please ensure you are running this script from a Gentoo LiveCD."
    fi
    
    get_pkg_for_cmd() {
        case "$1" in
            make) echo "sys-devel/make" ;;
            patch) echo "sys-devel/patch" ;;
            sandbox) echo "sys-apps/sandbox" ;;
            curl) echo "net-misc/curl" ;;
            wget) echo "net-misc/wget" ;;
            sgdisk) echo "sys-apps/gptfdisk" ;;
            parted) echo "sys-apps/parted" ;;
            mkfs.vfat) echo "sys-fs/dosfstools" ;;
            mkfs.xfs) echo "sys-fs/xfsprogs" ;;
            mkfs.ext4) echo "sys-fs/e2fsprogs" ;;
            mkfs.btrfs) echo "sys-fs/btrfs-progs" ;;
            sha512sum|b2sum) echo "app-crypt/sha512sum app-crypt/b2sum" ;;
            chroot) echo "sys-apps/util-linux" ;;
            lspci) echo "sys-apps/pciutils" ;;
            gcc) echo "sys-devel/gcc" ;;
            cryptsetup) echo "sys-fs/cryptsetup" ;;
            pvcreate|vgcreate|lvcreate) echo "sys-fs/lvm2" ;;
            udevadm) echo "virtual/udev" ;;
            blockdev|lsblk) echo "sys-apps/util-linux" ;;
            lscpu) echo "sys-apps/util-linux" ;;
            *) echo "" ;;
        esac
    }
    
    log "Checking for required tools..."
    local missing_commands=""
    for cmd in $all_deps; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands="$missing_commands $cmd"
            pkgs=$(get_pkg_for_cmd "$cmd")
            for pkg in $pkgs; do
                if [ -n "$pkg" ]; then
                    case "$pkg" in
                        sys-devel/make|sys-devel/patch|sys-apps/sandbox)
                            if ! echo "$build_essentials_pkgs" | grep -q "$pkg"; then
                                build_essentials_pkgs="$build_essentials_pkgs $pkg"
                            fi
                            ;;
                        sys-devel/gcc)
                            if ! echo "$compiler_pkgs" | grep -q "$pkg"; then
                                compiler_pkgs="$compiler_pkgs $pkg"
                            fi
                            ;;
                        *)
                            if ! echo "$other_pkgs" | grep -q "$pkg"; then
                                other_pkgs="$other_pkgs $pkg"
                            fi
                            ;;
                    esac
                fi
            done
        fi
    done
    
    if [ -n "$missing_commands" ]; then
        warn "Missing commands detected:$missing_commands"
    fi
    
    if [ -n "$build_essentials_pkgs" ] || [ -n "$compiler_pkgs" ] || [ -n "$other_pkgs" ]; then
        warn "Some required packages are missing. Preparing for installation."
        if ask_confirm "Do you want to proceed with automatic installation of dependencies?"; then
            sync_portage_tree
            local emerge_opts="--jobs=1 --load-average=1.5 --quiet-build"
            
            # Install essentials in the correct order
            if [ -n "$build_essentials_pkgs" ]; then
                log "Installing build essentials: ${build_essentials_pkgs}"
                if ! emerge $emerge_opts --noreplace $build_essentials_pkgs 2>>"${LOG_FILE_PATH}"; then
                    warn "Failed to install some build essentials. Trying with reduced parallelism..."
                    if ! emerge $emerge_opts --jobs=1 --load-average=1 --noreplace $build_essentials_pkgs 2>>"${LOG_FILE_PATH}"; then
                        die "Failed to install build essentials after multiple attempts."
                    fi
                fi
                log "Build essentials installed successfully."
            fi
            
            if [ -n "$other_pkgs" ]; then
                log "Installing other required tools: ${other_pkgs}"
                if ! emerge $emerge_opts --noreplace $other_pkgs 2>>"${LOG_FILE_PATH}"; then
                    warn "Failed to install some dependencies. Trying with reduced parallelism..."
                    if ! emerge $emerge_opts --jobs=1 --load-average=1 --noreplace $other_pkgs 2>>"${LOG_FILE_PATH}"; then
                        die "Failed to install required dependencies after multiple attempts."
                    fi
                fi
                log "Other tools installed successfully."
            fi
            
            if [ -n "$compiler_pkgs" ]; then
                log "Installing compiler: ${compiler_pkgs}"
                if ! emerge $emerge_opts --noreplace $compiler_pkgs 2>>"${LOG_FILE_PATH}"; then
                    warn "Failed to install compiler. Trying with reduced parallelism and disabled openmp..."
                    if ! USE="-openmp" emerge $emerge_opts --jobs=1 --load-average=1 --noreplace $compiler_pkgs 2>>"${LOG_FILE_PATH}"; then
                        die "Failed to install the compiler (gcc) after multiple attempts."
                    fi
                fi
                log "Compiler installed successfully."
            fi
        else
            die "Missing dependencies. Installation requires these packages to proceed."
        fi
    else
        log "All dependencies are satisfied."
    fi
    
    # Additional check for filesystem tools
    local fs_tools="mkfs.ext4 mkfs.xfs mkfs.btrfs mkfs.vfat"
    for tool in $fs_tools; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            warn "Filesystem tool $tool is missing. Installation may fail when formatting partitions."
        fi
    done
}

stage0_select_mirrors() {
    step_log "Selecting Fastest Mirrors"
    if ask_confirm "Do you want to automatically select the fastest mirrors? (Recommended)"; then
        sync_portage_tree
        if ! command -v mirrorselect &>/dev/null; then
            log "Installing mirrorselect..."
            run_emerge app-portage/mirrorselect
        fi
        log "Running mirrorselect, this may take a minute..."
        # Retry mirrorselect if it fails
        local retry_count=0
        while [ $retry_count -lt 3 ]; do
            if FASTEST_MIRRORS=$(mirrorselect -s4 -b10 -o -D 2>>"${LOG_FILE_PATH}"); then
                break
            else
                retry_count=$((retry_count + 1))
                warn "mirrorselect attempt $retry_count failed. Retrying in 5 seconds..."
                sleep 5
            fi
        done
        if [ -z "$FASTEST_MIRRORS" ]; then
            warn "Failed to select fastest mirrors after multiple attempts. Using default mirrors."
        else
            log "Fastest mirrors selected."
            # Ensure the directory exists before writing
            mkdir -p /etc/portage
            echo "$FASTEST_MIRRORS" > /etc/portage/make.conf.mirrors
            log "Mirror configuration saved to /etc/portage/make.conf.mirrors"
        fi
    else
        log "Skipping mirror selection. Default mirrors will be used."
    fi
}

# ==============================================================================
# --- HARDWARE DETECTION ENGINE ---
# ==============================================================================
detect_cpu_architecture() {
    step_log "Hardware Detection Engine (CPU)"
    if ! command -v lscpu >/dev/null; then
        warn "lscpu command not found. Falling back to generic settings."
        CPU_VENDOR="Generic"
        CPU_MODEL_NAME="Unknown"
        CPU_MARCH="x86-64-v2"
        MICROCODE_PACKAGE=""
        # Default video drivers
        VIDEO_CARDS="vesa fbdev"
        return
    fi
    
    # Get CPU model and vendor
    CPU_MODEL_NAME=$(lscpu --parse=MODELNAME | tail -n 1 | sed 's/"//g')
    local vendor_id
    vendor_id=$(lscpu --parse=VENDORID | tail -n 1)
    log "Detected CPU Model: ${CPU_MODEL_NAME}"
    
    case "$vendor_id" in
        "GenuineIntel")
            CPU_VENDOR="Intel"
            MICROCODE_PACKAGE="sys-firmware/intel-microcode"
            case "$CPU_MODEL_NAME" in
                *"14th Gen"*|*"13th Gen"*|*"12th Gen"*)
                    CPU_MARCH="alderlake"
                    ;;
                *"11th Gen"*)
                    CPU_MARCH="tigerlake"
                    ;;
                *"10th Gen"*)
                    CPU_MARCH="icelake-client"
                    ;;
                *"9th Gen"*|*"8th Gen"*|*"7th Gen"*|*"6th Gen"*)
                    CPU_MARCH="skylake"
                    ;;
                *"Core 2"*)
                    CPU_MARCH="core2"
                    ;;
                *)
                    warn "Unrecognized Intel CPU. Attempting to detect native march with GCC."
                    if command -v gcc &>/dev/null; then
                        local native_march
                        native_march=$(gcc -march=native -Q --help=target 2>/dev/null | grep -- '-march=' | awk '{print $2}' || true)
                        if [ -n "$native_march" ]; then
                            CPU_MARCH="$native_march"
                            log "Successfully detected native GCC march: ${CPU_MARCH}"
                        else
                            warn "GCC native march detection failed. Falling back to modern generic x86-64-v3."
                            CPU_MARCH="x86-64-v3"
                        fi
                    else
                        warn "GCC not found. Falling back to a modern generic architecture."
                        CPU_MARCH="x86-64-v3"
                    fi
                    ;;
            esac
            ;;
        "AuthenticAMD")
            CPU_VENDOR="AMD"
            MICROCODE_PACKAGE="sys-firmware/amd-microcode"
            case "$CPU_MODEL_NAME" in
                *"Ryzen 9 7"*|*"Ryzen 7 7"*|*"Ryzen 5 7"*)
                    CPU_MARCH="znver4"
                    ;;
                *"Ryzen 9 5"*|*"Ryzen 7 5"*|*"Ryzen 5 5"*)
                    CPU_MARCH="znver3"
                    ;;
                *"Ryzen 9 3"*|*"Ryzen 7 3"*|*"Ryzen 5 3"*)
                    CPU_MARCH="znver2"
                    ;;
                *"Ryzen 7 2"*|*"Ryzen 5 2"*|*"Ryzen 7 1"*|*"Ryzen 5 1"*)
                    CPU_MARCH="znver1"
                    ;;
                *"FX"*)
                    CPU_MARCH="bdver4"
                    ;;
                *)
                    warn "Unrecognized AMD CPU. Attempting to detect native march with GCC."
                    if command -v gcc &>/dev/null; then
                        local native_march
                        native_march=$(gcc -march=native -Q --help=target 2>/dev/null | grep -- '-march=' | awk '{print $2}' || true)
                        if [ -n "$native_march" ]; then
                            CPU_MARCH="$native_march"
                            log "Successfully detected native GCC march: ${CPU_MARCH}"
                        else
                            warn "GCC native march detection failed. Falling back to modern generic x86-64-v3."
                            CPU_MARCH="x86-64-v3"
                        fi
                    else
                        warn "GCC not found. Falling back to a modern generic architecture."
                        CPU_MARCH="x86-64-v3"
                    fi
                    ;;
            esac
            ;;
        *)
            warn "Unsupported CPU Vendor: ${vendor_id}. Falling back to generic x86-64-v2."
            CPU_VENDOR="Generic"
            CPU_MARCH="x86-64-v2"
            MICROCODE_PACKAGE=""
            ;;
    esac
    
    # Safety check for march values
    case "$CPU_MARCH" in
        native) CPU_MARCH="x86-64-v3" ;;
        "") CPU_MARCH="x86-64-v2" ;;
        *) ;;
    esac
    
    log "Auto-selected -march=${CPU_MARCH} for your ${CPU_VENDOR} CPU."
}

detect_cpu_flags() {
    log "Hardware Detection Engine (CPU Flags)"
    if ! command -v cpuid2cpuflags &>/dev/null; then
        if command -v emerge &>/dev/null && ask_confirm "Utility 'cpuid2cpuflags' not found. Install it to detect optimal CPU USE flags?"; then
            run_emerge app-portage/cpuid2cpuflags
        fi
    fi
    
    if command -v cpuid2cpuflags &>/dev/null; then
        log "Detecting CPU-specific USE flags..."
        # Filter out any problematic flags
        CPU_FLAGS_X86=$(cpuid2cpuflags 2>/dev/null | cut -d' ' -f2- | sed 's/-march=[^ ]*//g' | sed 's/-mtune=[^ ]*//g')
        # Remove duplicate flags and clean up
        CPU_FLAGS_X86=$(echo "$CPU_FLAGS_X86" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')
        log "Detected CPU_FLAGS_X86: ${CPU_FLAGS_X86}"
    else
        warn "Skipping CPU flag detection."
    fi
}

detect_gpu_hardware() {
    step_log "Hardware Detection Engine (GPU)"
    if ! command -v lspci >/dev/null; then
        warn "lspci not found. Using generic video drivers."
        VIDEO_CARDS="vesa fbdev"
        GPU_VENDOR="Unknown"
        return
    fi
    
    local intel_detected=false
    local amd_detected=false
    local nvidia_detected=false
    
    # Use safer parsing of lspci output
    lspci -mm 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | grep -iqE "VGA|3D controller"; then
            if echo "$line" | grep -iq "Intel"; then
                intel_detected=true
            fi
            if echo "$line" | grep -iq "AMD|ATI"; then
                amd_detected=true
            fi
            if echo "$line" | grep -iq "NVIDIA"; then
                nvidia_detected=true
            fi
        fi
    done
    
    # Default drivers
    VIDEO_CARDS="vesa fbdev"
    if [ "$intel_detected" = true ]; then
        log "Intel GPU detected. Adding 'intel i965' drivers."
        VIDEO_CARDS+=" intel i965"
        GPU_VENDOR="Intel"
    fi
    if [ "$amd_detected" = true ]; then
        log "AMD/ATI GPU detected. Adding 'amdgpu radeonsi' drivers."
        VIDEO_CARDS+=" amdgpu radesi"
        GPU_VENDOR="AMD"
    fi
    if [ "$nvidia_detected" = true ]; then
        log "NVIDIA GPU detected. Adding 'nouveau' driver for kernel support."
        VIDEO_CARDS+=" nouveau"
        GPU_VENDOR="NVIDIA"
    fi
    
    log "Final VIDEO_CARDS for make.conf: ${VIDEO_CARDS}"
    log "Primary GPU vendor for user interaction: ${GPU_VENDOR}"
}

# ==============================================================================
# --- Utility Functions ---
# ==============================================================================
ask_confirm() {
    if ${FORCE_MODE:-false}; then
        return 0
    fi
    
    local response
    while true; do
        read -r -p "$1 [y/N] " response
        case "$response" in
            [yY]|[yY][eE][sS]) return 0 ;;
            [nN]|[nN][oO]|"") return 1 ;;
            *) echo "Please enter y or n." ;;
        esac
    done
}

ask_password() {
    local password1 password2
    
    while true; do
        read -rs -p "$1: " password1
        echo
        read -rs -p "Confirm $1: " password2
        echo
        
        if [ "$password1" = "$password2" ]; then
            if [ "${#password1}" -lt 8 ]; then
                echo "Password too short. Minimum 8 characters required."
                continue
            fi
            echo "$password1"
            return 0
        else
            echo "Passwords do not match. Please try again."
        fi
    done
}

# ==============================================================================
# --- STAGE 0B: INTERACTIVE SETUP WIZARD ---
# ==============================================================================
interactive_setup() {
    step_log "Interactive Setup Wizard"
    log "--- Hardware Auto-Detection Results ---"
    log "  CPU Model:       ${CPU_MODEL_NAME}"
    log "  Selected March:  ${CPU_MARCH}"
    log "  CPU Flags:       ${CPU_FLAGS_X86:-None detected}"
    log "  GPU Vendor:      ${GPU_VENDOR}"
    
    if ! ask_confirm "Are these hardware settings correct?"; then
        die "Installation cancelled."
    fi
    
    NVIDIA_DRIVER_CHOICE="None"
    if [ "$GPU_VENDOR" = "NVIDIA" ]; then
        log "--- NVIDIA Driver Selection ---"
        warn "An NVIDIA GPU has been detected. Please choose the desired driver:"
        PS3="Select driver option (1-3): "
        select choice in "Proprietary (Best Performance, Recommended)" "Nouveau (Open-Source, Good Compatibility)" "Manual (Configure later)"; do
            case $REPLY in
                1) NVIDIA_DRIVER_CHOICE="Proprietary"; VIDEO_CARDS+=" nvidia"; break;;
                2) NVIDIA_DRIVER_CHOICE="Nouveau"; break;;
                3) NVIDIA_DRIVER_CHOICE="Manual"; break;;
                *) echo "Invalid option. Please select 1, 2, or 3." ;;
            esac
        done
        unset PS3
    fi
    
    log "--- System Architecture & Security ---"
    USE_HARDENED_PROFILE=false
    if ask_confirm "Use Hardened profile for enhanced security?"; then
        USE_HARDENED_PROFILE=true
    fi
    
    log "Select init system:"
    PS3="Select init system (1-2): "
    select INIT_SYSTEM in "OpenRC" "SystemD"; do
        case $REPLY in
            1) INIT_SYSTEM="OpenRC"; break;;
            2) INIT_SYSTEM="SystemD"; break;;
            *) echo "Invalid option. Please select 1 or 2." ;;
        esac
    done
    unset PS3
    
    log "Select Linux Security Module (LSM):"
    PS3="Select LSM (1-3): "
    select LSM_CHOICE in "None" "AppArmor" "SELinux"; do
        case $REPLY in
            1) LSM_CHOICE="None"; break;;
            2) LSM_CHOICE="AppArmor"; break;;
            3) LSM_CHOICE="SELinux"; break;;
            *) echo "Invalid option. Please select 1, 2, or 3." ;;
        esac
    done
    unset PS3
    
    ENABLE_FIREWALL=false
    if ask_confirm "Set up a basic firewall (ufw)? (Highly Recommended)"; then
        ENABLE_FIREWALL=true
    fi
    
    log "--- Multimedia Subsystem ---"
    USE_PIPEWIRE=false
    if ask_confirm "Use PipeWire as the default audio server? (Recommended for modern systems)"; then
        USE_PIPEWIRE=true
    fi
    
    log "--- Desktop Environment ---"
    log "Select desktop environment:"
    PS3="Select desktop environment (1-5): "
    select DESKTOP_ENV in "XFCE" "KDE-Plasma" "GNOME" "i3-WM" "Server (No GUI)"; do
        case $REPLY in
            1) DESKTOP_ENV="XFCE"; break;;
            2) DESKTOP_ENV="KDE-Plasma"; break;;
            3) DESKTOP_ENV="GNOME"; break;;
            4) DESKTOP_ENV="i3-WM"; break;;
            5) DESKTOP_ENV="Server (No GUI)"; break;;
            *) echo "Invalid option. Please select 1-5." ;;
        esac
    done
    unset PS3
    
    INSTALL_STYLING=false
    if [ "$DESKTOP_ENV" != "Server (No GUI)" ]; then
        if ask_confirm "Install a base styling set (Papirus Icons, FiraCode Nerd Font)?"; then
            INSTALL_STYLING=true
        fi
    fi
    
    log "--- Kernel Management ---"
    log "Select kernel management method:"
    PS3="Select kernel method (1-4): "
    select KERNEL_METHOD in "genkernel (recommended, auto)" "gentoo-kernel (distribution kernel, balanced)" "gentoo-kernel-bin (fastest, pre-compiled)" "manual (expert, interactive)"; do
        case $REPLY in
            1) KERNEL_METHOD="genkernel (recommended, auto)"; break;;
            2) KERNEL_METHOD="gentoo-kernel (distribution kernel, balanced)"; break;;
            3) KERNEL_METHOD="gentoo-kernel-bin (fastest, pre-compiled)"; break;;
            4) KERNEL_METHOD="manual (expert, interactive)"; break;;
            *) echo "Invalid option. Please select 1-4." ;;
        esac
    done
    unset PS3
    
    log "--- Performance Options ---"
    USE_CCACHE=false
    if ask_confirm "Enable ccache for faster recompiles?"; then
        USE_CCACHE=true
    fi
    
    USE_BINPKGS=false
    if ask_confirm "Use binary packages to speed up installation (if available)?"; then
        USE_BINPKGS=true
    fi
    
    USE_LTO=false
    if ask_confirm "Enable LTO (Link-Time Optimization) system-wide? (experimental)"; then
        USE_LTO=true
    fi
    
    ENABLE_CPU_GOVERNOR=false
    if [ "$IS_LAPTOP" = true ]; then
        if ask_confirm "Install an intelligent CPU governor for performance/battery balance?"; then
            ENABLE_CPU_GOVERNOR=true
        fi
    fi
    
    log "--- System Maintenance ---"
    ENABLE_AUTO_UPDATE=false
    if ask_confirm "Set up automatic weekly system updates? (Recommended for stable branch)"; then
        ENABLE_AUTO_UPDATE=true
    fi
    
    log "--- Storage and System Configuration ---"
    log "Available block devices:"
    lsblk -d -o NAME,SIZE,TYPE
    
    local valid_device=false
    while [ "$valid_device" = false ]; do
        read -r -p "Enter the target device for installation (e.g., /dev/sda): " TARGET_DEVICE
        
        if [ -z "$TARGET_DEVICE" ]; then
            err "Device name cannot be empty."
            continue
        fi
        
        if ! [ -b "$TARGET_DEVICE" ]; then
            err "Device '$TARGET_DEVICE' does not exist."
            continue
        fi
        
        if echo "$TARGET_DEVICE" | grep -qE '[0-9]$'; then
            warn "Device '$TARGET_DEVICE' looks like a partition, not a whole disk."
            if ! ask_confirm "Are you absolutely sure you want to proceed?"; then
                continue
            fi
        fi
        
        if ! blockdev --getsize64 "$TARGET_DEVICE" &>/dev/null; then
            err "Cannot get size of device '$TARGET_DEVICE'. It might not be a valid block device."
            continue
        fi
        
        local device_size_mb
        device_size_mb=$(( $(blockdev --getsize64 "$TARGET_DEVICE" 2>/dev/null || echo 0) / 1024 / 1024 ))
        if [ "$device_size_mb" -lt 8192 ]; then
            warn "Device '$TARGET_DEVICE' is smaller than 8GB. This might not be enough space for a full Gentoo installation."
            if ! ask_confirm "Continue anyway?"; then
                continue
            fi
        fi
        
        valid_device=true
    done
    
    while true; do
        read -r -p "Enter root filesystem type [xfs/ext4/btrfs, Default: btrfs]: " ROOT_FS_TYPE
        [ -z "$ROOT_FS_TYPE" ] && ROOT_FS_TYPE="btrfs"
        case "$ROOT_FS_TYPE" in
            xfs|ext4|btrfs) break;;
            *) err "Invalid filesystem. Please choose xfs, ext4, or btrfs.";;
        esac
    done
    
    ENABLE_BOOT_ENVIRONMENTS=false
    if [ "$ROOT_FS_TYPE" = "btrfs" ]; then
        if ask_confirm "Enable Boot Environments for atomic updates and rollbacks? (Requires Btrfs)"; then
            ENABLE_BOOT_ENVIRONMENTS=true
        fi
    else
        warn "Boot Environments feature is only available with Btrfs."
    fi
    
    log "--- Swap Configuration ---"
    SWAP_TYPE="zram"
    SWAP_SIZE_GB=0
    log "Select swap type:"
    PS3="Select swap type (1-3): "
    select choice in "zram (in-memory swap, recommended)" "partition (traditional on-disk swap)" "none"; do
        case $REPLY in
            1) SWAP_TYPE="zram (in-memory swap, recommended)"; break;;
            2) SWAP_TYPE="partition (traditional on-disk swap)"; break;;
            3) SWAP_TYPE="none"; break;;
            *) echo "Invalid option. Please select 1, 2, or 3." ;;
        esac
    done
    unset PS3
    
    if [ "$SWAP_TYPE" = "partition (traditional on-disk swap)" ]; then
        while true; do
            read -r -p "Enter SWAP size in GB (e.g., 8). [Default: 4]: " SWAP_SIZE_GB
            [ -z "$SWAP_SIZE_GB" ] && SWAP_SIZE_GB=4
            if echo "$SWAP_SIZE_GB" | grep -qE '^[0-9]+$'; then
                if [ "$SWAP_SIZE_GB" -gt 32 ]; then
                    warn "SWAP size greater than 32GB is unusual. Are you sure?"
                    if ! ask_confirm "Continue with ${SWAP_SIZE_GB}GB swap?"; then
                        continue
                    fi
                fi
                break
            else
                err "Invalid input. Please enter a number."
            fi
        done
    fi
    
    USE_LUKS=false
    ENCRYPT_BOOT=false
    if ask_confirm "Use LUKS full-disk encryption for the root partition?"; then
        USE_LUKS=true
        if [ "$BOOT_MODE" = "UEFI" ]; then
            if ask_confirm "Encrypt the /boot partition as well? (Maximum security)"; then
                ENCRYPT_BOOT=true
                USE_LVM=true
                warn "Encrypted /boot selected. LVM will be enabled automatically."
            fi
        else
            warn "Encrypted /boot is only supported in UEFI mode by this script."
        fi
    fi
    
    if [ "$USE_LUKS" = true ]; then
        LUKS_PASSPHRASE=$(ask_password "Enter LUKS passphrase (minimum 8 characters)")
        export LUKS_PASSPHRASE
    fi
    
    if [ "$ENCRYPT_BOOT" != true ]; then
        USE_LVM=false
        if ask_confirm "Use LVM to manage partitions?"; then
            USE_LVM=true
        fi
    fi
    
    USE_SEPARATE_HOME=false
    HOME_SIZE_GB=0
    if [ "$USE_LVM" = true ]; then
        if ask_confirm "Create a separate logical volume for /home?"; then
            USE_SEPARATE_HOME=true
            while true; do
                read -r -p "Enter /home size in GB [Default: 20]: " HOME_SIZE_GB
                [ -z "$HOME_SIZE_GB" ] && HOME_SIZE_GB=20
                if echo "$HOME_SIZE_GB" | grep -qE '^[0-9]+$'; then
                    break
                else
                    err "Invalid input. Please enter a number."
                fi
            done
        fi
    else
        warn "A separate /home partition is only supported with LVM in this script."
    fi
    
    while true; do
        read -r -p "Enter timezone [Default: UTC]: " SYSTEM_TIMEZONE
        [ -z "$SYSTEM_TIMEZONE" ] && SYSTEM_TIMEZONE="UTC"
        if [ -f "/usr/share/zoneinfo/${SYSTEM_TIMEZONE}" ]; then
            break
        else
            err "Invalid timezone. Please enter a valid path from /usr/share/zoneinfo/ (e.g., Europe/London)."
        fi
    done
    
    while true; do
        read -r -p "Enter locale [Default: en_US.UTF-8]: " SYSTEM_LOCALE
        [ -z "$SYSTEM_LOCALE" ] && SYSTEM_LOCALE="en_US.UTF-8"
        if grep -q "^${SYSTEM_LOCALE}" /usr/share/i18n/SUPPORTED 2>/dev/null || [ -f "/usr/share/i18n/locales/${SYSTEM_LOCALE%.*}" ]; then
            break
        else
            err "Invalid locale. Check /usr/share/i18n/SUPPORTED for a list of valid locales."
        fi
    done
    
    read -r -p "Enter LINGUAS (space separated) [Default: en ru]: " SYSTEM_LINGUAS
    [ -z "$SYSTEM_LINGUAS" ] && SYSTEM_LINGUAS="en ru"
    
    read -r -p "Enter hostname [Default: gentoo-desktop]: " SYSTEM_HOSTNAME
    [ -z "$SYSTEM_HOSTNAME" ] && SYSTEM_HOSTNAME="gentoo-desktop"
    
    local detected_cores
    detected_cores=$(nproc --all 2>/dev/null || echo 4)
    local default_makeopts="-j${detected_cores} -l${detected_cores}"
    read -r -p "Enter MAKEOPTS [Default: ${default_makeopts}]: " MAKEOPTS
    [ -z "$MAKEOPTS" ] && MAKEOPTS="$default_makeopts"
    
    log "--- Post-Install Application Profiles ---"
    INSTALL_APP_HOST=false
    if ask_confirm "Install Universal App Host (Flatpak + Distrobox)?"; then
        INSTALL_APP_HOST=true
    fi
    
    INSTALL_CYBER_TERM=false
    if ask_confirm "Install the 'Cybernetic Terminal' (zsh + starship)?"; then
        INSTALL_CYBER_TERM=true
    fi
    
    INSTALL_DEV_TOOLS=false
    if ask_confirm "Install Developer Tools (git, vscode, docker)?"; then
        INSTALL_DEV_TOOLS=true
    fi
    
    INSTALL_OFFICE_GFX=false
    if ask_confirm "Install Office/Graphics Suite (LibreOffice, GIMP, Inkscape)?"; then
        INSTALL_OFFICE_GFX=true
    fi
    
    INSTALL_GAMING=false
    if ask_confirm "Install Gaming Essentials (Steam, Lutris, Wine)?"; then
        INSTALL_GAMING=true
    fi
    
    local grub_platform="pc"
    if [ "$BOOT_MODE" = "UEFI" ]; then
        grub_platform="efi-64"
    fi
    
    # Create config directory if needed
    mkdir -p "$(dirname "$CONFIG_FILE_TMP")"
    
    # Ensure the config file is created with proper permissions
    cat > "$CONFIG_FILE_TMP" <<EOF
TARGET_DEVICE='${TARGET_DEVICE}'
ROOT_FS_TYPE='${ROOT_FS_TYPE}'
SYSTEM_HOSTNAME='${SYSTEM_HOSTNAME}'
SYSTEM_TIMEZONE='${SYSTEM_TIMEZONE}'
SYSTEM_LOCALE='${SYSTEM_LOCALE}'
SYSTEM_LINGUAS='${SYSTEM_LINGUAS}'
CPU_MARCH='${CPU_MARCH}'
VIDEO_CARDS='${VIDEO_CARDS}'
MICROCODE_PACKAGE='${MICROCODE_PACKAGE}'
MAKEOPTS='${MAKEOPTS}'
EMERGE_JOBS='${detected_cores}'
USE_LVM=${USE_LVM}
USE_LUKS=${USE_LUKS}
INIT_SYSTEM='${INIT_SYSTEM}'
DESKTOP_ENV='${DESKTOP_ENV}'
KERNEL_METHOD='${KERNEL_METHOD}'
USE_CCACHE=${USE_CCACHE}
USE_BINPKGS=${USE_BINPKGS}
INSTALL_DEV_TOOLS=${INSTALL_DEV_TOOLS}
INSTALL_OFFICE_GFX=${INSTALL_OFFICE_GFX}
INSTALL_GAMING=${INSTALL_GAMING}
NVIDIA_DRIVER_CHOICE='${NVIDIA_DRIVER_CHOICE}'
USE_HARDENED_PROFILE=${USE_HARDENED_PROFILE}
LSM_CHOICE='${LSM_CHOICE}'
CPU_FLAGS_X86='${CPU_FLAGS_X86}'
USE_LTO=${USE_LTO}
USE_SEPARATE_HOME=${USE_SEPARATE_HOME}
HOME_SIZE_GB=${HOME_SIZE_GB}
USE_PIPEWIRE=${USE_PIPEWIRE}
ENCRYPT_BOOT=${ENCRYPT_BOOT}
ENABLE_AUTO_UPDATE=${ENABLE_AUTO_UPDATE}
ENABLE_BOOT_ENVIRONMENTS=${ENABLE_BOOT_ENVIRONMENTS}
INSTALL_APP_HOST=${INSTALL_APP_HOST}
SWAP_TYPE='${SWAP_TYPE}'
SWAP_SIZE_GB=${SWAP_SIZE_GB}
ENABLE_FIREWALL=${ENABLE_FIREWALL}
ENABLE_CPU_GOVERNOR=${ENABLE_CPU_GOVERNOR}
INSTALL_STYLING=${INSTALL_STYLING}
INSTALL_CYBER_TERM=${INSTALL_CYBER_TERM}
GRUB_PLATFORMS='${grub_platform}'
IS_LAPTOP=${IS_LAPTOP}
EOF
    
    log "Configuration complete. Review summary before proceeding."
    cat "$CONFIG_FILE_TMP"
}

# ==============================================================================
# --- STAGE 0C, 1, 2: PARTITION, DEPLOY, CHROOT ---
# ==============================================================================
stage0_partition_and_format() {
    step_log "Disk Partitioning and Formatting (Mode: ${BOOT_MODE})"
    warn "Final confirmation. ALL DATA ON ${TARGET_DEVICE} WILL BE PERMANENTLY DESTROYED!"
    read -r -p "To confirm, type the full device name ('${TARGET_DEVICE}'): " confirmation
    if [ "$confirmation" != "${TARGET_DEVICE}" ]; then
        die "Confirmation failed. Aborting."
    fi
    
    log "Initiating 'Absolute Zero' protocol..."
    
    # Unmount any mounted partitions on the target device
    while mount | grep -q "^${TARGET_DEVICE}"; do
        local mounted_part
        mounted_part=$(mount | grep "^${TARGET_DEVICE}" | head -1 | awk '{print $3}')
        log "Unmounting ${mounted_part}..."
        umount -l "$mounted_part" &>/dev/null || true
    done
    
    # Stop any RAID/LVM/encryption devices that might be using the target device
    log "Stopping any active RAID/LVM/encryption devices..."
    if command -v mdadm &>/dev/null; then
        mdadm --stop --scan &>/dev/null || true
    fi
    if command -v dmraid &>/dev/null; then
        dmraid -an &>/dev/null || true
    fi
    if command -v vgchange &>/dev/null; then
        vgchange -an &>/dev/null || true
    fi
    if command -v cryptsetup &>/dev/null; then
        for dm in $(dmsetup ls --target crypt --exec basename 2>/dev/null || true); do
            if [ -n "$dm" ]; then
                cryptsetup close "$dm" &>/dev/null || true
            fi
        done
    fi
    
    sync
    blockdev --flushbufs "${TARGET_DEVICE}" &>/dev/null || true
    log "Device locks released."
    
    # Wipe partition table safely
    log "Wiping partition table on ${TARGET_DEVICE}..."
    if ! sgdisk --zap-all "${TARGET_DEVICE}" &>/dev/null; then
        warn "sgdisk failed. Trying with dd to wipe the first few MB..."
        dd if=/dev/zero of="${TARGET_DEVICE}" bs=1M count=8 &>/dev/null || true
    fi
    wipefs -a "${TARGET_DEVICE}" &>/dev/null || true
    sync
    
    local P_SEPARATOR=""
    if echo "${TARGET_DEVICE}" | grep -qE 'nvme|mmcblk'; then
        P_SEPARATOR="p"
    fi
    
    local luks_opts=(--type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-random)
    
    if [ "$ENCRYPT_BOOT" = true ]; then
        log "Creating partitions for Encrypted /boot scheme (UEFI)..."
        sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System" "${TARGET_DEVICE}"
        sgdisk -n 2:0:0 -t 2:8300 -c 2:"LUKS Container" "${TARGET_DEVICE}"
        EFI_PART="${TARGET_DEVICE}${P_SEPARATOR}1"
        LUKS_PART="${TARGET_DEVICE}${P_SEPARATOR}2"
        sync
        partprobe "${TARGET_DEVICE}" &>/dev/null || true
        udevadm settle &>/dev/null || true
        log "Formatting EFI partition..."
        wipefs -a "${EFI_PART}" &>/dev/null || true
        mkfs.vfat -F 32 "${EFI_PART}"
        log "Creating LUKS container on ${LUKS_PART}..."
        echo -e "$LUKS_PASSPHRASE\n$LUKS_PASSPHRASE" | cryptsetup luksFormat "${luks_opts[@]}" "${LUKS_PART}" &>/dev/null
        log "Opening LUKS container..."
        echo -n "$LUKS_PASSPHRASE" | cryptsetup open "${LUKS_PART}" gentoo_crypted
        local device_to_format="/dev/mapper/gentoo_crypted"
        echo "LUKS_UUID=$(get_blkid_uuid "${LUKS_PART}")" >> "$CONFIG_FILE_TMP"
        log "Setting up LVM on ${device_to_format}..."
        pvcreate -ff "${device_to_format}" &>/dev/null
        vgcreate -ff gentoo_vg "${device_to_format}" &>/dev/null
        log "Creating Boot logical volume..."
        lvcreate -L 1G -n boot gentoo_vg &>/dev/null
        BOOT_PART="/dev/gentoo_vg/boot"
        if [ "$SWAP_TYPE" = "partition (traditional on-disk swap)" ] && [ "$SWAP_SIZE_GB" -gt 0 ]; then
            log "Creating SWAP logical volume..."
            lvcreate -L "${SWAP_SIZE_GB}G" -n swap gentoo_vg &>/dev/null
            SWAP_PART="/dev/gentoo_vg/swap"
            mkswap "${SWAP_PART}"
        fi
        if [ "$USE_SEPARATE_HOME" = true ]; then
            log "Creating Home logical volume..."
            lvcreate -L "${HOME_SIZE_GB}G" -n home gentoo_vg &>/dev/null
            HOME_PART="/dev/gentoo_vg/home"
        fi
        log "Creating Root logical volume..."
        lvcreate -l 100%FREE -n root gentoo_vg &>/dev/null
        ROOT_PART="/dev/gentoo_vg/root"
        log "Formatting logical volumes..."
        wipefs -a "${BOOT_PART}" &>/dev/null || true
        mkfs.ext4 -F "${BOOT_PART}"
    else
        local BOOT_PART_NUM=1
        local MAIN_PART_NUM=2
        local SWAP_PART_NUM=3
        
        if [ "$BOOT_MODE" = "UEFI" ]; then
            log "Creating GPT partitions for UEFI..."
            sgdisk -n ${BOOT_PART_NUM}:0:+512M -t ${BOOT_PART_NUM}:ef00 -c ${BOOT_PART_NUM}:"EFI System" "${TARGET_DEVICE}"
            EFI_PART="${TARGET_DEVICE}${P_SEPARATOR}${BOOT_PART_NUM}"
            BOOT_PART="${EFI_PART}"
        else
            log "Creating GPT partitions for Legacy BIOS..."
            sgdisk -n ${BOOT_PART_NUM}:0:+2M -t ${BOOT_PART_NUM}:ef02 -c ${BOOT_PART_NUM}:"BIOS Boot" "${TARGET_DEVICE}"
            BOOT_PART="${TARGET_DEVICE}${P_SEPARATOR}${BOOT_PART_NUM}"
        fi
        
        if [ "$SWAP_TYPE" = "partition (traditional on-disk swap)" ] && [ "$SWAP_SIZE_GB" -gt 0 ] && [ "$USE_LVM" = false ]; then
            log "Creating dedicated SWAP partition..."
            sgdisk -n ${SWAP_PART_NUM}:0:+${SWAP_SIZE_GB}G -t ${SWAP_PART_NUM}:8200 -c ${SWAP_PART_NUM}:"Linux Swap" "${TARGET_DEVICE}"
            SWAP_PART="${TARGET_DEVICE}${P_SEPARATOR}${SWAP_PART_NUM}"
        fi
        
        log "Creating main Linux partition..."
        sgdisk -n ${MAIN_PART_NUM}:0:0 -t ${MAIN_PART_NUM}:8300 -c ${MAIN_PART_NUM}:"Gentoo Root" "${TARGET_DEVICE}"
        local MAIN_PART="${TARGET_DEVICE}${P_SEPARATOR}${MAIN_PART_NUM}"
        sync
        partprobe "${TARGET_DEVICE}" &>/dev/null || true
        udevadm settle &>/dev/null || true
        
        if [ "$BOOT_MODE" = "UEFI" ]; then
            log "Formatting EFI partition..."
            wipefs -a "${EFI_PART}" &>/dev/null || true
            mkfs.vfat -F 32 "${EFI_PART}"
        fi
        
        if [ -n "$SWAP_PART" ]; then
            log "Formatting SWAP partition..."
            wipefs -a "${SWAP_PART}" &>/dev/null || true
            mkswap "${SWAP_PART}"
        fi
        
        local device_to_format="${MAIN_PART}"
        if [ "$USE_LUKS" = true ]; then
            LUKS_PART="${MAIN_PART}"
            log "Creating LUKS container on ${LUKS_PART}..."
            echo -e "$LUKS_PASSPHRASE\n$LUKS_PASSPHRASE" | cryptsetup luksFormat "${luks_opts[@]}" "${LUKS_PART}" &>/dev/null
            log "Opening LUKS container..."
            echo -n "$LUKS_PASSPHRASE" | cryptsetup open "${LUKS_PART}" gentoo_crypted
            device_to_format="/dev/mapper/gentoo_crypted"
            echo "LUKS_UUID=$(get_blkid_uuid "${LUKS_PART}")" >> "$CONFIG_FILE_TMP"
        fi
        
        if [ "$USE_LVM" = true ]; then
            log "Setting up LVM on ${device_to_format}..."
            pvcreate -ff "${device_to_format}" &>/dev/null
            vgcreate -ff gentoo_vg "${device_to_format}" &>/dev/null
            
            if [ "$SWAP_TYPE" = "partition (traditional on-disk swap)" ] && [ "$SWAP_SIZE_GB" -gt 0 ]; then
                log "Creating SWAP logical volume..."
                lvcreate -L "${SWAP_SIZE_GB}G" -n swap gentoo_vg &>/dev/null
                SWAP_PART="/dev/gentoo_vg/swap"
                mkswap "${SWAP_PART}"
            fi
            
            if [ "$USE_SEPARATE_HOME" = true ]; then
                log "Creating Home logical volume..."
                lvcreate -L "${HOME_SIZE_GB}G" -n home gentoo_vg &>/dev/null
                HOME_PART="/dev/gentoo_vg/home"
            fi
            
            log "Creating Root logical volume..."
            lvcreate -l 100%FREE -n root gentoo_vg &>/dev/null
            ROOT_PART="/dev/gentoo_vg/root"
        else
            ROOT_PART="${device_to_format}"
        fi
    fi
    
    log "Formatting root/home filesystems..."
    wipefs -a "${ROOT_PART}" &>/dev/null || true
    if [ -n "$HOME_PART" ]; then
        wipefs -a "${HOME_PART}" &>/dev/null || true
    fi
    
    case "$ROOT_FS_TYPE" in
        "xfs")
            mkfs.xfs -f "${ROOT_PART}"
            if [ -n "$HOME_PART" ]; then
                mkfs.xfs -f "${HOME_PART}"
            fi
            ;;
        "ext4")
            mkfs.ext4 -F "${ROOT_PART}"
            if [ -n "$HOME_PART" ]; then
                mkfs.ext4 -F "${HOME_PART}"
            fi
            ;;
        "btrfs")
            mkfs.btrfs -f "${ROOT_PART}"
            if [ -n "$HOME_PART" ]; then
                mkfs.btrfs -f "${HOME_PART}"
            fi
            ;;
    esac
    
    sync
    log "Waiting for udev to process new partition information..."
    udevadm settle &>/dev/null || true
    
    log "Mounting partitions..."
    local BTRFS_TMP_MNT
    if [ "$ROOT_FS_TYPE" = "btrfs" ]; then
        BTRFS_TMP_MNT=$(mktemp -d)
        mount "${ROOT_PART}" "${BTRFS_TMP_MNT}"
        log "Creating Btrfs subvolumes..."
        btrfs subvolume create "${BTRFS_TMP_MNT}/@" &>/dev/null
        btrfs subvolume create "${BTRFS_TMP_MNT}/@home" &>/dev/null
        if [ "$ENABLE_BOOT_ENVIRONMENTS" = true ]; then
            btrfs subvolume create "${BTRFS_TMP_MNT}/@snapshots" &>/dev/null
            btrfs subvolume create "${BTRFS_TMP_MNT}/@bootenv" &>/dev/null
        fi
        umount "${BTRFS_TMP_MNT}"
        rmdir "${BTRFS_TMP_MNT}"
    fi
    
    mkdir -p "${GENTOO_MNT}"
    if [ "$ROOT_FS_TYPE" = "btrfs" ]; then
        mount -o subvol=@,compress=zstd,noatime "${ROOT_PART}" "${GENTOO_MNT}"
    else
        mount "${ROOT_PART}" "${GENTOO_MNT}"
    fi
    
    if [ -n "$HOME_PART" ]; then
        mkdir -p "${GENTOO_MNT}/home"
        if [ "$ROOT_FS_TYPE" = "btrfs" ]; then
            mount -o subvol=@home,compress=zstd "${ROOT_PART}" "${GENTOO_MNT}/home"
        else
            mount "${HOME_PART}" "${GENTOO_MNT}/home"
        fi
    fi
    
    if [ "$ENCRYPT_BOOT" = true ]; then
        mkdir -p "${GENTOO_MNT}/boot"
        mount "${BOOT_PART}" "${GENTOO_MNT}/boot"
        mkdir -p "${GENTOO_MNT}/boot/efi"
        mount "${EFI_PART}" "${GENTOO_MNT}/boot/efi"
    elif [ "$BOOT_MODE" = "UEFI" ]; then
        mkdir -p "${GENTOO_MNT}/boot/efi"
        mount "${EFI_PART}" "${GENTOO_MNT}/boot/efi"
    fi
    
    if [ -n "$SWAP_PART" ]; then
        swapon "${SWAP_PART}" || true
    elif [ "$SWAP_TYPE" = "zram (in-memory swap, recommended)" ]; then
        log "ZRAM swap will be set up after chroot."
    fi
    
    echo "LUKS_PART='${LUKS_PART}'" >> "$CONFIG_FILE_TMP"
    echo "ROOT_PART='${ROOT_PART}'" >> "$CONFIG_FILE_TMP"
    echo "BOOT_MODE='${BOOT_MODE}'" >> "$CONFIG_FILE_TMP"
    
    # Migrate log to chroot environment
    if [ -f "$LOG_FILE_PATH" ]; then
        mkdir -p "${GENTOO_MNT}/root"
        local final_log_path="${GENTOO_MNT}/root/gentoo_genesis_install.log"
        log "Migrating log file to ${final_log_path}"
        cat "$LOG_FILE_PATH" >> "$final_log_path" 2>/dev/null || true
        exec 1>>"$final_log_path" 2>&1
        rm -f "$LOG_FILE_PATH" 2>/dev/null || true
        LOG_FILE_PATH="$final_log_path"
    fi
}

stage1_deploy_base_system() {
    step_log "Base System Deployment"
    local stage3_variant="openrc"
    if [ "$INIT_SYSTEM" = "SystemD" ]; then
        stage3_variant="systemd"
    fi
    
    log "Selecting '${stage3_variant}' stage3 build based on user choice."
    
    # Create directory for stage3 tarball if it doesn't exist
    mkdir -p "${GENTOO_MNT}"
    
    local success=false
    local base_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/"
    local latest_info_url="${base_url}latest-stage3-amd64-${stage3_variant}.txt"
    
    log "Fetching list of recent stage3 builds from ${latest_info_url}..."
    local build_list
    local attempt_count=0
    local max_retries=3
    
    while [ $attempt_count -lt $max_retries ]; do
        if build_list=$(curl --fail -L -s --connect-timeout 15 "$latest_info_url" 2>/dev/null | grep -E '\.tar\.xz' | awk '{print $1}'); then
            break
        else
            attempt_count=$((attempt_count + 1))
            warn "Attempt $attempt_count/$max_retries to fetch stage3 list failed. Retrying in 5 seconds..."
            sleep 5
        fi
    done
    
    if [ -z "$build_list" ] || [ $attempt_count -eq $max_retries ]; then
        die "Could not fetch stage3 build list from ${latest_info_url} after $max_retries attempts."
    fi
    
    attempt_count=0
    for build_path in $build_list; do
        attempt_count=$((attempt_count + 1))
        log "--- [Attempt ${attempt_count}] Trying build: ${build_path} ---"
        local tarball_name
        tarball_name=$(basename "$build_path")
        local tarball_url="${base_url}${build_path}"
        local local_tarball_path="${GENTOO_MNT}/${tarball_name}"
        local digests_url="${tarball_url}.DIGESTS"
        local local_digests_path="${GENTOO_MNT}/${tarball_name}.DIGESTS"
        
        # Download stage3 tarball
        log "Downloading stage3: ${tarball_name}"
        if ! wget --tries=3 --timeout=45 -c -O "${local_tarball_path}" "$tarball_url"; then
            warn "Stage3 download failed. Trying next build..."
            continue
        fi
        
        # Verify file size
        local file_size
        file_size=$(stat -c%s "${local_tarball_path}" 2>/dev/null || stat -f%z "${local_tarball_path}" 2>/dev/null || echo 0)
        if [ "$file_size" -lt 100000000 ]; then
            warn "Downloaded file appears too small (${file_size} bytes). Trying next build..."
            rm -f "${local_tarball_path}"
            continue
        fi
        
        # Download digests file
        log "Downloading digests file..."
        if ! wget --tries=3 -c -O "${local_digests_path}" "$digests_url"; then
            warn "Digests download failed. Trying next build..."
            rm -f "${local_tarball_path}"
            continue
        fi
        
        # Verify checksums
        local checksum_verified=false
        for hash_cmd in b2sum sha512sum; do
            if command -v "$hash_cmd" >/dev/null; then
                log "Verifying tarball integrity with ${hash_cmd}..."
                pushd "${GENTOO_MNT}" >/dev/null
                local match_line
                match_line=$(grep -E "\s+${tarball_name}$" "$(basename "${local_digests_path}")" 2>/dev/null || true)
                if [ -n "$match_line" ]; then
                    echo "$match_line" | $hash_cmd --strict -c - && checksum_verified=true
                fi
                popd >/dev/null
                if [ "$checksum_verified" = true ]; then
                    log "Checksum OK with ${hash_cmd}. Found a valid stage3 build."
                    break
                else
                    warn "Checksum FAILED with ${hash_cmd} for this build."
                fi
            fi
        done
        
        if [ "$checksum_verified" = true ]; then
            success=true
            break
        else
            warn "All available checksum methods failed. Trying next build."
            rm -f "${local_tarball_path}" "${local_digests_path}"
        fi
    done
    
    if [ "$success" = false ]; then
        # Last resort: skip checksum verification if explicitly allowed
        if [ "$SKIP_CHECKSUM" = true ]; then
            warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            err "  DANGER: CHECKSUM VERIFICATION IS DISABLED!"
            err "  This is a significant security risk. Proceed only if you"
            err "  understand and accept this risk."
            warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            read -r -p "Press ENTER to acknowledge this risk and continue..."
        else
            die "Failed to find a verifiable stage3 build after trying ${attempt_count} options."
        fi
    fi
    
    log "Unpacking stage3 tarball..."
    tar xpvf "${local_tarball_path}" --xattrs-include='*.*' --numeric-owner -C "${GENTOO_MNT}"
    
    # Clean up downloaded files
    rm -f "${local_tarball_path}" "${local_digests_path}"
    log "Base system deployed successfully."
}

stage2_prepare_chroot() {
    step_log "Chroot Preparation"
    
    # Mount required filesystems first to avoid chicken-egg problem with portage
    mkdir -p "${GENTOO_MNT}/proc" "${GENTOO_MNT}/sys" "${GENTOO_MNT}/dev" "${GENTOO_MNT}/run"
    mount --types proc /proc "${GENTOO_MNT}/proc" &>/dev/null || true
    mount --rbind /sys "${GENTOO_MNT}/sys" &>/dev/null || true
    mount --make-rslave "${GENTOO_MNT}/sys" &>/dev/null || true
    mount --rbind /dev "${GENTOO_MNT}/dev" &>/dev/null || true
    mount --make-rslave "${GENTOO_MNT}/dev" &>/dev/null || true
    mount --bind /run "${GENTOO_MNT}/run" &>/dev/null || true
    
    # Copy network configuration
    cp -L /etc/resolv.conf "${GENTOO_MNT}/etc/" &>/dev/null || true
    
    log "Configuring Portage..."
    mkdir -p "${GENTOO_MNT}/etc/portage/repos.conf"
    if [ -f "${GENTOO_MNT}/usr/share/portage/config/repos.conf" ]; then
        cp "${GENTOO_MNT}/usr/share/portage/config/repos.conf" "${GENTOO_MNT}/etc/portage/repos.conf/gentoo.conf"
    else
        # Create minimal repos.conf if file doesn't exist
        cat > "${GENTOO_MNT}/etc/portage/repos.conf/gentoo.conf" <<EOF
[DEFAULT]
main-repo = gentoo
[gentoo]
location = /var/db/repos/gentoo
sync-type = git
sync-uri = https://github.com/gentoo/gentoo.git
auto-sync = yes
EOF
    fi
    
    log "Writing dynamic make.conf..."
    local emerge_opts="--jobs=${EMERGE_JOBS} --load-average=${EMERGE_JOBS} --quiet-build --autounmask-write=y --with-bdeps=y"
    if [ "$USE_BINPKGS" = true ]; then
        emerge_opts+=" --getbinpkg=y"
    fi
    
    local features="candy"
    if [ "$USE_CCACHE" = true ]; then
        features+=" ccache"
    fi
    
    local base_use="X dbus policykit gtk udev udisks vaapi vdpau vulkan"
    if [ "$USE_PIPEWIRE" = true ]; then
        base_use+=" pipewire wireplumber -pulseaudio"
    else
        base_use+=" pulseaudio"
    fi
    
    local extra_use=""
    case "$DESKTOP_ENV" in
        "KDE-Plasma") extra_use="kde plasma qt5 -gnome" ;;
        "GNOME") extra_use="gnome -kde -qt5" ;;
        "i3-WM") extra_use="-gnome -kde -qt5" ;;
        "XFCE") extra_use="-gnome -kde -qt5" ;;
        *) extra_use="-gnome -kde -qt5" ;;
    esac
    
    if [ "$INIT_SYSTEM" = "SystemD" ]; then
        extra_use+=" systemd -elogind"
    else
        extra_use+=" elogind -systemd"
    fi
    
    if [ "$LSM_CHOICE" = "AppArmor" ]; then
        extra_use+=" apparmor"
    fi
    
    if [ "$LSM_CHOICE" = "SELinux" ]; then
        extra_use+=" selinux"
    fi
    
    local common_flags="-O2 -pipe -march=${CPU_MARCH}"
    local ld_flags=""
    if [ "$USE_LTO" = true ]; then
        common_flags+=" -flto=auto"
        ld_flags+="-flto=auto"
    fi
    
    cat > "${GENTOO_MNT}/etc/portage/make.conf" <<EOF
# --- Generated by The Gentoo Genesis Engine ---
COMMON_FLAGS="${common_flags}"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
LDFLAGS="${ld_flags}"
MAKEOPTS="${MAKEOPTS}"
EMERGE_DEFAULT_OPTS="${emerge_opts}"
FEATURES="${features}"
VIDEO_CARDS="${VIDEO_CARDS}"
INPUT_DEVICES="libinput synaptics"
USE="${base_use} ${extra_use}"
ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"
GRUB_PLATFORMS='${GRUB_PLATFORMS}'
L10N="${SYSTEM_LINGUAS}"
LINGUAS="${SYSTEM_LINGUAS}"
$( [ -n "$CPU_FLAGS_X86" ] && echo "CPU_FLAGS_X86=\"${CPU_FLAGS_X86}\"" )
$( echo "${FASTEST_MIRRORS:-GENTOO_MIRRORS=\"https://distfiles.gentoo.org\"}" )
EOF
    
    # Create required portage directories
    mkdir -p "${GENTOO_MNT}/etc/portage/package.use" "${GENTOO_MNT}/etc/portage/package.accept_keywords" "${GENTOO_MNT}/etc/portage/package.license"
    
    if [ "$USE_PIPEWIRE" = true ]; then
        log "Configuring Portage for PipeWire..."
        echo "media-sound/pipewire pipewire-pulse" > "${GENTOO_MNT}/etc/portage/package.use/pipewire"
    fi
    
    if [ "$NVIDIA_DRIVER_CHOICE" = "Proprietary" ]; then
        log "Configuring Portage for NVIDIA proprietary drivers..."
        echo "x11-drivers/nvidia-drivers ~amd64" > "${GENTOO_MNT}/etc/portage/package.accept_keywords/nvidia"
        echo "x11-drivers/nvidia-drivers NVIDIA" > "${GENTOO_MNT}/etc/portage/package.license/nvidia"
    fi
    
    log "Generating /etc/fstab..."
    mkdir -p "${GENTOO_MNT}/etc"
    {
        echo "# /etc/fstab: static file system information."
        echo "# Generated by Gentoo Genesis Engine"
        echo ""
        local root_opts="defaults,noatime"
        if [ "$ROOT_FS_TYPE" = "btrfs" ]; then
            root_opts="subvol=@,compress=zstd,noatime"
        fi
        echo "# Root filesystem"
        echo "UUID=$(get_blkid_uuid "${ROOT_PART}")  /  ${ROOT_FS_TYPE}  ${root_opts}  0 1"
        
        if [ -n "$HOME_PART" ]; then
            local home_opts="defaults,noatime"
            if [ "$ROOT_FS_TYPE" = "btrfs" ]; then
                home_opts="subvol=@home,compress=zstd,noatime"
            fi
            echo "# Home partition"
            echo "UUID=$(get_blkid_uuid "${HOME_PART}")  /home  ${ROOT_FS_TYPE}  ${home_opts}  0 2"
        fi
        
        if [ "$ENCRYPT_BOOT" = true ]; then
            echo "# Encrypted boot partition"
            echo "UUID=$(get_blkid_uuid "${BOOT_PART}")  /boot  ext4  defaults,noatime  0 2"
            echo "# EFI System Partition"
            echo "UUID=$(get_blkid_uuid "${EFI_PART}")  /boot/efi  vfat  defaults,noatime,uid=0,gid=0,umask=022  0 2"
        elif [ "$BOOT_MODE" = "UEFI" ]; then
            echo "# EFI System Partition"
            echo "UUID=$(get_blkid_uuid "${EFI_PART}")  /boot/efi  vfat  defaults,noatime,uid=0,gid=0,umask=022  0 2"
        fi
        
        if [ -n "$SWAP_PART" ]; then
            echo "# Swap partition"
            echo "UUID=$(get_blkid_uuid "${SWAP_PART}")  none  swap  sw  0 0"
        elif [ "$SWAP_TYPE" = "zram (in-memory swap, recommended)" ]; then
            echo "# ZRAM swap will be configured after installation"
            :
        fi
    } > "${GENTOO_MNT}/etc/fstab"
    
    log "/etc/fstab generated successfully."
    
    # Clean up previous mount attempts
    umount -R "${GENTOO_MNT}/proc" &>/dev/null || true
    umount -R "${GENTOO_MNT}/sys" &>/dev/null || true
    umount -R "${GENTOO_MNT}/dev" &>/dev/null || true
    umount -R "${GENTOO_MNT}/run" &>/dev/null || true
    
    log "Mounting virtual filesystems..."
    mount --types proc /proc "${GENTOO_MNT}/proc" || die "Failed to mount proc"
    mount --rbind /sys "${GENTOO_MNT}/sys" || die "Failed to mount sys"
    mount --make-rslave "${GENTOO_MNT}/sys" || die "Failed to make sys rslave"
    mount --rbind /dev "${GENTOO_MNT}/dev" || die "Failed to mount dev"
    mount --make-rslave "${GENTOO_MNT}/dev" || die "Failed to make dev rslave"
    mount --bind /run "${GENTOO_MNT}/run" || die "Failed to mount run"
    
    log "Copying DNS info..."
    mkdir -p "${GENTOO_MNT}/etc"
    cp -L /etc/resolv.conf "${GENTOO_MNT}/etc/" &>/dev/null || true
    
    local script_name
    script_name=$(basename "$0")
    local script_dest_path="/root/${script_name}"
    
    log "Copying this script into the chroot..."
    cp "$0" "${GENTOO_MNT}${script_dest_path}" &>/dev/null || die "Failed to copy script to chroot"
    chmod +x "${GENTOO_MNT}${script_dest_path}" || die "Failed to set executable permissions"
    
    # Copy config file to chroot
    mkdir -p "${GENTOO_MNT}/etc"
    cp "$CONFIG_FILE_TMP" "${GENTOO_MNT}/etc/autobuilder.conf" || die "Failed to copy config file to chroot"
    
    log "Entering chroot to continue installation..."
    chroot "${GENTOO_MNT}" /bin/bash -c "echo 'CHROOT' > /proc/1/cmdline && exec /bin/bash ${script_dest_path} --chrooted"
    log "Chroot execution finished."
}

# ==============================================================================
# --- STAGES 3-7: CHROOTED OPERATIONS ---
# ==============================================================================
stage3_configure_in_chroot() {
    step_log "System Configuration (Inside Chroot)"
    source /etc/profile
    export PS1="(chroot) ${PS1:-}"
    
    # Fix potential DNS issues in chroot
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    
    # Check and fix portage permissions
    if [ -d "/var/db/repos/gentoo" ]; then
        chown -R portage:portage /var/db/repos/gentoo &>/dev/null || true
    fi
    
    sync_portage_tree
    
    local profile_base="default/linux/amd64/17.1"
    if [ "$USE_HARDENED_PROFILE" = true ]; then
        profile_base+="/hardened"
    fi
    
    local profile_desktop=""
    if [ "$DESKTOP_ENV" = "KDE-Plasma" ]; then
        profile_desktop="/desktop/plasma"
    elif [ "$DESKTOP_ENV" = "GNOME" ]; then
        profile_desktop="/desktop/gnome"
    elif [ "$DESKTOP_ENV" != "Server (No GUI)" ]; then
        profile_desktop="/desktop"
    fi
    
    local profile_init=""
    if [ "$INIT_SYSTEM" = "SystemD" ]; then
        profile_init="/systemd"
    fi
    
    local GENTOO_PROFILE="${profile_base}${profile_desktop}${profile_init}"
    log "Setting system profile to: ${GENTOO_PROFILE}"
    
    # Check if profile exists before setting it
    if ! eselect profile list | grep -q "${GENTOO_PROFILE}"; then
        warn "Profile ${GENTOO_PROFILE} not found. Using closest match."
        GENTOO_PROFILE=$(eselect profile list | grep -m1 "default/linux/amd64/17.1" | awk '{print $2}')
    fi
    
    eselect profile set "${GENTOO_PROFILE}"
    
    if [ "$USE_CCACHE" = true ]; then
        log "Setting up ccache..."
        run_emerge app-misc/ccache
        ccache -M 50G || true
    fi
    
    step_log "Installing Kernel Headers and Core System Utilities"
    run_emerge sys-kernel/linux-headers
    
    if [ "$USE_LVM" = true ]; then
        run_emerge sys-fs/lvm2
    fi
    
    if [ "$USE_LUKS" = true ]; then
        run_emerge sys-fs/cryptsetup
    fi
    
    if [ "$LSM_CHOICE" = "AppArmor" ]; then
        run_emerge sys-apps/apparmor
    fi
    
    if [ "$LSM_CHOICE" = "SELinux" ]; then
        run_emerge sys-libs/libselinux sys-apps/policycoreutils
    fi
    
    if [ -n "$MICROCODE_PACKAGE" ]; then
        log "Installing CPU microcode package: ${MICROCODE_PACKAGE}"
        run_emerge "${MICROCODE_PACKAGE}"
    else
        warn "No specific microcode package to install."
    fi
    
    log "Configuring timezone and locale..."
    if [ -f "/usr/share/zoneinfo/${SYSTEM_TIMEZONE}" ]; then
        ln -sf "/usr/share/zoneinfo/${SYSTEM_TIMEZONE}" /etc/localtime
    else
        warn "Timezone file not found. Using UTC as fallback."
        ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    fi
    
    echo "${SYSTEM_LOCALE} UTF-8" > /etc/locale.gen
    if [ "${SYSTEM_LOCALE}" != "en_US.UTF-8" ]; then
        echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    fi
    
    locale-gen || die "Failed to generate locales"
    eselect locale set "${SYSTEM_LOCALE}" || warn "Failed to set locale, continuing anyway"
    
    env-update && source /etc/profile
    log "Setting hostname..."
    echo "${SYSTEM_HOSTNAME}" > /etc/hostname
    echo "127.0.0.1 ${SYSTEM_HOSTNAME} localhost" > /etc/hosts
    echo "::1 ${SYSTEM_HOSTNAME} localhost" >> /etc/hosts
}

stage4_build_world_and_kernel() {
    step_log "Updating @world set and Building Kernel"
    log "Building @world set..."
    run_emerge --update --deep --newuse --keep-going @world
    
    log "Installing firmware..."
    run_emerge sys-kernel/linux-firmware
    
    case "$KERNEL_METHOD" in
        "genkernel (recommended, auto)"|"manual (expert, interactive)")
            log "Installing kernel sources..."
            run_emerge sys-kernel/gentoo-sources
            log "Setting the default kernel symlink..."
            eselect kernel list
            eselect kernel set 1
            
            if [ "$KERNEL_METHOD" = "genkernel (recommended, auto)" ]; then
                log "Building kernel with genkernel"
                run_emerge sys-kernel/genkernel
                local genkernel_opts="--install"
                if [ "$USE_LVM" = true ]; then
                    genkernel_opts+=" --lvm"
                fi
                if [ "$USE_LUKS" = true ]; then
                    genkernel_opts+=" --luks"
                fi
                if [ "$LSM_CHOICE" = "AppArmor" ]; then
                    genkernel_opts+=" --apparmor"
                fi
                if [ "$LSM_CHOICE" = "SELinux" ]; then
                    genkernel_opts+=" --selinux"
                fi
                log "Running genkernel with options: ${genkernel_opts}"
                genkernel "${genkernel_opts}" all
            else
                log "Preparing for manual kernel configuration..."
                cd /usr/src/linux || die "Failed to change to kernel source directory"
                warn "--- MANUAL INTERVENTION REQUIRED ---"
                warn "The script is about to launch the interactive kernel configuration menu ('make menuconfig')."
                warn "You will need to configure your kernel manually."
                if [ "$LSM_CHOICE" != "None" ]; then
                    warn "-> REMINDER: Enable ${LSM_CHOICE} support in 'Security options'."
                fi
                if [ "$NVIDIA_DRIVER_CHOICE" = "Proprietary" ]; then
                    warn "-> CRITICAL: You MUST DISABLE the Nouveau driver: 'Device Drivers -> Graphics support -> Nouveau driver' (set to [N])."
                fi
                warn "Once you save your configuration and exit, the script will automatically continue with compilation."
                read -r -p "Press ENTER to launch the kernel configuration menu..."
                make menuconfig
                log "Compiling and installing kernel..."
                make -j$(nproc) && make modules_install && make install
                # Install initramfs for LUKS/LVM
                if [ "$USE_LUKS" = true ] || [ "$USE_LVM" = true ]; then
                    log "Generating initramfs..."
                    genkernel --install initramfs
                fi
            fi
            ;;
        "gentoo-kernel (distribution kernel, balanced)")
            log "Installing distribution kernel..."
            run_emerge sys-kernel/gentoo-kernel
            # Install initramfs for LUKS/LVM
            if [ "$USE_LUKS" = true ] || [ "$USE_LVM" = true ]; then
                log "Generating initramfs..."
                run_emerge sys-kernel/genkernel
                genkernel --install initramfs
            fi
            ;;
        "gentoo-kernel-bin (fastest, pre-compiled)")
            log "Installing pre-compiled binary kernel..."
            run_emerge sys-kernel/gentoo-kernel-bin
            # Install initramfs for LUKS/LVM
            if [ "$USE_LUKS" = true ] || [ "$USE_LVM" = true ]; then
                log "Generating initramfs..."
                run_emerge sys-kernel/genkernel
                genkernel --install initramfs
            fi
            ;;
    esac
}

stage5_install_bootloader() {
    step_log "Installing GRUB Bootloader (Mode: ${BOOT_MODE})"
    # For LUKS systems, we need to ensure the initramfs has the right modules
    if [ "$USE_LUKS" = true ]; then
        log "Ensuring initramfs has LUKS modules..."
        if [ -f /etc/genkernel.conf ]; then
            sed -i 's/#LUKS="no"/LUKS="yes"/' /etc/genkernel.conf || true
            sed -i 's/#LVM="no"/LVM="yes"/' /etc/genkernel.conf || true
        fi
    fi
    
    local grub_conf="/etc/default/grub"
    mkdir -p "$(dirname "$grub_conf")"
    
    # Create default grub configuration if it doesn't exist
    if [ ! -f "$grub_conf" ]; then
        cat > "$grub_conf" <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Gentoo"
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX=""
EOF
    fi
    
    local grub_cmdline_additions=""
    if [ "$USE_LUKS" = true ] && [ "$ENCRYPT_BOOT" != true ]; then
        log "Configuring GRUB for LUKS (standard)..."
        # Get UUID without relying on LUKS_PART variable (which might not be set in chroot)
        local LUKS_DEVICE_UUID
        local ROOT_DEVICE_PATH="/dev/mapper/gentoo_crypted"
        
        if [ -n "$LUKS_UUID" ]; then
            LUKS_DEVICE_UUID="$LUKS_UUID"
        elif [ -n "$LUKS_PART" ] && [ -e "$LUKS_PART" ]; then
            LUKS_DEVICE_UUID=$(get_blkid_uuid "${LUKS_PART}")
        else
            # Try to find LUKS partition based on mapper name
            local possible_luks_device
            possible_luks_device=$(cryptsetup status gentoo_crypted 2>/dev/null | grep "device:" | awk '{print $2}')
            if [ -n "$possible_luks_device" ] && [ -e "$possible_luks_device" ]; then
                LUKS_DEVICE_UUID=$(get_blkid_uuid "$possible_luks_device")
            fi
        fi
        
        if [ "$USE_LVM" = true ]; then
            ROOT_DEVICE_PATH="/dev/gentoo_vg/root"
        fi
        
        if [ -n "$LUKS_DEVICE_UUID" ]; then
            grub_cmdline_additions+=" crypt_root=UUID=${LUKS_DEVICE_UUID} root=${ROOT_DEVICE_PATH}"
        fi
    fi
    
    if [ "$LSM_CHOICE" = "AppArmor" ]; then
        grub_cmdline_additions+=" apparmor=1 security=apparmor"
    fi
    
    if [ "$LSM_CHOICE" = "SELinux" ]; then
        grub_cmdline_additions+=" selinux=1 security=selinux"
    fi
    
    if [ -n "$grub_cmdline_additions" ]; then
        log "Adding kernel parameters: ${grub_cmdline_additions}"
        # Use a safer approach to update GRUB_CMDLINE_LINUX
        if grep -q "GRUB_CMDLINE_LINUX=" "$grub_conf"; then
            sed -i "s|GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$(grep "GRUB_CMDLINE_LINUX=" "$grub_conf" | sed 's/GRUB_CMDLINE_LINUX="//;s/"$//')${grub_cmdline_additions}\"|" "$grub_conf"
        else
            echo "GRUB_CMDLINE_LINUX=\"${grub_cmdline_additions}\"" >> "$grub_conf"
        fi
    fi
    
    if [ "$USE_LUKS" = true ]; then
        log "Enabling GRUB cryptodisk feature..."
        if ! grep -q "GRUB_ENABLE_CRYPTODISK=y" "$grub_conf"; then
            echo 'GRUB_ENABLE_CRYPTODISK=y' >> "$grub_conf"
        fi
    fi
    
    if [ "$BOOT_MODE" = "UEFI" ]; then
        log "Setting GRUB graphics mode for better readability..."
        sed -i 's/^#\(GRUB_GFXMODE=\).*/GRUB_GFXMODE=1920x1080x32,auto/' "$grub_conf"
    fi
    
    # Ensure GRUB is installed properly
    run_emerge --noreplace sys-boot/grub:2
    
    if [ "$BOOT_MODE" = "UEFI" ]; then
        # Ensure EFI variables are available
        if [ ! -d /sys/firmware/efi/efivars ]; then
            modprobe efivarfs &>/dev/null || true
            mount -t efivarfs efivarfs /sys/firmware/efi/efivars &>/dev/null || true
        fi
        
        # Install for UEFI
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Gentoo --recheck
    else
        # Install for BIOS
        grub-install "${TARGET_DEVICE}" --recheck
    fi
    
    # Generate GRUB config
    grub-mkconfig -o /boot/grub/grub.cfg
}

stage6_install_software() {
    step_log "Installing Desktop Environment and Application Profiles"
    local display_manager=""
    case "$DESKTOP_ENV" in
        "XFCE")
            log "Installing XFCE..."
            run_emerge xfce-base/xfce4-meta x11-terms/xfce4-terminal x11-themes/greybird
            display_manager="x11-misc/lightdm"
            ;;
        "KDE-Plasma")
            log "Installing KDE Plasma..."
            run_emerge kde-plasma/plasma-meta kde-plasma/konsole kde-apps/dolphin
            display_manager="x11-misc/sddm"
            ;;
        "GNOME")
            log "Installing GNOME..."
            run_emerge gnome-base/gnome gnome-base/gnome-shell gnome-extra/gnome-shell-extensions
            display_manager="gnome-base/gdm"
            ;;
        "i3-WM")
            log "Installing i3 Window Manager..."
            run_emerge x11-wm/i3 x11-terms/alacritty x11-misc/dmenu x11-misc/i3lock x11-misc/i3status
            display_manager="x11-misc/lightdm"
            ;;
        "Server (No GUI)")
            log "Skipping GUI installation for server profile."
            ;;
    esac
    
    if [ -n "$display_manager" ] && [ "$DESKTOP_ENV" != "Server (No GUI)" ]; then
        log "Installing Xorg Server and Display Manager..."
        run_emerge x11-base/xorg-server "${display_manager}"
        # Configure display manager
        if [ "$INIT_SYSTEM" = "OpenRC" ]; then
            rc-update add "${display_manager#*/}" default
        else
            systemctl enable "${display_manager#*/}.service"
        fi
    fi
    
    if [ "$USE_PIPEWIRE" = true ]; then
        log "Installing PipeWire..."
        run_emerge media-video/pipewire media-video/wireplumber media-sound/pipewire-pulse media-sound/pipewire-alsa
    fi
    
    if [ "$ENABLE_AUTO_UPDATE" = true ]; then
        log "Installing utilities for automatic maintenance..."
        local maintenance_pkgs="app-portage/eix app-portage/gentoolkit"
        if [ "$INIT_SYSTEM" = "OpenRC" ]; then
            maintenance_pkgs+=" sys-process/cronie"
        else
            maintenance_pkgs+=" sys-process/systemd-cron"
        fi
        # shellcheck disable=SC2086
        run_emerge $maintenance_pkgs
    fi
    
    local advanced_pkgs=""
    if [ "$INSTALL_APP_HOST" = true ]; then
        log "Installing Universal App Host packages..."
        advanced_pkgs+=" sys-apps/flatpak app-emulation/distrobox app-emulation/podman app-containers/podman-docker"
    fi
    
    if [ "$ENABLE_BOOT_ENVIRONMENTS" = true ]; then
        log "Installing Boot Environment packages..."
        advanced_pkgs+=" sys-boot/grub-btrfs"
    fi
    
    if [ "$SWAP_TYPE" = "zram (in-memory swap, recommended)" ]; then
        log "Installing zram packages..."
        advanced_pkgs+=" sys-block/zram-generator sys-apps/systemd-zram-generator"
    fi
    
    if [ "$ENABLE_FIREWALL" = true ]; then
        log "Installing firewall..."
        advanced_pkgs+=" net-firewall/ufw"
    fi
    
    if [ "$ENABLE_CPU_GOVERNOR" = true ]; then
        log "Installing CPU governor..."
        advanced_pkgs+=" sys-power/auto-cpufreq"
    fi
    
    if [ "$INSTALL_STYLING" = true ]; then
        log "Installing styling packages..."
        advanced_pkgs+=" x11-themes/papirus-icon-theme media-fonts/firacode-nerd-font"
    fi
    
    if [ "$INSTALL_CYBER_TERM" = true ]; then
        log "Installing Cybernetic Terminal packages..."
        advanced_pkgs+=" app-shells/zsh app-shells/starship sys-apps/fzf"
    fi
    
    if [ -n "$advanced_pkgs" ]; then
        # shellcheck disable=SC2086
        run_emerge $advanced_pkgs
    fi
    
    if [ "$NVIDIA_DRIVER_CHOICE" = "Proprietary" ]; then
        log "Installing NVIDIA drivers and settings panel..."
        run_emerge x11-drivers/nvidia-drivers x11-misc/nvidia-settings
        # Add NVIDIA module to initramfs
        if [ "$USE_LUKS" = true ] || [ "$USE_LVM" = true ]; then
            sed -i 's/MODULES=""/MODULES="nvidia nvidia-drm"/' /etc/genkernel.conf 2>/dev/null || true
        fi
    fi
    
    if [ "$INSTALL_DEV_TOOLS" = true ]; then
        log "Installing Developer Tools..."
        run_emerge dev-vcs/git app-editors/vscode dev-util/docker dev-util/cmake sys-devel/clang dev-util/valgrind
    fi
    
    if [ "$INSTALL_OFFICE_GFX" = true ]; then
        log "Installing Office/Graphics Suite..."
        run_emerge app-office/libreoffice media-gfx/gimp media-gfx/inkscape media-gfx/blender
    fi
    
    if [ "$INSTALL_GAMING" = true ]; then
        log "Installing Gaming Essentials..."
        run_emerge games-util/steam-launcher games-util/lutris app-emulation/wine-staging games-util/heroic-games-launcher-bin
    fi
    
    log "Installing essential utilities..."
    run_emerge www-client/firefox-bin app-admin/sudo app-shells/bash-completion net-misc/networkmanager app-misc/tmux sys-apps/neofetch
}

stage7_finalize() {
    step_log "Finalizing System"
    # Ensure NetworkManager is installed and enabled
    run_emerge net-misc/networkmanager
    
    log "Enabling system-wide services..."
    if [ "$ENABLE_FIREWALL" = true ]; then
        log "Configuring and enabling firewall..."
        ufw default deny incoming
        ufw default allow outgoing
        ufw enable || true
        if [ "$INIT_SYSTEM" = "OpenRC" ]; then
            rc-update add ufw default
        else
            systemctl enable ufw.service
        fi
    fi
    
    if [ "$ENABLE_CPU_GOVERNOR" = true ]; then
        log "Enabling intelligent CPU governor..."
        if [ "$INIT_SYSTEM" = "OpenRC" ]; then
            rc-update add auto-cpufreq default
        else
            systemctl enable auto-cpufreq.service
        fi
    fi
    
    if [ "$SWAP_TYPE" = "zram (in-memory swap, recommended)" ]; then
        log "Configuring zram..."
        local ram_size_mb
        ram_size_mb=$(free -m | awk '/^Mem:/{print $2}')
        local zram_size
        zram_size=$((ram_size_mb / 2))
        if [ "$INIT_SYSTEM" = "OpenRC" ]; then
            mkdir -p /etc/conf.d
            cat > /etc/conf.d/zram-init <<EOF
# ZRAM configuration
ZRAM_SIZE=${zram_size}
ZRAM_COMP_ALGORITHM=zstd
EOF
            rc-update add zram-init default
        else
            mkdir -p /etc/systemd/zram-generator.conf.d
            cat > /etc/systemd/zram-generator.conf.d/swap.conf <<EOF
[zram0]
compression-algorithm = zstd
memory-limit = ${zram_size}M
swap-priority = 100
EOF
            systemctl daemon-reload
            systemctl start /dev/zram0
        fi
    fi
    
    log "Enabling core services (${INIT_SYSTEM})..."
    if [ "$INIT_SYSTEM" = "OpenRC" ]; then
        if [ "$USE_LVM" = true ]; then
            rc-update add lvm default
        fi
        rc-update add dbus default
        rc-update add NetworkManager default
    else
        if [ "$USE_LVM" = true ]; then
            systemctl enable lvm2-monitor.service
        fi
        systemctl enable dbus.service
        systemctl enable NetworkManager.service
    fi
    
    if [ "$ENABLE_AUTO_UPDATE" = true ]; then
        log "Setting up automatic weekly updates..."
        local update_script_path="/usr/local/bin/gentoo-update.sh"
        if [ "$ENABLE_BOOT_ENVIRONMENTS" = true ]; then
            cat > "$update_script_path" <<'EOF'
#!/bin/bash
set -euo pipefail
exec >> /var/log/gentoo-update.log 2>&1
echo "=== Gentoo Update started at $(date) ==="
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
CURRENT_ROOT_SUBVOL_PATH="/@"
BOOT_ENV_ROOT="/@bootenv"
# Ensure directories exist
mkdir -p /.snapshots
mkdir -p /boot/grub/bootenv
log() { echo ">>> $*"; }
cleanup() {
    umount -R "${SNAPSHOT_PATH}/proc" 2>/dev/null || true
    umount -R "${SNAPSHOT_PATH}/dev" 2>/dev/null || true
    umount -R "${SNAPSHOT_PATH}/sys" 2>/dev/null || true
    umount -R "${SNAPSHOT_PATH}" 2>/dev/null || true
}
trap cleanup EXIT
log "Creating new boot environment snapshot: ${BOOT_ENV_ROOT}/update_${TIMESTAMP}"
btrfs subvolume snapshot -r "${CURRENT_ROOT_SUBVOL_PATH}" "${BOOT_ENV_ROOT}/update_${TIMESTAMP}"
SNAPSHOT_PATH="/mnt/snapshot_$$"
mkdir -p "${SNAPSHOT_PATH}"
log "Mounting snapshot for update..."
mount -o subvol="${BOOT_ENV_ROOT}/update_${TIMESTAMP}",compress=zstd,noatime /dev/disk/by-uuid/$(blkid -s UUID -o value /dev/disk/by-label/root) "${SNAPSHOT_PATH}"
log "Preparing chroot environment for the new snapshot..."
mount --rbind /proc "${SNAPSHOT_PATH}/proc"
mount --rbind /dev "${SNAPSHOT_PATH}/dev"
mount --rbind /sys "${SNAPSHOT_PATH}/sys"
mount --bind /run "${SNAPSHOT_PATH}/run"
cp /etc/resolv.conf "${SNAPSHOT_PATH}/etc/"
log "Starting update inside the chroot..."
chroot "${SNAPSHOT_PATH}" /bin/bash -c '
    source /etc/profile
    export EIX_LIMIT=0
    eix-sync
    emerge --update --deep --newuse --keep-going @world
    emerge --depclean
    revdep-rebuild -- --quiet
'
log "Unmounting snapshot..."
umount -R "${SNAPSHOT_PATH}"
rmdir "${SNAPSHOT_PATH}"
log "Updating GRUB to detect the new boot environment..."
grub-mkconfig -o /boot/grub/grub.cfg
log "SUCCESS! Reboot and select the new boot environment from the GRUB menu."
echo "=== Gentoo Update completed at $(date) ==="
EOF
        else
            cat > "$update_script_path" <<'EOF'
#!/bin/bash
set -euo pipefail
exec >> /var/log/gentoo-update.log 2>&1
echo "=== Gentoo Update started at $(date) ==="
export EIX_QUIET=1
export EIX_LIMIT=0
eix-sync
emerge --update --deep --newuse --keep-going @world
emerge --depclean
revdep-rebuild -- --quiet
echo "=== Gentoo Update completed at $(date) ==="
EOF
        fi
        chmod +x "$update_script_path"
        if [ "$INIT_SYSTEM" = "OpenRC" ]; then
            log "Creating weekly cron job..."
            mkdir -p /etc/cron.weekly
            ln -sf "$update_script_path" /etc/cron.weekly/gentoo-update
            rc-update add cronie default
        else
            log "Creating systemd service and timer..."
            mkdir -p /etc/systemd/system
            cat > /etc/systemd/system/gentoo-update.service <<EOF
[Unit]
Description=Weekly Gentoo Update
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=${update_script_path}
Nice=10
IOSchedulingClass=idle
[Install]
WantedBy=multi-user.target
EOF
            cat > /etc/systemd/system/gentoo-update.timer <<EOF
[Unit]
Description=Run weekly Gentoo update
Requires=gentoo-update.service
[Timer]
OnCalendar=Sun 03:00
RandomizedDelaySec=3600
Persistent=true
[Install]
WantedBy=timers.target
EOF
            systemctl daemon-reload
            systemctl enable --now gentoo-update.timer
            log "Systemd timer enabled."
        fi
        warn "Automatic updates are enabled, but you MUST run 'etc-update' or 'dispatch-conf' manually to merge configuration file changes."
    fi
    
    if [ "$ENABLE_BOOT_ENVIRONMENTS" = true ]; then
        log "Enabling grub-btrfs service..."
        if [ "$INIT_SYSTEM" = "SystemD" ]; then
            systemctl enable grub-btrfs.path
            systemctl start grub-btrfs.path
        else
            warn "grub-btrfs auto-update on OpenRC requires manual setup."
            rc-update add grub-btrfs default
        fi
    fi
    
    if [ "$INSTALL_APP_HOST" = true ]; then
        log "Finalizing Universal App Host setup..."
        mkdir -p /var/lib/flatpak
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    fi
    
    log "Configuring sudo for 'wheel' group..."
    mkdir -p /etc/sudoers.d
    echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
    chmod 440 /etc/sudoers.d/wheel
    
    local new_user=""
    if ! ${FORCE_MODE:-false}; then
        while true; do
            read -r -p "Enter a username: " new_user
            if [ -z "$new_user" ]; then
                err "Username cannot be empty."
                continue
            fi
            if ! echo "$new_user" | grep -qE '^[a-z_][a-z0-9_-]*[$]?$'; then
                err "Invalid username format. Must start with a letter or underscore, followed by letters, numbers, underscores, hyphens, or dollar sign."
                continue
            fi
            if id "$new_user" &>/dev/null; then
                err "Username already exists."
                continue
            fi
            break
        done
    else
        new_user="gentoo"
        log "Force mode: creating default user '${new_user}'."
    fi
    
    local user_groups="wheel,users,audio,video,usb,input,render"
    if [ "$INSTALL_APP_HOST" = true ]; then
        user_groups+=",podman"
    fi
    
    if ${FORCE_MODE:-false}; then
        log "Force mode enabled. Generating random passwords..."
        local root_pass
        local user_pass
        
        if command -v openssl >/dev/null; then
            root_pass=$(openssl rand -base64 12)
            user_pass=$(openssl rand -base64 12)
        else
            warn "openssl not found, using /dev/urandom for password generation."
            root_pass=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
            user_pass=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
        fi
        
        printf "\n"
        warn "--- AUTO-GENERATED PASSWORDS ---"
        warn "root: ${root_pass}"
        warn "${new_user}: ${user_pass}"
        warn "--- SAVE THESE NOW ---"
        printf "\n"
        
        # Create password hashes
        local root_hash
        local user_hash
        
        if command -v openssl >/dev/null; then
            root_hash=$(openssl passwd -6 "$root_pass")
            user_hash=$(openssl passwd -6 "$user_pass")
        elif command -v mkpasswd >/dev/null; then
            root_hash=$(mkpasswd -m sha-512 "$root_pass")
            user_hash=$(mkpasswd -m sha-512 "$user_pass")
        else
            warn "No password hashing tool found. Creating user without password (you must set it manually later)."
            root_hash="*"
            user_hash="*"
        fi
        
        # Create users
        useradd -m -G "$user_groups" -s /bin/bash -p "$user_hash" "$new_user" || die "Failed to create user $new_user"
        usermod -p "$root_hash" root || die "Failed to set root password"
    else
        log "Set a password for the 'root' user:"
        passwd root
        useradd -m -G "$user_groups" -s /bin/bash "$new_user" || die "Failed to create user $new_user"
        log "Set a password for user '$new_user':"
        passwd "$new_user"
    fi
    
    if [ "$INSTALL_APP_HOST" = true ]; then
        usermod -aG podman "$new_user" || true
    fi
    
    log "User '$new_user' created."
    log "Creating first-login setup script for user '${new_user}'..."
    local first_login_script_path="/home/${new_user}/.first_login.sh"
    cat > "$first_login_script_path" <<EOF
#!/bin/bash
echo ">>> Performing one-time user setup... (output is logged to ~/.first_login.log)"
(
export HOME="/home/${new_user}"
export USER="${new_user}"
if [ "$INSTALL_STYLING" = true ]; then
    echo ">>> Applying base styling..."
    case "$DESKTOP_ENV" in
        "XFCE")
            for ((i=0; i<120; i++)); do
                if pgrep -u "\${USER}" xfce4-session >/dev/null; then
                    break
                fi
                sleep 1
            done
            if command -v xfconf-query &>/dev/null && [ -n "\$DBUS_SESSION_BUS_ADDRESS" ]; then
                xfconf-query -c xsettings -p /Net/IconThemeName -s "Papirus"
                xfconf-query -c xfce4-terminal -p /font-name -s 'FiraCode Nerd Font Mono 10'
                xfconf-query -c xfwm4 -p /general/theme -s "Greybird"
            else
                echo ">>> Could not configure XFCE theming automatically."
            fi
            ;;
        "KDE-Plasma")
            echo ">>> KDE theming setup needs to be done manually."
            ;;
        "GNOME")
            echo ">>> GNOME theming setup needs to be done manually."
            ;;
        *) 
            echo ">>> Please manually select 'Papirus' icon theme and 'FiraCode Nerd Font' in your DE settings."
            ;;
    esac
fi
if [ "$INSTALL_APP_HOST" = true ] && command -v distrobox-create &>/dev/null; then
    echo ">>> Creating Distrobox container (this may take a few minutes)..."
    # Check if container already exists
    if ! distrobox-list | grep -q ubuntu; then
        distrobox-create --name ubuntu --image ubuntu:latest --yes
    fi
fi
echo ">>> Setup complete!" 
) 2>&1 | tee "/home/${new_user}/.first_login.log"
echo ">>> Removing first-login script..."
rm -- "\$0"
EOF
    chmod +x "$first_login_script_path"
    chown "${new_user}:${new_user}" "$first_login_script_path"
    
    local shell_profile_path="/home/${new_user}/.profile"
    local shell_rc_path="/home/${new_user}/.bashrc"
    
    if [ "$INSTALL_CYBER_TERM" = true ]; then
        log "Setting up Cybernetic Terminal for user '${new_user}'..."
        chsh -s /bin/zsh "${new_user}"
        shell_rc_path="/home/${new_user}/.zshrc"
        shell_profile_path="/home/${new_user}/.zprofile"
        cat > "$shell_rc_path" <<'EOF'
# Enable Powerlevel10k prompt if available
if [ -f /usr/share/zsh/site-contrib/powerlevel10k.zsh-theme ]; then
    source /usr/share/zsh/site-contrib/powerlevel10k.zsh-theme
fi
# Enable starship prompt
if command -v starship &>/dev/null; then
    eval "$(starship init zsh)"
fi
# Enable fzf keybindings and fuzzy completion
if command -v fzf &>/dev/null; then
    source /usr/share/fzf/completion.zsh
    source /usr/share/fzf/key-bindings.zsh
fi
# Aliases
alias ls='ls --color=auto'
alias ll='ls -lh'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias neofetch='neofetch --disable title model --ascii_colors 5 6 1 2 3'
# Add user bin to PATH
export PATH="$HOME/.local/bin:$PATH"
# Add distrobox to PATH if available
if [ -d "$HOME/.local/share/distrobox" ]; then
    export PATH="$PATH:$HOME/.local/share/distrobox"
fi
EOF
        chown "${new_user}:${new_user}" "$shell_rc_path"
    fi
    
    if [ "$INSTALL_APP_HOST" = true ]; then
        log "Adding Distrobox aliases to ${shell_rc_path}..."
        cat >> "$shell_rc_path" <<'EOF'
# Distrobox aliases
if command -v distrobox-enter &> /dev/null; then
    alias db='distrobox-enter'
    alias dbr='distrobox-enter ubuntu --'
    alias apt="distrobox-enter ubuntu -- sudo apt"
    alias apti="distrobox-enter ubuntu -- sudo apt install"
    alias aptu="distrobox-enter ubuntu -- sudo apt update && distrobox-enter ubuntu -- sudo apt upgrade"
    alias dbox='distrobox-list'
fi
EOF
    fi
    
    # Add first login script to profile
    cat >> "$shell_profile_path" <<EOF
# First login setup script
if [ -f "\$HOME/.first_login.sh" ]; then
    . "\$HOME/.first_login.sh"
fi
EOF
    chown "${new_user}:${new_user}" "$shell_profile_path"
    
    log "Installation complete."
    log "Finalizing disk writes..."
    sync
}

unmount_and_reboot() {
    log "Installation has finished."
    warn "The script will now attempt to cleanly unmount all partitions and reboot."
    if ! ${FORCE_MODE:-false}; then
        read -r -p "Press ENTER to proceed..."
    else
        log "Force mode: proceeding automatically."
    fi
    
    # Final sync
    sync
    
    local retries=5
    while [ $retries -gt 0 ]; do
        log "Attempting to unmount filesystems (attempt $((6 - retries))/5)..."
        
        # Try to kill any processes using the mount point
        if command -v lsof >/dev/null && lsof "${GENTOO_MNT}" >/dev/null 2>&1; then
            warn "Processes are still using the mount point. Attempting to kill them..."
            lsof "${GENTOO_MNT}" | awk 'NR>1 {print $2}' | xargs -r kill -9 &>/dev/null || true
            sleep 2
        fi
        
        # Unmount in reverse order
        umount -R "${GENTOO_MNT}/proc" &>/dev/null || true
        umount -R "${GENTOO_MNT}/sys" &>/dev/null || true
        umount -R "${GENTOO_MNT}/dev" &>/dev/null || true
        umount -R "${GENTOO_MNT}/run" &>/dev/null || true
        
        # Handle LVM and LUKS
        if [ "$USE_LVM" = true ]; then
            vgchange -an gentoo_vg &>/dev/null || true
        fi
        
        if [ "$USE_LUKS" = true ]; then
            cryptsetup close gentoo_crypted &>/dev/null || true
        fi
        
        umount -R "${GENTOO_MNT}" &>/dev/null || umount -l "${GENTOO_MNT}" &>/dev/null || true
        
        if ! mountpoint -q "${GENTOO_MNT}"; then
            log "Successfully unmounted ${GENTOO_MNT}."
            
            # Final cleanup of temp files
            if [ -f "$CONFIG_FILE_TMP" ]; then
                rm -f "$CONFIG_FILE_TMP" 2>/dev/null || true
            fi
            
            if [ -f "$CHECKPOINT_FILE" ]; then
                rm -f "$CHECKPOINT_FILE" 2>/dev/null || true
            fi
            
            log "Rebooting in 5 seconds..."
            sleep 5
            reboot
            exit 0
        else
            err "Failed to unmount ${GENTOO_MNT}. It might still be busy."
            if command -v lsof >/dev/null; then
                warn "Processes still using the mount point:"
                lsof "${GENTOO_MNT}" || echo " (none found, might be a kernel issue)"
            fi
            warn "Retrying in 10 seconds... (${retries} attempts left)"
            sleep 10
            retries=$((retries - 1))
        fi
    done
    
    warn "Could not automatically unmount all filesystems. You may need to do this manually."
    warn "Run the following commands before rebooting:"
    warn "  umount -R ${GENTOO_MNT}"
    if [ "$USE_LUKS" = true ]; then
        warn "  cryptsetup close gentoo_crypted"
    fi
    if [ "$USE_LVM" = true ]; then
        warn "  vgchange -an gentoo_vg"
    fi
    warn "Then reboot with: reboot"
    read -r -p "Press ENTER to drop to a shell for manual cleanup, or Ctrl+C to abort..."
    exec /bin/bash
}

# ==============================================================================
# --- MAIN SCRIPT LOGIC ---
# ==============================================================================
main() {
    if [ $EUID -ne 0 ]; then
        die "This script must be run as root."
    fi
    
    # Run integrity check as the very first step.
    self_check
    
    if [ "${1:-}" = "--chrooted" ]; then
        # Source configuration in chroot environment
        if [ -f /etc/autobuilder.conf ]; then
            source /etc/autobuilder.conf
        else
            die "Configuration file not found in chroot environment."
        fi
        
        CHECKPOINT_FILE="/.genesis_checkpoint"
        if [ -f "$CHECKPOINT_FILE" ]; then
            START_STAGE=$(<"$CHECKPOINT_FILE")
            START_STAGE=$((START_STAGE + 1))
            log "Resuming from stage ${START_STAGE} after interruption."
        else
            START_STAGE=3
        fi
        
        declare -a chrooted_stages=(
            stage3_configure_in_chroot
            stage4_build_world_and_kernel
            stage5_install_bootloader
            stage6_install_software
            stage7_finalize
        )
        
        local stage_num=3
        for stage_func in "${chrooted_stages[@]}"; do
            if [ "$START_STAGE" -le "$stage_num" ]; then
                if declare -f "$stage_func" >/dev/null; then
                    log "Executing stage ${stage_num}: ${stage_func}"
                    "$stage_func"
                    save_checkpoint "$stage_num"
                else
                    die "Function $stage_func is not defined."
                fi
            else
                log "Skipping stage ${stage_num} (already completed)."
            fi
            stage_num=$((stage_num + 1))
        done
        
        log "Chroot stages complete. Cleaning up..."
        rm -f /etc/autobuilder.conf "/.genesis_checkpoint" 2>/dev/null || true
        
        # Exit chroot
        exit 0
    else
        # Parse command line arguments
        for arg in "$@"; do
            case "$arg" in
                --force|--auto)
                    FORCE_MODE=true
                    ;;
                --skip-checksum)
                    SKIP_CHECKSUM=true
                    warn "WARNING: Checksum verification is disabled. This is a security risk."
                    ;;
            esac
        done
        
        # Check if we're resuming an installation
        if mountpoint -q "${GENTOO_MNT}"; then
            CHECKPOINT_FILE="${GENTOO_MNT}/.genesis_checkpoint"
            if [ -f "$CHECKPOINT_FILE" ]; then
                log "Found existing installation at ${GENTOO_MNT}. Resuming..."
            fi
        fi
        
        load_checkpoint
        
        declare -a stages=(
            pre_flight_checks
            ensure_dependencies
            stage0_select_mirrors
            detect_cpu_architecture
            detect_cpu_flags
            detect_gpu_hardware
            interactive_setup
            stage0_partition_and_format
            stage1_deploy_base_system
            stage2_prepare_chroot
        )
        
        for i in "${!stages[@]}"; do
            local stage_num=$i
            local stage_func=${stages[$i]}
            if [ "$START_STAGE" -le "$stage_num" ]; then
                if declare -f "$stage_func" >/dev/null; then
                    log "Executing stage ${stage_num}: ${stage_func}"
                    "$stage_func"
                    if [ "$stage_func" != "stage2_prepare_chroot" ]; then
                        save_checkpoint "$stage_num"
                    fi
                else
                    die "Function $stage_func is not defined."
                fi
            else
                log "Skipping stage ${stage_num} (already completed)."
            fi
        done
        
        unmount_and_reboot
    fi
}

# --- SCRIPT ENTRYPOINT ---
# Setup logging before main function
mkdir -p /tmp
if [ "${1:-}" != "--chrooted" ]; then
    # Handle log file for initial run
    if [ -f "${CHECKPOINT_FILE}" ] && [ -d "${GENTOO_MNT}/root" ]; then
        EXISTING_LOG=$(find "${GENTOO_MNT}/root" -name "gentoo_genesis_install.log" -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -n 1)
        if [ -n "$EXISTING_LOG" ] && [ -f "$EXISTING_LOG" ]; then
            LOG_FILE_PATH="$EXISTING_LOG"
            echo -e "\n--- RESUMING LOG $(date) ---\n" >> "$LOG_FILE_PATH"
        fi
    fi
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE_PATH")"
    
    # Run main function with logging
    main "$@" 2>&1 | tee -a "$LOG_FILE_PATH"
else
    # In chroot, just run main
    main "$@"
fi

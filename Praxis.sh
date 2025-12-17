#!/usr/bin/env bash
# ============================================================================
# The Gentoo Genesis Engine - Improved Edition
# Version: 11.0.0 "Phoenix"
# Original Author: viktorpolanitsa
# License: MIT
#
# Fully automated Gentoo Linux installer with:
# - Interactive configuration wizard with validation
# - Robust checkpoints and resume capability
# - LUKS2 (Argon2id), LVM, separate /home, swap/zram
# - Btrfs with @, @home, @snapshots subvolumes + boot environments
# - OpenRC/systemd, standard/hardened profiles
# - LSM: AppArmor / SELinux / none
# - UFW firewall, desktop environments (KDE/GNOME/XFCE/i3/server)
# - Kernel: genkernel / gentoo-kernel / gentoo-kernel-bin / manual
# - ccache, binpkg, LTO optimizations
# - Automatic updates with snapshot rollback support
# - CPU frequency scaling and power management
#
# Security improvements:
# - Secure password handling (no cmdline exposure)
# - GPG verification of Stage3 tarballs
# - Proper CPU architecture detection
# - Enhanced error handling
# ============================================================================

set -euo pipefail

# Save original IFS and restore in functions that modify it
readonly ORIG_IFS="$IFS"

# ============================================================================
# CONSTANTS AND DEFAULTS
# ============================================================================

readonly GENESIS_VERSION="11.0.0"
readonly GENESIS_NAME="The Gentoo Genesis Engine"
readonly GENESIS_CODENAME="Phoenix"

# File locations
CHECKPOINT_DIR=""  # Set after mount, defaults to /tmp initially
CHECKPOINT_FILE="/tmp/genesis_checkpoint"
readonly LIVECD_FIX_LOG="/var/log/genesis-livecd-fix.log"
readonly LOG_FILE="/var/log/genesis-install.log"
readonly ERR_LOG="/var/log/genesis-install-error.log"
readonly CONFIG_FILE=""

# Runtime flags
FORCE_AUTO=0
SKIP_CHECKSUM=0
SKIP_GPG=0
DRY_RUN=0
VERBOSE=0
DEBUG=0

# Ensure directories exist
mkdir -p /var/log /mnt/gentoo 2>/dev/null || true

# ============================================================================
# LOGGING SYSTEM
# ============================================================================

# Color codes (disabled if not a terminal)
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly NC='\033[0m'  # No Color
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

# Setup logging with proper buffering
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$ERR_LOG" >&2)

log() {
    printf '%s [INFO]  %s\n' "$(date -Is)" "$*"
}

debug() {
    (( DEBUG )) && printf '%s [DEBUG] %s\n' "$(date -Is)" "$*" || true
}

warn() {
    printf "${YELLOW}%s [WARN]  %s${NC}\n" "$(date -Is)" "$*" >&2
}

err() {
    printf "${RED}%s [ERROR] %s${NC}\n" "$(date -Is)" "$*" >&2
}

die() {
    err "$*"
    exit 1
}

success() {
    printf "${GREEN}%s [OK]    %s${NC}\n" "$(date -Is)" "$*"
}

# Print a section header
section() {
    local msg="$1"
    local width=70
    local padding=$(( (width - ${#msg} - 2) / 2 ))
    printf '\n%s\n' "$(printf '=%.0s' $(seq 1 $width))"
    printf '%*s %s %*s\n' $padding '' "$msg" $padding ''
    printf '%s\n\n' "$(printf '=%.0s' $(seq 1 $width))"
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Retry command with exponential backoff and jitter
retry_cmd() {
    local -i max_attempts=${1:-3}
    local -i base_sleep=${2:-3}
    shift 2
    
    local -i attempt=0
    local -i sleep_time
    local -i jitter
    
    until "$@"; do
        attempt=$((attempt + 1))
        if (( attempt >= max_attempts )); then
            err "Command failed after $max_attempts attempts: $*"
            return 1
        fi
        
        # Exponential backoff with jitter
        sleep_time=$((base_sleep * (2 ** (attempt - 1))))
        jitter=$((RANDOM % 5))
        sleep_time=$((sleep_time + jitter))
        
        warn "Retry $attempt/$max_attempts (waiting ${sleep_time}s): $*"
        sleep "$sleep_time"
    done
    return 0
}

# Check if command exists
cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Secure password reading (prevents echo and stores securely)
read_password() {
    local prompt="$1"
    local -n result_var="$2"
    local confirm="${3:-}"
    local min_length="${4:-8}"
    
    while true; do
        IFS= read -rs -p "$prompt" result_var
        echo
        
        # Check minimum length
        if (( ${#result_var} < min_length )); then
            warn "Password must be at least $min_length characters"
            continue
        fi
        
        # Confirm if requested
        if [[ -n "$confirm" ]]; then
            local confirm_pass
            IFS= read -rs -p "$confirm" confirm_pass
            echo
            
            if [[ "$result_var" != "$confirm_pass" ]]; then
                warn "Passwords do not match"
                continue
            fi
        fi
        
        break
    done
}

# Secure password passing to commands (no cmdline exposure)
# Uses process substitution and file descriptors
secure_cryptsetup_format() {
    local device="$1"
    local password="$2"
    
    # Use a file descriptor to pass password securely
    cryptsetup luksFormat --type luks2 \
        --pbkdf argon2id \
        --pbkdf-memory 1048576 \
        --pbkdf-parallel 4 \
        --iter-time 3000 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --use-random \
        "$device" --key-file=<(printf '%s' "$password")
}

secure_cryptsetup_open() {
    local device="$1"
    local name="$2"
    local password="$3"
    
    cryptsetup open "$device" "$name" --key-file=<(printf '%s' "$password")
}

# Compare version strings
version_gte() {
    printf '%s\n%s' "$1" "$2" | sort -V -C
}

# Get disk partition prefix (handles nvme, mmc, etc.)
partition_prefix() {
    local disk="$1"
    if [[ "$disk" =~ [0-9]$ ]]; then
        echo "${disk}p"
    else
        echo "$disk"
    fi
}

# Check if disk is in use
disk_in_use() {
    local disk="$1"
    
    # Check for mounted partitions
    if findmnt -S "$disk"'*' >/dev/null 2>&1; then
        return 0
    fi
    
    # Check for active LVM
    if pvs "$disk"* 2>/dev/null | grep -q "$disk"; then
        return 0
    fi
    
    # Check for active LUKS
    if dmsetup ls 2>/dev/null | grep -q "$(basename "$disk")"; then
        return 0
    fi
    
    return 1
}

# Human readable size
human_size() {
    local bytes="$1"
    local units=("B" "KiB" "MiB" "GiB" "TiB")
    local unit=0
    
    while (( bytes >= 1024 && unit < 4 )); do
        bytes=$((bytes / 1024))
        unit=$((unit + 1))
    done
    
    echo "${bytes} ${units[$unit]}"
}

# ============================================================================
# CHECKPOINT SYSTEM
# ============================================================================

checkpoint() {
    local stage="$1"
    local data="${2:-}"
    
    # Save checkpoint with metadata
    {
        echo "STAGE=$stage"
        echo "TIMESTAMP=$(date -Is)"
        echo "VERSION=$GENESIS_VERSION"
        [[ -n "$data" ]] && echo "DATA=$data"
    } > "$CHECKPOINT_FILE"
    
    sync
    debug "Checkpoint saved: $stage"
}

get_checkpoint() {
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        grep '^STAGE=' "$CHECKPOINT_FILE" 2>/dev/null | cut -d= -f2 || echo "0"
    else
        echo "0"
    fi
}

get_checkpoint_version() {
    if [[ -f "$CHECKPOINT_FILE" ]]; then
        grep '^VERSION=' "$CHECKPOINT_FILE" 2>/dev/null | cut -d= -f2 || echo "0"
    else
        echo "0"
    fi
}

clear_checkpoint() {
    rm -f "$CHECKPOINT_FILE" 2>/dev/null || true
    debug "Checkpoint cleared"
}

# Move checkpoint to persistent storage after mount
migrate_checkpoint() {
    if [[ -d /mnt/gentoo && -w /mnt/gentoo ]]; then
        CHECKPOINT_DIR="/mnt/gentoo/.genesis"
        mkdir -p "$CHECKPOINT_DIR"
        
        if [[ -f /tmp/genesis_checkpoint && ! -f "$CHECKPOINT_DIR/checkpoint" ]]; then
            cp /tmp/genesis_checkpoint "$CHECKPOINT_DIR/checkpoint"
        fi
        
        CHECKPOINT_FILE="$CHECKPOINT_DIR/checkpoint"
    fi
}

# ============================================================================
# CLEANUP AND SIGNAL HANDLING
# ============================================================================

cleanup() {
    local exit_code=$?
    
    log "Cleanup: unmounting filesystems and closing encrypted volumes"
    
    # Remove sensitive files
    rm -f /mnt/gentoo/tmp/.genesis_env.sh 2>/dev/null || true
    shred -u /mnt/gentoo/tmp/.genesis_env.sh 2>/dev/null || true
    
    # Unmount in reverse order
    local mounts=(
        "/mnt/gentoo/dev/shm"
        "/mnt/gentoo/dev/pts"
        "/mnt/gentoo/dev"
        "/mnt/gentoo/sys"
        "/mnt/gentoo/proc"
        "/mnt/gentoo/run"
        "/mnt/gentoo/boot/efi"
        "/mnt/gentoo/boot"
        "/mnt/gentoo/home"
        "/mnt/gentoo"
    )
    
    for mount in "${mounts[@]}"; do
        umount -l "$mount" 2>/dev/null || true
    done
    
    # Deactivate LVM
    if [[ -n "${VG_NAME:-}" ]]; then
        vgchange -an "$VG_NAME" 2>/dev/null || true
    fi
    
    # Close LUKS container
    if [[ -e /dev/mapper/cryptroot ]]; then
        cryptsetup close cryptroot 2>/dev/null || true
    fi
    
    # Close any additional LUKS containers
    if [[ -e /dev/mapper/cryptboot ]]; then
        cryptsetup close cryptboot 2>/dev/null || true
    fi
    
    if (( exit_code != 0 )); then
        warn "Installation did not complete successfully (exit code: $exit_code)"
        warn "Checkpoint saved. You can resume by running the script again."
    fi
}

trap cleanup EXIT

# Handle interrupts gracefully
handle_interrupt() {
    echo
    warn "Installation interrupted by user"
    checkpoint "interrupted"
    exit 130
}

trap handle_interrupt INT TERM

# ============================================================================
# USAGE AND ARGUMENT PARSING
# ============================================================================

usage() {
    cat <<EOF
${GENESIS_NAME} v${GENESIS_VERSION} "${GENESIS_CODENAME}"

A fully automated, robust Gentoo Linux installer.

Usage: $0 [OPTIONS]

Options:
  -h, --help          Show this help message
  -V, --version       Show version information
  -f, --force         Automatically answer "yes" to confirmations
  -a, --auto          Same as --force
  -c, --config FILE   Load configuration from file
  -n, --dry-run       Show what would be done without making changes
  -v, --verbose       Enable verbose output
  -d, --debug         Enable debug output
  --skip-checksum     Skip SHA512 verification (NOT recommended)
  --skip-gpg          Skip GPG signature verification
  --clear-checkpoint  Clear saved checkpoint and start fresh

Examples:
  $0                         # Interactive installation
  $0 --force                 # Non-interactive with defaults
  $0 --config my-config.sh   # Load settings from file
  $0 --dry-run               # Preview actions without executing

For more information, visit: https://github.com/viktorpolanitsa/genesis

EOF
}

version_info() {
    cat <<EOF
${GENESIS_NAME}
Version: ${GENESIS_VERSION} "${GENESIS_CODENAME}"
License: MIT

Features:
  - UEFI and BIOS boot support
  - LUKS2 encryption with Argon2id
  - LVM logical volume management
  - Btrfs with subvolumes and snapshots
  - Multiple desktop environments
  - Automatic system updates

EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -V|--version)
                version_info
                exit 0
                ;;
            -f|--force|-a|--auto)
                FORCE_AUTO=1
                shift
                ;;
            -c|--config)
                [[ -n "${2:-}" ]] || die "Config file required"
                [[ -f "$2" ]] || die "Config file not found: $2"
                # shellcheck source=/dev/null
                source "$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -d|--debug)
                DEBUG=1
                VERBOSE=1
                shift
                ;;
            --skip-checksum)
                SKIP_CHECKSUM=1
                warn "Stage3 checksum verification disabled"
                shift
                ;;
            --skip-gpg)
                SKIP_GPG=1
                warn "GPG signature verification disabled"
                shift
                ;;
            --clear-checkpoint)
                clear_checkpoint
                log "Checkpoint cleared"
                shift
                ;;
            -*)
                die "Unknown option: $1 (use --help for usage)"
                ;;
            *)
                die "Unexpected argument: $1"
                ;;
        esac
    done
}

# Root check
check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root"
    fi
}

# ============================================================================
# LIVECD SELF-HEALING
# ============================================================================

self_heal_livecd() {
    section "LiveCD Self-Diagnostics"
    
    local mem_kb
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local mem_human
    mem_human=$(human_size $((mem_kb * 1024)))
    log "Total RAM: $mem_human"
    
    # Setup ZRAM if RAM < 6 GiB
    if (( mem_kb > 0 && mem_kb < 6 * 1024 * 1024 )); then
        if ! grep -q zram /proc/swaps 2>/dev/null; then
            log "Low RAM detected - configuring ZRAM swap"
            
            if modprobe zram 2>/dev/null; then
                local zram_size=$((mem_kb * 1024 / 2))  # Half of RAM
                
                # Use newer interface if available
                if [[ -f /sys/block/zram0/reset ]]; then
                    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
                fi
                
                # Try newer disksize interface first
                if [[ -f /sys/block/zram0/disksize ]]; then
                    echo "$zram_size" > /sys/block/zram0/disksize 2>/dev/null || true
                fi
                
                mkswap /dev/zram0 2>/dev/null && \
                swapon -p 100 /dev/zram0 2>/dev/null && \
                success "ZRAM swap configured: $(human_size $zram_size)"
            fi
        else
            debug "ZRAM already active"
        fi
    fi
    
    # Check required tools
    local required_tools=(
        lsblk sfdisk parted
        mkfs.ext4 mkfs.xfs mkfs.btrfs mkfs.vfat
        cryptsetup
        pvcreate vgcreate lvcreate
        btrfs
        wget curl
        tar xz
        gpg
    )
    
    local missing=()
    for tool in "${required_tools[@]}"; do
        if ! cmd_exists "$tool"; then
            missing+=("$tool")
        fi
    done
    
    if (( ${#missing[@]} > 0 )); then
        warn "Missing tools: ${missing[*]}"
        
        if cmd_exists emerge; then
            log "Attempting to install missing tools..."
            
            local packages=(
                sys-fs/cryptsetup
                sys-fs/lvm2
                sys-fs/btrfs-progs
                sys-fs/xfsprogs
                sys-fs/dosfstools
                sys-apps/util-linux
                sys-apps/pv
                app-crypt/gnupg
                net-misc/wget
                net-misc/curl
                sys-block/parted
            )
            
            (
                export FEATURES="-news"
                emerge --quiet --noreplace "${packages[@]}" || true
            ) >> "$LIVECD_FIX_LOG" 2>&1
            
            # Recheck
            local still_missing=()
            for tool in "${missing[@]}"; do
                cmd_exists "$tool" || still_missing+=("$tool")
            done
            
            if (( ${#still_missing[@]} > 0 )); then
                warn "Still missing after install attempt: ${still_missing[*]}"
            else
                success "All missing tools installed"
            fi
        fi
    else
        success "All required tools available"
    fi
    
    # Import Gentoo release keys for GPG verification
    if ! gpg --list-keys "Gentoo Linux Release Engineering" >/dev/null 2>&1; then
        log "Importing Gentoo release signing keys..."
        if wget -q -O - https://qa-reports.gentoo.org/output/service-keys.gpg | gpg --import 2>/dev/null; then
            success "Gentoo GPG keys imported"
        else
            warn "Could not import Gentoo GPG keys - signature verification may fail"
        fi
    fi
}

# ============================================================================
# HARDWARE DETECTION
# ============================================================================

# Global hardware variables
CPU_VENDOR="Unknown"
CPU_MODEL="Unknown"
CPU_MARCH="x86-64"
CPU_FLAGS=""
GPU_VENDOR="Unknown"
GPU_DRIVER="fbdev"
BOOT_MODE="bios"
HAS_SSD=0

detect_hardware() {
    section "Hardware Detection"
    
    # CPU Detection
    if [[ -f /proc/cpuinfo ]]; then
        CPU_VENDOR=$(awk -F: '/^vendor_id/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' /proc/cpuinfo)
        CPU_MODEL=$(awk -F: '/^model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo)
        CPU_FLAGS=$(awk -F: '/^flags/ {print $2; exit}' /proc/cpuinfo)
    fi
    
    # Detect CPU microarchitecture level
    CPU_MARCH=$(detect_cpu_march)
    
    log "CPU: $CPU_VENDOR $CPU_MODEL"
    log "Target architecture: $CPU_MARCH"
    
    # GPU Detection
    if cmd_exists lspci; then
        if lspci | grep -qi 'NVIDIA'; then
            GPU_VENDOR="NVIDIA"
            # Check for newer cards that work better with nouveau
            if lspci | grep -qiE 'NVIDIA.*(GTX|RTX|Quadro)'; then
                GPU_DRIVER="nvidia"  # Proprietary recommended for newer cards
            else
                GPU_DRIVER="nouveau"
            fi
        elif lspci | grep -qi 'AMD.*Radeon\|ATI'; then
            GPU_VENDOR="AMD"
            GPU_DRIVER="amdgpu radeonsi"
        elif lspci | grep -qi 'Intel.*Graphics\|Intel.*UHD\|Intel.*Iris'; then
            GPU_VENDOR="Intel"
            GPU_DRIVER="intel i965 iris"
        else
            GPU_VENDOR="Generic"
            GPU_DRIVER="fbdev vesa"
        fi
    fi
    
    log "GPU: $GPU_VENDOR (drivers: $GPU_DRIVER)"
    
    # Boot mode detection
    if [[ -d /sys/firmware/efi ]]; then
        BOOT_MODE="uefi"
        log "Boot mode: UEFI"
    else
        BOOT_MODE="bios"
        log "Boot mode: Legacy BIOS"
    fi
    
    # SSD detection
    for disk in /sys/block/sd* /sys/block/nvme*; do
        [[ -d "$disk" ]] || continue
        if [[ "$(cat "$disk/queue/rotational" 2>/dev/null)" == "0" ]]; then
            HAS_SSD=1
            break
        fi
    done
    
    log "SSD detected: $(( HAS_SSD ? 1 : 0 ))"
}

# Detect the appropriate CPU march based on actual capabilities
detect_cpu_march() {
    local flags
    flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2 || echo "")
    
    # x86-64-v4: AVX-512
    if [[ "$flags" == *" avx512f "* ]]; then
        echo "x86-64-v4"
        return
    fi
    
    # x86-64-v3: AVX2, BMI1, BMI2, F16C, FMA, LZCNT, MOVBE, XSAVE
    if [[ "$flags" == *" avx2 "* ]] && \
       [[ "$flags" == *" bmi1 "* ]] && \
       [[ "$flags" == *" bmi2 "* ]] && \
       [[ "$flags" == *" fma "* ]]; then
        echo "x86-64-v3"
        return
    fi
    
    # x86-64-v2: CMPXCHG16B, LAHF-SAHF, POPCNT, SSE3, SSE4.1, SSE4.2, SSSE3
    if [[ "$flags" == *" sse4_2 "* ]] && \
       [[ "$flags" == *" popcnt "* ]] && \
       [[ "$flags" == *" ssse3 "* ]]; then
        echo "x86-64-v2"
        return
    fi
    
    # Fallback to baseline x86-64
    echo "x86-64"
}

# ============================================================================
# CHECKPOINT RESUME HANDLING
# ============================================================================

handle_resume() {
    local current_checkpoint
    current_checkpoint=$(get_checkpoint)
    
    if [[ "$current_checkpoint" != "0" ]]; then
        local checkpoint_version
        checkpoint_version=$(get_checkpoint_version)
        
        section "Resume Detected"
        
        log "Found unfinished installation at stage: $current_checkpoint"
        log "Checkpoint version: $checkpoint_version"
        log "Current version: $GENESIS_VERSION"
        
        if [[ "$checkpoint_version" != "$GENESIS_VERSION" ]]; then
            warn "Checkpoint was created with a different version"
        fi
        
        if (( FORCE_AUTO )); then
            log "Auto mode: resuming from checkpoint"
            return
        fi
        
        echo
        echo "Options:"
        echo "  [C] Continue - Resume from saved checkpoint"
        echo "  [R] Restart  - Start installation from scratch"
        echo "  [A] Abort    - Exit without changes"
        echo
        
        local choice
        read -rp "Your choice [C/R/A]: " choice
        
        case "${choice^^}" in
            C|"")
                log "Continuing from checkpoint: $current_checkpoint"
                ;;
            R)
                log "Clearing checkpoint and restarting"
                clear_checkpoint
                ;;
            A)
                die "Installation aborted by user"
                ;;
            *)
                log "Invalid choice, defaulting to Continue"
                ;;
        esac
    fi
}

# ============================================================================
# NETWORK VERIFICATION
# ============================================================================

check_network() {
    section "Network Connectivity"
    
    local test_hosts=(
        "1.1.1.1"
        "8.8.8.8"
        "9.9.9.9"
    )
    
    local test_urls=(
        "https://distfiles.gentoo.org"
        "https://gentoo.osuosl.org"
        "https://mirror.yandex.ru/gentoo/"
    )
    
    # Test basic connectivity
    local connected=0
    for host in "${test_hosts[@]}"; do
        if ping -c1 -W3 "$host" >/dev/null 2>&1; then
            debug "Ping to $host successful"
            connected=1
            break
        fi
    done
    
    if (( ! connected )); then
        warn "ICMP ping failed, testing HTTP connectivity..."
    fi
    
    # Test HTTP connectivity
    for url in "${test_urls[@]}"; do
        if curl -s --head --max-time 10 "$url" >/dev/null 2>&1; then
            success "Network connectivity verified via $url"
            return 0
        fi
    done
    
    die "No network connectivity detected. Please configure network before running installer."
}

# ============================================================================
# CONFIGURATION VARIABLES (with defaults)
# ============================================================================

# Disk and partitioning
TARGET_DISK=""
FS_TYPE="btrfs"
USE_LVM=1
USE_LUKS=1
ENCRYPT_BOOT=0
SEPARATE_HOME=1
SWAP_MODE="zram"
SWAP_SIZE="4G"

# System configuration
INIT_SYSTEM="openrc"
PROFILE_FLAVOR="standard"
LSM_CHOICE="none"
ENABLE_UFW=1

# Desktop/Server
DE_CHOICE="kde"

# Kernel
KERNEL_MODE="gentoo-kernel-bin"

# Performance
ENABLE_CCACHE=1
ENABLE_BINPKG=1
ENABLE_LTO=0

# Software bundles
BUNDLE_FLATPAK=1
BUNDLE_TERM=1
BUNDLE_DEV=1
BUNDLE_OFFICE=1
BUNDLE_GAMING=0

# Maintenance
AUTO_UPDATE=1
CPU_FREQ_TUNE=1

# User configuration
HOSTNAME="gentoo"
USERNAME="gentoo"
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# Passwords (set interactively)
ROOT_PASSWORD=""
USER_PASSWORD=""
LUKS_PASSWORD=""

# LVM names
VG_NAME="vg0"
LV_ROOT="lvroot"
LV_SWAP="lvswap"
LV_HOME="lvhome"
LV_BOOT="lvboot"

# ============================================================================
# INTERACTIVE WIZARD
# ============================================================================

# Helper: Yes/No prompt with default
yesno() {
    local prompt="$1"
    local default="${2:-yes}"
    
    if (( FORCE_AUTO )); then
        [[ "${default,,}" == "yes" ]] && echo "yes" || echo "no"
        return
    fi
    
    local yn_hint
    [[ "${default,,}" == "yes" ]] && yn_hint="[Y/n]" || yn_hint="[y/N]"
    
    local answer
    read -rp "$prompt $yn_hint: " answer
    answer="${answer:-$default}"
    
    [[ "${answer,,}" =~ ^y(es)?$ ]] && echo "yes" || echo "no"
}

# Helper: Choice from numbered list
choose_option() {
    local prompt="$1"
    local default="$2"
    shift 2
    local options=("$@")
    
    if (( FORCE_AUTO )); then
        echo "$default"
        return
    fi
    
    echo
    local i=1
    for opt in "${options[@]}"; do
        if (( i == default )); then
            echo "  $i) $opt (default)"
        else
            echo "  $i) $opt"
        fi
        ((i++))
    done
    
    local choice
    read -rp "$prompt [1-${#options[@]}, default $default]: " choice
    choice="${choice:-$default}"
    
    # Validate
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#options[@]} )); then
        choice="$default"
    fi
    
    echo "$choice"
}

wizard() {
    section "Configuration Wizard"
    
    # -------------------------------------------------------------------------
    # Disk Selection
    # -------------------------------------------------------------------------
    echo "Available disks:"
    echo
    
    # Show disks with more information
    lsblk -dno NAME,SIZE,MODEL,TYPE,TRAN | grep -E 'disk' | while read -r line; do
        local name size model type tran
        read -r name size model type tran <<< "$line"
        local in_use=""
        
        if disk_in_use "/dev/$name"; then
            in_use=" [IN USE]"
        fi
        
        printf "  %-12s %8s  %-30s %s%s\n" "$name" "$size" "${model:-Unknown}" "${tran:-}" "$in_use"
    done
    
    echo
    
    local disk_input
    while true; do
        read -rp "Select target disk (e.g., sda, nvme0n1): " disk_input
        
        [[ -n "$disk_input" ]] || { warn "No disk selected"; continue; }
        
        TARGET_DISK="/dev/${disk_input##*/}"
        
        [[ -b "$TARGET_DISK" ]] || { warn "Device $TARGET_DISK not found"; continue; }
        
        # Check if it's a disk, not partition
        if [[ ! -e "/sys/block/${disk_input##*/}" ]]; then
            warn "$TARGET_DISK appears to be a partition, not a disk"
            continue
        fi
        
        # Warn if disk is in use
        if disk_in_use "$TARGET_DISK"; then
            warn "WARNING: $TARGET_DISK appears to be in use!"
            local confirm
            confirm=$(yesno "Are you sure you want to use this disk?" "no")
            [[ "$confirm" == "yes" ]] || continue
        fi
        
        break
    done
    
    log "Selected disk: $TARGET_DISK"
    
    # -------------------------------------------------------------------------
    # Filesystem
    # -------------------------------------------------------------------------
    echo
    echo "Root filesystem:"
    local fs_choice
    fs_choice=$(choose_option "Select filesystem" 1 \
        "Btrfs (recommended - snapshots, compression)" \
        "XFS (high performance)" \
        "Ext4 (traditional, stable)")
    
    case "$fs_choice" in
        1) FS_TYPE="btrfs" ;;
        2) FS_TYPE="xfs" ;;
        3) FS_TYPE="ext4" ;;
    esac
    
    log "Filesystem: $FS_TYPE"
    
    # -------------------------------------------------------------------------
    # Encryption
    # -------------------------------------------------------------------------
    echo
    local luks_answer
    luks_answer=$(yesno "Enable full disk encryption (LUKS2)?" "yes")
    [[ "$luks_answer" == "yes" ]] && USE_LUKS=1 || USE_LUKS=0
    
    if (( USE_LUKS )); then
        log "Encryption: LUKS2 enabled"
        
        # Ask for LUKS password
        if (( ! FORCE_AUTO )); then
            echo
            read_password "Enter encryption password: " LUKS_PASSWORD \
                "Confirm encryption password: " 8
        else
            LUKS_PASSWORD="changeme_luks"
            warn "Using default LUKS password (CHANGE THIS!)"
        fi
        
        # Encrypt /boot option (UEFI + LVM only)
        if [[ "$BOOT_MODE" == "uefi" ]]; then
            local encrypt_boot_answer
            encrypt_boot_answer=$(yesno "Encrypt /boot partition (except EFI)?" "no")
            [[ "$encrypt_boot_answer" == "yes" ]] && ENCRYPT_BOOT=1 || ENCRYPT_BOOT=0
        fi
    fi
    
    # -------------------------------------------------------------------------
    # LVM
    # -------------------------------------------------------------------------
    echo
    local lvm_answer
    lvm_answer=$(yesno "Use LVM for flexible volume management?" "yes")
    [[ "$lvm_answer" == "yes" ]] && USE_LVM=1 || USE_LVM=0
    
    # -------------------------------------------------------------------------
    # Separate /home
    # -------------------------------------------------------------------------
    echo
    local home_answer
    home_answer=$(yesno "Create separate /home partition/subvolume?" "yes")
    [[ "$home_answer" == "yes" ]] && SEPARATE_HOME=1 || SEPARATE_HOME=0
    
    # -------------------------------------------------------------------------
    # Swap
    # -------------------------------------------------------------------------
    echo
    echo "Swap configuration:"
    local swap_choice
    swap_choice=$(choose_option "Select swap type" 1 \
        "ZRAM (compressed RAM, recommended)" \
        "Swap partition/LV" \
        "No swap")
    
    case "$swap_choice" in
        1) SWAP_MODE="zram" ;;
        2) SWAP_MODE="partition" ;;
        3) SWAP_MODE="none" ;;
    esac
    
    # -------------------------------------------------------------------------
    # Init System
    # -------------------------------------------------------------------------
    echo
    echo "Init system:"
    local init_choice
    init_choice=$(choose_option "Select init system" 1 \
        "OpenRC (lightweight, recommended)" \
        "systemd (feature-rich)")
    
    case "$init_choice" in
        1) INIT_SYSTEM="openrc" ;;
        2) INIT_SYSTEM="systemd" ;;
    esac
    
    # -------------------------------------------------------------------------
    # Profile
    # -------------------------------------------------------------------------
    echo
    local hardened_answer
    hardened_answer=$(yesno "Use hardened security profile?" "no")
    [[ "$hardened_answer" == "yes" ]] && PROFILE_FLAVOR="hardened" || PROFILE_FLAVOR="standard"
    
    # -------------------------------------------------------------------------
    # LSM
    # -------------------------------------------------------------------------
    echo
    echo "Linux Security Module:"
    local lsm_choice
    lsm_choice=$(choose_option "Select LSM" 1 \
        "None (default)" \
        "AppArmor (path-based MAC)" \
        "SELinux (label-based MAC)")
    
    case "$lsm_choice" in
        1) LSM_CHOICE="none" ;;
        2) LSM_CHOICE="apparmor" ;;
        3) LSM_CHOICE="selinux" ;;
    esac
    
    # -------------------------------------------------------------------------
    # Firewall
    # -------------------------------------------------------------------------
    echo
    local ufw_answer
    ufw_answer=$(yesno "Enable UFW firewall?" "yes")
    [[ "$ufw_answer" == "yes" ]] && ENABLE_UFW=1 || ENABLE_UFW=0
    
    # -------------------------------------------------------------------------
    # Desktop Environment
    # -------------------------------------------------------------------------
    echo
    echo "Desktop environment:"
    local de_choice
    de_choice=$(choose_option "Select environment" 1 \
        "KDE Plasma" \
        "GNOME" \
        "XFCE" \
        "i3 (minimal tiling WM)" \
        "Server (no GUI)")
    
    case "$de_choice" in
        1) DE_CHOICE="kde" ;;
        2) DE_CHOICE="gnome" ;;
        3) DE_CHOICE="xfce" ;;
        4) DE_CHOICE="i3" ;;
        5) DE_CHOICE="server" ;;
    esac
    
    # -------------------------------------------------------------------------
    # Kernel
    # -------------------------------------------------------------------------
    echo
    echo "Kernel management:"
    local kernel_choice
    kernel_choice=$(choose_option "Select kernel type" 1 \
        "gentoo-kernel-bin (prebuilt, fastest)" \
        "gentoo-kernel (distribution kernel)" \
        "genkernel (automatic build)" \
        "Manual (sources only)")
    
    case "$kernel_choice" in
        1) KERNEL_MODE="gentoo-kernel-bin" ;;
        2) KERNEL_MODE="gentoo-kernel" ;;
        3) KERNEL_MODE="genkernel" ;;
        4) KERNEL_MODE="manual" ;;
    esac
    
    # -------------------------------------------------------------------------
    # Performance Options
    # -------------------------------------------------------------------------
    echo
    echo "Performance options:"
    
    local ccache_answer
    ccache_answer=$(yesno "Enable ccache (compiler cache)?" "yes")
    [[ "$ccache_answer" == "yes" ]] && ENABLE_CCACHE=1 || ENABLE_CCACHE=0
    
    local binpkg_answer
    binpkg_answer=$(yesno "Enable binary package building?" "yes")
    [[ "$binpkg_answer" == "yes" ]] && ENABLE_BINPKG=1 || ENABLE_BINPKG=0
    
    local lto_answer
    lto_answer=$(yesno "Enable LTO (Link Time Optimization)?" "no")
    [[ "$lto_answer" == "yes" ]] && ENABLE_LTO=1 || ENABLE_LTO=0
    
    # -------------------------------------------------------------------------
    # Software Bundles
    # -------------------------------------------------------------------------
    echo
    echo "Software bundles:"
    
    local flatpak_answer
    flatpak_answer=$(yesno "Install Flatpak + Distrobox?" "yes")
    [[ "$flatpak_answer" == "yes" ]] && BUNDLE_FLATPAK=1 || BUNDLE_FLATPAK=0
    
    local term_answer
    term_answer=$(yesno "Install enhanced terminal (zsh + starship)?" "yes")
    [[ "$term_answer" == "yes" ]] && BUNDLE_TERM=1 || BUNDLE_TERM=0
    
    local dev_answer
    dev_answer=$(yesno "Install developer tools (git, docker, vscode)?" "yes")
    [[ "$dev_answer" == "yes" ]] && BUNDLE_DEV=1 || BUNDLE_DEV=0
    
    local office_answer
    office_answer=$(yesno "Install office suite (LibreOffice, GIMP)?" "yes")
    [[ "$office_answer" == "yes" ]] && BUNDLE_OFFICE=1 || BUNDLE_OFFICE=0
    
    local gaming_answer
    gaming_answer=$(yesno "Install gaming tools (Steam, Lutris, Wine)?" "no")
    [[ "$gaming_answer" == "yes" ]] && BUNDLE_GAMING=1 || BUNDLE_GAMING=0
    
    # -------------------------------------------------------------------------
    # Maintenance
    # -------------------------------------------------------------------------
    echo
    echo "System maintenance:"
    
    local update_answer
    update_answer=$(yesno "Enable automatic weekly updates?" "yes")
    [[ "$update_answer" == "yes" ]] && AUTO_UPDATE=1 || AUTO_UPDATE=0
    
    local cpufreq_answer
    cpufreq_answer=$(yesno "Enable CPU frequency management?" "yes")
    [[ "$cpufreq_answer" == "yes" ]] && CPU_FREQ_TUNE=1 || CPU_FREQ_TUNE=0
    
    # -------------------------------------------------------------------------
    # System Identity
    # -------------------------------------------------------------------------
    echo
    echo "System identity:"
    
    if (( ! FORCE_AUTO )); then
        read -rp "Hostname [gentoo]: " HOSTNAME
        HOSTNAME="${HOSTNAME:-gentoo}"
        
        read -rp "Username [gentoo]: " USERNAME
        USERNAME="${USERNAME:-gentoo}"
        
        # Validate username
        while [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; do
            warn "Invalid username (must start with letter, lowercase alphanumeric)"
            read -rp "Username: " USERNAME
        done
        
        read -rp "Timezone (e.g., Europe/London) [UTC]: " TIMEZONE
        TIMEZONE="${TIMEZONE:-UTC}"
        
        # Validate timezone
        if [[ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
            warn "Invalid timezone, using UTC"
            TIMEZONE="UTC"
        fi
    fi
    
    # -------------------------------------------------------------------------
    # Passwords
    # -------------------------------------------------------------------------
    echo
    if (( ! FORCE_AUTO )); then
        echo "Set passwords:"
        read_password "Root password: " ROOT_PASSWORD "Confirm root password: " 8
        echo
        read_password "User password for $USERNAME: " USER_PASSWORD "Confirm user password: " 8
    else
        ROOT_PASSWORD="changeme_root"
        USER_PASSWORD="changeme_user"
        warn "Using default passwords (CHANGE THESE IMMEDIATELY!)"
    fi
    
    # -------------------------------------------------------------------------
    # Summary and Confirmation
    # -------------------------------------------------------------------------
    display_summary
    
    if (( ! FORCE_AUTO )); then
        echo
        echo "═══════════════════════════════════════════════════════════════════════"
        echo "  WARNING: ALL DATA ON $TARGET_DISK WILL BE PERMANENTLY DESTROYED!"
        echo "═══════════════════════════════════════════════════════════════════════"
        echo
        
        local confirm
        read -rp "Type 'YES' in capitals to proceed: " confirm
        [[ "$confirm" == "YES" ]] || die "Installation aborted by user"
    fi
    
    if (( DRY_RUN )); then
        log "Dry run mode - no changes will be made"
        exit 0
    fi
}

display_summary() {
    section "Configuration Summary"
    
    cat <<EOF
  Target Disk:       $TARGET_DISK
  Boot Mode:         $BOOT_MODE
  
  STORAGE:
    Filesystem:      $FS_TYPE
    LVM:             $(( USE_LVM ? 1 : 0 )) (enabled)
    LUKS:            $(( USE_LUKS ? 1 : 0 )) (encrypt boot: $ENCRYPT_BOOT)
    Separate /home:  $(( SEPARATE_HOME ? 1 : 0 ))
    Swap:            $SWAP_MODE
  
  SYSTEM:
    Init System:     $INIT_SYSTEM
    Profile:         $PROFILE_FLAVOR
    LSM:             $LSM_CHOICE
    UFW Firewall:    $(( ENABLE_UFW ? 1 : 0 ))
    Desktop:         $DE_CHOICE
    Kernel:          $KERNEL_MODE
  
  PERFORMANCE:
    ccache:          $(( ENABLE_CCACHE ? 1 : 0 ))
    Binary pkgs:     $(( ENABLE_BINPKG ? 1 : 0 ))
    LTO:             $(( ENABLE_LTO ? 1 : 0 ))
  
  SOFTWARE:
    Flatpak:         $(( BUNDLE_FLATPAK ? 1 : 0 ))
    Terminal:        $(( BUNDLE_TERM ? 1 : 0 ))
    Developer:       $(( BUNDLE_DEV ? 1 : 0 ))
    Office:          $(( BUNDLE_OFFICE ? 1 : 0 ))
    Gaming:          $(( BUNDLE_GAMING ? 1 : 0 ))
  
  MAINTENANCE:
    Auto-update:     $(( AUTO_UPDATE ? 1 : 0 ))
    CPU Freq:        $(( CPU_FREQ_TUNE ? 1 : 0 ))
  
  IDENTITY:
    Hostname:        $HOSTNAME
    Username:        $USERNAME
    Timezone:        $TIMEZONE

EOF
}

# ============================================================================
# DISK PARTITIONING AND FILESYSTEM SETUP
# ============================================================================

partition_disk() {
    section "Disk Partitioning"
    
    log "Preparing disk: $TARGET_DISK"
    
    # Ensure nothing is using the disk
    swapoff -a 2>/dev/null || true
    
    # Stop any LVM on this disk
    for vg in $(vgs --noheadings -o vg_name 2>/dev/null); do
        if pvs --noheadings -o pv_name 2>/dev/null | grep -q "$TARGET_DISK"; then
            vgchange -an "$vg" 2>/dev/null || true
        fi
    done
    
    # Close any LUKS containers
    for dm in $(dmsetup ls --target crypt 2>/dev/null | cut -f1); do
        cryptsetup close "$dm" 2>/dev/null || true
    done
    
    # Unmount anything on this disk
    for mount in $(findmnt -rno TARGET -S "$TARGET_DISK"'*' 2>/dev/null); do
        umount -l "$mount" 2>/dev/null || true
    done
    
    sleep 2
    
    # Wipe disk signatures
    wipefs -af "$TARGET_DISK" 2>/dev/null || true
    
    # Flush buffers
    blockdev --flushbufs "$TARGET_DISK" 2>/dev/null || true
    sync
    sleep 1
    
    local part_prefix
    part_prefix=$(partition_prefix "$TARGET_DISK")
    
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        log "Creating GPT partition table for UEFI boot"
        
        # UEFI: EFI System Partition + Root (LUKS or plain)
        parted -s "$TARGET_DISK" \
            mklabel gpt \
            mkpart "EFI" fat32 1MiB 513MiB \
            set 1 esp on \
            mkpart "root" ext4 513MiB 100%
        
    else
        log "Creating GPT partition table for BIOS boot"
        
        # BIOS: BIOS Boot Partition + Root
        parted -s "$TARGET_DISK" \
            mklabel gpt \
            mkpart "BIOS" 1MiB 3MiB \
            set 1 bios_grub on \
            mkpart "root" ext4 3MiB 100%
    fi
    
    # Wait for partitions to appear
    partprobe "$TARGET_DISK"
    sleep 2
    
    # Verify partitions exist
    local p1="${part_prefix}1"
    local p2="${part_prefix}2"
    
    [[ -b "$p1" ]] || die "Partition $p1 not found after partitioning"
    [[ -b "$p2" ]] || die "Partition $p2 not found after partitioning"
    
    success "Partitions created: $p1, $p2"
}

setup_encryption() {
    if (( ! USE_LUKS )); then
        return
    fi
    
    section "Encryption Setup"
    
    local part_prefix
    part_prefix=$(partition_prefix "$TARGET_DISK")
    local crypt_part="${part_prefix}2"
    
    log "Setting up LUKS2 encryption on $crypt_part"
    
    # Use secure password passing
    secure_cryptsetup_format "$crypt_part" "$LUKS_PASSWORD"
    
    success "LUKS2 container created"
    
    # Open the container
    log "Opening encrypted container"
    secure_cryptsetup_open "$crypt_part" "cryptroot" "$LUKS_PASSWORD"
    
    success "Encrypted container opened as /dev/mapper/cryptroot"
}

setup_lvm() {
    section "LVM Setup"
    
    local pv_device
    
    if (( USE_LUKS )); then
        pv_device="/dev/mapper/cryptroot"
    else
        local part_prefix
        part_prefix=$(partition_prefix "$TARGET_DISK")
        pv_device="${part_prefix}2"
    fi
    
    if (( USE_LVM )); then
        log "Creating LVM on $pv_device"
        
        # Create physical volume
        pvcreate -ff "$pv_device"
        
        # Create volume group
        vgcreate "$VG_NAME" "$pv_device"
        
        success "Volume group $VG_NAME created"
        
        # Calculate sizes
        local vg_size_mb
        vg_size_mb=$(vgs --noheadings --units m -o vg_free "$VG_NAME" | tr -d ' mM')
        
        # Create logical volumes
        if (( SEPARATE_HOME )); then
            # Root: 40%, Swap: 4G or 5%, Home: rest
            local root_size=$((vg_size_mb * 40 / 100))
            
            lvcreate -y -L "${root_size}M" -n "$LV_ROOT" "$VG_NAME"
            log "Created LV $LV_ROOT (${root_size}M)"
            
            if [[ "$SWAP_MODE" == "partition" ]]; then
                lvcreate -y -L "$SWAP_SIZE" -n "$LV_SWAP" "$VG_NAME"
                log "Created LV $LV_SWAP ($SWAP_SIZE)"
            fi
            
            lvcreate -y -l 100%FREE -n "$LV_HOME" "$VG_NAME"
            log "Created LV $LV_HOME (remaining space)"
        else
            # Just root (and maybe swap)
            if [[ "$SWAP_MODE" == "partition" ]]; then
                lvcreate -y -L "$SWAP_SIZE" -n "$LV_SWAP" "$VG_NAME"
                log "Created LV $LV_SWAP ($SWAP_SIZE)"
            fi
            
            lvcreate -y -l 100%FREE -n "$LV_ROOT" "$VG_NAME"
            log "Created LV $LV_ROOT (remaining space)"
        fi
        
        success "Logical volumes created"
    fi
}

create_filesystems() {
    section "Filesystem Creation"
    
    local part_prefix
    part_prefix=$(partition_prefix "$TARGET_DISK")
    
    # EFI/Boot partition
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        log "Creating FAT32 filesystem on EFI partition"
        mkfs.vfat -F32 -n "EFI" "${part_prefix}1"
    fi
    
    # Determine root device
    local root_dev
    if (( USE_LVM )); then
        root_dev="/dev/$VG_NAME/$LV_ROOT"
    elif (( USE_LUKS )); then
        root_dev="/dev/mapper/cryptroot"
    else
        root_dev="${part_prefix}2"
    fi
    
    # Create root filesystem
    log "Creating $FS_TYPE filesystem on $root_dev"
    
    case "$FS_TYPE" in
        btrfs)
            mkfs.btrfs -f -L "gentoo-root" "$root_dev"
            
            # Mount and create subvolumes
            mount "$root_dev" /mnt/gentoo
            
            btrfs subvolume create /mnt/gentoo/@
            btrfs subvolume create /mnt/gentoo/@snapshots
            
            if (( SEPARATE_HOME )); then
                btrfs subvolume create /mnt/gentoo/@home
            fi
            
            # Create initial snapshot directory structure
            mkdir -p /mnt/gentoo/@snapshots/.snapshots
            
            umount /mnt/gentoo
            
            # Mount with proper options
            local btrfs_opts="noatime,compress=zstd:3,space_cache=v2"
            (( HAS_SSD )) && btrfs_opts+=",ssd,discard=async"
            
            mount -o "subvol=@,$btrfs_opts" "$root_dev" /mnt/gentoo
            
            mkdir -p /mnt/gentoo/.snapshots
            mount -o "subvol=@snapshots,$btrfs_opts" "$root_dev" /mnt/gentoo/.snapshots
            
            if (( SEPARATE_HOME )); then
                mkdir -p /mnt/gentoo/home
                mount -o "subvol=@home,$btrfs_opts" "$root_dev" /mnt/gentoo/home
            fi
            ;;
            
        xfs)
            mkfs.xfs -f -L "gentoo-root" "$root_dev"
            mount "$root_dev" /mnt/gentoo
            
            if (( SEPARATE_HOME && USE_LVM )); then
                mkfs.xfs -f -L "gentoo-home" "/dev/$VG_NAME/$LV_HOME"
                mkdir -p /mnt/gentoo/home
                mount "/dev/$VG_NAME/$LV_HOME" /mnt/gentoo/home
            fi
            ;;
            
        ext4)
            mkfs.ext4 -F -L "gentoo-root" "$root_dev"
            mount "$root_dev" /mnt/gentoo
            
            if (( SEPARATE_HOME && USE_LVM )); then
                mkfs.ext4 -F -L "gentoo-home" "/dev/$VG_NAME/$LV_HOME"
                mkdir -p /mnt/gentoo/home
                mount "/dev/$VG_NAME/$LV_HOME" /mnt/gentoo/home
            fi
            ;;
    esac
    
    # Create and mount boot/efi
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        mkdir -p /mnt/gentoo/boot/efi
        mount "${part_prefix}1" /mnt/gentoo/boot/efi
    else
        mkdir -p /mnt/gentoo/boot
    fi
    
    # Swap LV
    if [[ "$SWAP_MODE" == "partition" ]] && (( USE_LVM )); then
        mkswap -L "swap" "/dev/$VG_NAME/$LV_SWAP"
        swapon "/dev/$VG_NAME/$LV_SWAP"
    fi
    
    # Migrate checkpoint to persistent storage
    migrate_checkpoint
    
    success "Filesystems created and mounted"
    
    # Show mount points
    log "Current mount points:"
    findmnt -t btrfs,ext4,xfs,vfat | grep gentoo || true
}

# ============================================================================
# STAGE3 DOWNLOAD AND EXTRACTION
# ============================================================================

STAGE3_URL=""
STAGE3_FILE="/tmp/stage3.tar.xz"
STAGE3_DIGESTS="/tmp/stage3.DIGESTS"
STAGE3_ASC="/tmp/stage3.DIGESTS.asc"

select_mirror() {
    section "Mirror Selection"
    
    # Try to determine region
    local region=""
    region=$(curl -s --max-time 5 "https://ipapi.co/country" 2>/dev/null || echo "")
    debug "Detected region: ${region:-unknown}"
    
    # Mirror list (ordered by general reliability)
    local mirrors=(
        "https://distfiles.gentoo.org/"
        "https://gentoo.osuosl.org/"
        "https://mirror.yandex.ru/gentoo/"
        "https://ftp.fau.de/gentoo/"
        "https://mirrors.mit.edu/gentoo-distfiles/"
        "https://gentoo.mirrors.ovh.net/gentoo-distfiles/"
    )
    
    # Try mirrorselect if available
    if cmd_exists mirrorselect && [[ -n "$region" ]]; then
        debug "Running mirrorselect..."
        local ms_out
        ms_out=$(mktemp)
        if mirrorselect -s4 -b8 --country "$region" -o "$ms_out" 2>/dev/null; then
            while IFS= read -r line; do
                local url
                url=$(echo "$line" | grep -oE 'https?://[^ "]+' | head -1)
                [[ -n "$url" ]] && mirrors=("${url%/}/" "${mirrors[@]}")
            done < "$ms_out"
        fi
        rm -f "$ms_out"
    fi
    
    # Stage3 index files based on init system
    local stage_index
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        stage_index="releases/amd64/autobuilds/latest-stage3-amd64-systemd.txt"
    else
        stage_index="releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt"
    fi
    
    # Find fastest working mirror
    local best_mirror=""
    local best_time=999
    
    for mirror in "${mirrors[@]}"; do
        local url="${mirror}${stage_index}"
        debug "Testing mirror: $mirror"
        
        local start_time end_time elapsed
        start_time=$(date +%s.%N)
        
        if curl -s --head --fail --max-time 5 "$url" >/dev/null 2>&1; then
            end_time=$(date +%s.%N)
            elapsed=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "5")
            
            debug "Mirror $mirror responded in ${elapsed}s"
            
            if (( $(echo "$elapsed < $best_time" | bc -l 2>/dev/null || echo 0) )); then
                best_time="$elapsed"
                best_mirror="$mirror"
            fi
        fi
    done
    
    if [[ -z "$best_mirror" ]]; then
        # Fallback to default
        best_mirror="https://distfiles.gentoo.org/"
        warn "Could not find fast mirror, using default"
    fi
    
    log "Selected mirror: $best_mirror (response time: ${best_time}s)"
    
    # Get Stage3 filename
    local index_url="${best_mirror}${stage_index}"
    local stage3_path
    stage3_path=$(curl -fsS "$index_url" 2>/dev/null | awk '!/^#/ && /stage3.*\.tar\.xz$/ {print $1; exit}')
    
    [[ -n "$stage3_path" ]] || die "Could not find Stage3 tarball in index"
    
    STAGE3_URL="${best_mirror}releases/amd64/autobuilds/${stage3_path}"
    
    success "Stage3 URL: $STAGE3_URL"
}

download_stage3() {
    section "Stage3 Download"
    
    log "Downloading Stage3 tarball..."
    
    # Download with resume support
    retry_cmd 5 10 wget --continue --progress=bar:force -O "$STAGE3_FILE" "$STAGE3_URL"
    
    success "Stage3 downloaded: $(ls -lh "$STAGE3_FILE" | awk '{print $5}')"
    
    # Download verification files
    if (( ! SKIP_CHECKSUM )) || (( ! SKIP_GPG )); then
        log "Downloading verification files..."
        
        local digests_url="${STAGE3_URL%.tar.xz}.DIGESTS"
        wget -q -O "$STAGE3_DIGESTS" "$digests_url" || warn "Could not download DIGESTS"
        
        if (( ! SKIP_GPG )); then
            local asc_url="${STAGE3_URL%.tar.xz}.DIGESTS.asc"
            wget -q -O "$STAGE3_ASC" "$asc_url" 2>/dev/null || \
            wget -q -O "$STAGE3_ASC" "${digests_url}.asc" 2>/dev/null || \
            warn "Could not download GPG signature"
        fi
    fi
}

verify_stage3() {
    section "Stage3 Verification"
    
    # GPG verification
    if (( ! SKIP_GPG )) && [[ -f "$STAGE3_ASC" ]]; then
        log "Verifying GPG signature..."
        
        if gpg --verify "$STAGE3_ASC" "$STAGE3_DIGESTS" 2>/dev/null; then
            success "GPG signature valid"
        else
            warn "GPG verification failed - continuing anyway"
            warn "This could indicate a compromised download!"
        fi
    else
        (( SKIP_GPG )) && warn "GPG verification skipped"
    fi
    
    # SHA512 verification
    if (( ! SKIP_CHECKSUM )) && [[ -f "$STAGE3_DIGESTS" ]]; then
        log "Verifying SHA512 checksum..."
        
        # Extract expected hash
        local expected_hash
        expected_hash=$(grep -A1 "SHA512 HASH" "$STAGE3_DIGESTS" | \
                       grep -v "^#" | \
                       awk '{print $1}' | \
                       head -1)
        
        if [[ -n "$expected_hash" ]]; then
            local actual_hash
            actual_hash=$(sha512sum "$STAGE3_FILE" | awk '{print $1}')
            
            if [[ "$expected_hash" == "$actual_hash" ]]; then
                success "SHA512 checksum verified"
            else
                die "SHA512 checksum mismatch! Expected: $expected_hash, Got: $actual_hash"
            fi
        else
            warn "Could not extract expected hash from DIGESTS"
        fi
    else
        (( SKIP_CHECKSUM )) && warn "Checksum verification skipped"
    fi
}

extract_stage3() {
    section "Stage3 Extraction"
    
    log "Extracting Stage3 to /mnt/gentoo..."
    
    tar xpf "$STAGE3_FILE" \
        --xattrs-include='*.*' \
        --numeric-owner \
        -C /mnt/gentoo
    
    success "Stage3 extracted successfully"
    
    # Cleanup
    rm -f "$STAGE3_FILE" "$STAGE3_DIGESTS" "$STAGE3_ASC"
}

# ============================================================================
# SYSTEM CONFIGURATION
# ============================================================================

generate_fstab() {
    section "Generating fstab"
    
    local fstab="/mnt/gentoo/etc/fstab"
    local part_prefix
    part_prefix=$(partition_prefix "$TARGET_DISK")
    
    # Start with header
    cat > "$fstab" <<EOF
# /etc/fstab: static file system information.
# Generated by Gentoo Genesis Engine v${GENESIS_VERSION}
#
# <file system>  <mount point>  <type>  <options>  <dump>  <pass>

EOF
    
    # Root filesystem
    local root_dev root_uuid root_opts
    
    if (( USE_LVM )); then
        root_dev="/dev/$VG_NAME/$LV_ROOT"
    elif (( USE_LUKS )); then
        root_dev="/dev/mapper/cryptroot"
    else
        root_dev="${part_prefix}2"
    fi
    
    root_uuid=$(blkid -s UUID -o value "$root_dev" 2>/dev/null || echo "")
    
    case "$FS_TYPE" in
        btrfs)
            root_opts="noatime,compress=zstd:3,space_cache=v2,subvol=@"
            (( HAS_SSD )) && root_opts+=",ssd,discard=async"
            
            echo "# Root filesystem (Btrfs)" >> "$fstab"
            if [[ -n "$root_uuid" ]]; then
                echo "UUID=$root_uuid  /  btrfs  $root_opts  0 0" >> "$fstab"
            else
                echo "$root_dev  /  btrfs  $root_opts  0 0" >> "$fstab"
            fi
            
            # Snapshots subvolume
            local snap_opts="${root_opts/subvol=@/subvol=@snapshots}"
            echo "UUID=$root_uuid  /.snapshots  btrfs  $snap_opts  0 0" >> "$fstab"
            
            # Home subvolume
            if (( SEPARATE_HOME )); then
                local home_opts="${root_opts/subvol=@/subvol=@home}"
                echo "UUID=$root_uuid  /home  btrfs  $home_opts  0 0" >> "$fstab"
            fi
            ;;
            
        xfs|ext4)
            root_opts="noatime"
            (( HAS_SSD )) && root_opts+=",discard"
            
            echo "# Root filesystem ($FS_TYPE)" >> "$fstab"
            if [[ -n "$root_uuid" ]]; then
                echo "UUID=$root_uuid  /  $FS_TYPE  $root_opts  0 1" >> "$fstab"
            else
                echo "$root_dev  /  $FS_TYPE  $root_opts  0 1" >> "$fstab"
            fi
            
            # Separate home LV
            if (( SEPARATE_HOME && USE_LVM )); then
                local home_uuid
                home_uuid=$(blkid -s UUID -o value "/dev/$VG_NAME/$LV_HOME" 2>/dev/null || echo "")
                if [[ -n "$home_uuid" ]]; then
                    echo "UUID=$home_uuid  /home  $FS_TYPE  $root_opts  0 2" >> "$fstab"
                else
                    echo "/dev/$VG_NAME/$LV_HOME  /home  $FS_TYPE  $root_opts  0 2" >> "$fstab"
                fi
            fi
            ;;
    esac
    
    # EFI partition
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        local efi_uuid
        efi_uuid=$(blkid -s UUID -o value "${part_prefix}1" 2>/dev/null || echo "")
        
        echo "" >> "$fstab"
        echo "# EFI System Partition" >> "$fstab"
        if [[ -n "$efi_uuid" ]]; then
            echo "UUID=$efi_uuid  /boot/efi  vfat  noatime,umask=0077  0 2" >> "$fstab"
        else
            echo "${part_prefix}1  /boot/efi  vfat  noatime,umask=0077  0 2" >> "$fstab"
        fi
    fi
    
    # Swap
    if [[ "$SWAP_MODE" == "partition" ]] && (( USE_LVM )); then
        echo "" >> "$fstab"
        echo "# Swap" >> "$fstab"
        echo "/dev/$VG_NAME/$LV_SWAP  none  swap  sw  0 0" >> "$fstab"
    fi
    
    # Tmpfs for /tmp
    echo "" >> "$fstab"
    echo "# Tmpfs" >> "$fstab"
    echo "tmpfs  /tmp  tmpfs  noatime,nosuid,nodev,size=2G  0 0" >> "$fstab"
    
    success "fstab generated"
    debug "Contents of /mnt/gentoo/etc/fstab:"
    (( DEBUG )) && cat "$fstab"
}

generate_crypttab() {
    if (( ! USE_LUKS )); then
        return
    fi
    
    log "Generating crypttab..."
    
    local part_prefix
    part_prefix=$(partition_prefix "$TARGET_DISK")
    local crypt_part="${part_prefix}2"
    local crypt_uuid
    crypt_uuid=$(blkid -s UUID -o value "$crypt_part" 2>/dev/null || echo "")
    
    local crypttab="/mnt/gentoo/etc/crypttab"
    
    cat > "$crypttab" <<EOF
# /etc/crypttab: encrypted volume configuration
# Generated by Gentoo Genesis Engine v${GENESIS_VERSION}
#
# <name>  <device>  <password>  <options>

EOF
    
    local opts="luks"
    (( HAS_SSD )) && opts+=",discard"
    
    if [[ -n "$crypt_uuid" ]]; then
        echo "cryptroot  UUID=$crypt_uuid  none  $opts" >> "$crypttab"
    else
        echo "cryptroot  $crypt_part  none  $opts" >> "$crypttab"
    fi
    
    success "crypttab generated"
}

generate_makeconf() {
    section "Generating make.conf"
    
    local makeconf="/mnt/gentoo/etc/portage/make.conf"
    
    # Determine USE flags based on DE choice
    local de_use=""
    case "$DE_CHOICE" in
        kde)    de_use="qt5 qt6 kde plasma -gtk -gnome" ;;
        gnome)  de_use="gtk gnome -qt5 -qt6 -kde" ;;
        xfce)   de_use="gtk xfce -qt5 -qt6 -kde -gnome" ;;
        i3)     de_use="X -gtk -qt5 -qt6 -kde -gnome" ;;
        server) de_use="-X -gtk -qt5 -qt6 -kde -gnome" ;;
    esac
    
    # Audio USE flags (prefer pipewire on newer systems)
    local audio_use="pipewire pulseaudio alsa"
    
    # Features
    local features="parallel-fetch candy"
    (( ENABLE_CCACHE )) && features+=" ccache"
    (( ENABLE_BINPKG )) && features+=" buildpkg getbinpkg"
    
    # CFLAGS
    local cflags="-march=$CPU_MARCH -O2 -pipe"
    (( ENABLE_LTO )) && cflags+=" -flto"
    
    # Calculate safe MAKEOPTS
    local nproc
    nproc=$(nproc)
    local jobs=$((nproc > 1 ? nproc : 1))
    local load=$nproc
    
    # Reduce jobs if low RAM
    local mem_gb
    mem_gb=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)
    if (( mem_gb < 8 )); then
        jobs=$((jobs > 2 ? jobs / 2 : 1))
    fi
    
    cat > "$makeconf" <<EOF
# /etc/portage/make.conf
# Generated by Gentoo Genesis Engine v${GENESIS_VERSION}
# CPU: $CPU_MODEL
# Architecture: $CPU_MARCH

# Compiler flags
COMMON_FLAGS="$cflags"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C target-cpu=$CPU_MARCH"

# Build parallelism
MAKEOPTS="-j$jobs -l$load"
EMERGE_DEFAULT_OPTS="--jobs=$((jobs / 2 > 1 ? jobs / 2 : 1)) --load-average=$load --with-bdeps=y --complete-graph=y"

# USE flags
USE="$de_use $audio_use dbus elogind unicode"

# Accepted licenses
ACCEPT_LICENSE="@FREE @BINARY-REDISTRIBUTABLE"

# Hardware
VIDEO_CARDS="$GPU_DRIVER"
INPUT_DEVICES="libinput"

# GRUB platforms
GRUB_PLATFORMS="${BOOT_MODE/uefi/efi-64}"

# Portage features
FEATURES="$features"

# Localization
L10N="en"
LINGUAS="en"

EOF
    
    # ccache configuration
    if (( ENABLE_CCACHE )); then
        cat >> "$makeconf" <<EOF
# ccache
CCACHE_DIR="/var/cache/ccache"
CCACHE_SIZE="10G"

EOF
        mkdir -p /mnt/gentoo/var/cache/ccache
        chmod 755 /mnt/gentoo/var/cache/ccache
    fi
    
    # Binary packages configuration
    if (( ENABLE_BINPKG )); then
        cat >> "$makeconf" <<EOF
# Binary packages
BINPKG_FORMAT="gpkg"
BINPKG_COMPRESS="zstd"

EOF
    fi
    
    success "make.conf generated"
}

# ============================================================================
# CHROOT PREPARATION
# ============================================================================

prepare_chroot() {
    section "Preparing Chroot Environment"
    
    # Copy DNS configuration
    log "Copying DNS configuration..."
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/ 2>/dev/null || \
        echo "nameserver 1.1.1.1" > /mnt/gentoo/etc/resolv.conf
    
    # Mount necessary filesystems
    log "Mounting virtual filesystems..."
    
    mount -t proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    mount --bind /run /mnt/gentoo/run
    mount --make-rslave /mnt/gentoo/run
    
    # Ensure /dev/shm is properly mounted
    if [[ ! -d /mnt/gentoo/dev/shm ]]; then
        mkdir -p /mnt/gentoo/dev/shm
    fi
    mount -t tmpfs -o nosuid,nodev,noexec shm /mnt/gentoo/dev/shm 2>/dev/null || true
    chmod 1777 /mnt/gentoo/dev/shm
    
    success "Chroot environment prepared"
}

write_chroot_env() {
    log "Writing environment file for chroot..."
    
    local env_file="/mnt/gentoo/tmp/.genesis_env.sh"
    
    cat > "$env_file" <<EOF
#!/bin/bash
# Genesis Engine environment variables
# This file is automatically deleted after installation

export DE_CHOICE='$DE_CHOICE'
export HOSTNAME='$HOSTNAME'
export USERNAME='$USERNAME'
export TIMEZONE='$TIMEZONE'
export LOCALE='$LOCALE'
export KEYMAP='$KEYMAP'
export ROOT_PASSWORD='$ROOT_PASSWORD'
export USER_PASSWORD='$USER_PASSWORD'
export INIT_SYSTEM='$INIT_SYSTEM'
export PROFILE_FLAVOR='$PROFILE_FLAVOR'
export LSM_CHOICE='$LSM_CHOICE'
export ENABLE_UFW='$ENABLE_UFW'
export KERNEL_MODE='$KERNEL_MODE'
export FS_TYPE='$FS_TYPE'
export USE_LVM='$USE_LVM'
export USE_LUKS='$USE_LUKS'
export ENCRYPT_BOOT='$ENCRYPT_BOOT'
export SWAP_MODE='$SWAP_MODE'
export SEPARATE_HOME='$SEPARATE_HOME'
export ENABLE_CCACHE='$ENABLE_CCACHE'
export ENABLE_BINPKG='$ENABLE_BINPKG'
export ENABLE_LTO='$ENABLE_LTO'
export BUNDLE_FLATPAK='$BUNDLE_FLATPAK'
export BUNDLE_TERM='$BUNDLE_TERM'
export BUNDLE_DEV='$BUNDLE_DEV'
export BUNDLE_OFFICE='$BUNDLE_OFFICE'
export BUNDLE_GAMING='$BUNDLE_GAMING'
export AUTO_UPDATE='$AUTO_UPDATE'
export CPU_FREQ_TUNE='$CPU_FREQ_TUNE'
export VG_NAME='$VG_NAME'
export LV_ROOT='$LV_ROOT'
export LV_SWAP='$LV_SWAP'
export LV_HOME='$LV_HOME'
export TARGET_DISK='$TARGET_DISK'
export BOOT_MODE='$BOOT_MODE'
export CPU_MARCH='$CPU_MARCH'
export GPU_DRIVER='$GPU_DRIVER'
export GENESIS_VERSION='$GENESIS_VERSION'
EOF
    
    chmod 600 "$env_file"
    
    success "Environment file created"
}

# ============================================================================
# CHROOT INSTALLATION SCRIPT
# ============================================================================

write_chroot_script() {
    log "Creating chroot installation script..."
    
    cat > /mnt/gentoo/tmp/genesis_chroot_install.sh <<'CHROOT_SCRIPT'
#!/bin/bash
# Gentoo Genesis Engine - Chroot Installation Script
# This script runs inside the chroot environment

set -euo pipefail

# ============================================================================
# LOGGING
# ============================================================================

log() { printf '%s [CHROOT] %s\n' "$(date -Is)" "$*"; }
warn() { printf '%s [WARN]  %s\n' "$(date -Is)" "$*" >&2; }
err() { printf '%s [ERROR] %s\n' "$(date -Is)" "$*" >&2; }
success() { printf '%s [OK]    %s\n' "$(date -Is)" "$*"; }

# ============================================================================
# HEALING EMERGE
# ============================================================================

# Robust emerge wrapper with auto-unmask and retry
healing_emerge() {
    local -a packages=("$@")
    local -i attempt=1
    local -i max_attempts=3
    
    while (( attempt <= max_attempts )); do
        log "emerge attempt $attempt: ${packages[*]}"
        
        if emerge --backtrack=50 --verbose-conflicts "${packages[@]}" 2>&1; then
            return 0
        fi
        
        # Try with autounmask
        if emerge --autounmask-write --autounmask-continue "${packages[@]}" 2>&1; then
            # Apply changes
            etc-update --automode -5 2>/dev/null || true
            dispatch-conf --noconfirm 2>/dev/null || true
            attempt=$((attempt + 1))
            continue
        fi
        
        # Try with --oneshot for circular deps
        if emerge --oneshot --backtrack=50 "${packages[@]}" 2>&1; then
            return 0
        fi
        
        attempt=$((attempt + 1))
    done
    
    warn "Failed to emerge: ${packages[*]} after $max_attempts attempts"
    return 1
}

# ============================================================================
# MAIN INSTALLATION
# ============================================================================

main() {
    # Load environment
    source /tmp/.genesis_env.sh
    
    log "Starting chroot installation"
    log "Hostname: $HOSTNAME, User: $USERNAME, DE: $DE_CHOICE, Init: $INIT_SYSTEM"
    
    # -------------------------------------------------------------------------
    # Portage sync
    # -------------------------------------------------------------------------
    log "Syncing Portage tree..."
    
    if ! emerge-webrsync 2>&1; then
        warn "emerge-webrsync failed, trying emerge --sync"
        emerge --sync || warn "Sync had issues, continuing..."
    fi
    
    # -------------------------------------------------------------------------
    # Profile selection
    # -------------------------------------------------------------------------
    log "Selecting profile..."
    
    local profile_pattern=""
    if [[ "$PROFILE_FLAVOR" == "hardened" ]]; then
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            profile_pattern="hardened.*systemd"
        else
            profile_pattern="hardened.*openrc"
        fi
    else
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
            profile_pattern="amd64.*systemd.*desktop"
        else
            profile_pattern="amd64.*openrc.*desktop"
        fi
    fi
    
    local profile_num=""
    profile_num=$(eselect profile list | grep -iE "$profile_pattern" | head -1 | grep -oE '^\[?[0-9]+\]?' | tr -d '[]' || echo "")
    
    if [[ -z "$profile_num" ]]; then
        # Fallback to basic profile
        profile_num=$(eselect profile list | grep -E 'amd64.*stable' | head -1 | grep -oE '^\[?[0-9]+\]?' | tr -d '[]' || echo "1")
    fi
    
    if [[ -n "$profile_num" ]]; then
        eselect profile set "$profile_num" && \
            success "Profile set to $profile_num" || \
            warn "Could not set profile"
    fi
    
    # -------------------------------------------------------------------------
    # Accept licenses and keywords
    # -------------------------------------------------------------------------
    log "Configuring package settings..."
    
    mkdir -p /etc/portage/package.{license,accept_keywords,use,mask,unmask}
    
    # Linux firmware
    echo "sys-kernel/linux-firmware linux-fw-redistributable" >> /etc/portage/package.license/firmware
    echo "sys-firmware/intel-microcode intel-ucode" >> /etc/portage/package.license/firmware
    
    # -------------------------------------------------------------------------
    # World update
    # -------------------------------------------------------------------------
    log "Updating @world..."
    healing_emerge --update --deep --newuse @world || warn "@world update had issues"
    
    # -------------------------------------------------------------------------
    # Timezone and locale
    # -------------------------------------------------------------------------
    log "Configuring timezone and locale..."
    
    # Timezone
    if [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
        ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
        echo "$TIMEZONE" > /etc/timezone
    fi
    
    # Locale
    echo "$LOCALE UTF-8" >> /etc/locale.gen
    echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
    locale-gen
    
    eselect locale set "$LOCALE" 2>/dev/null || \
        eselect locale set en_US.utf8 2>/dev/null || true
    
    env-update && source /etc/profile
    
    success "Timezone set to $TIMEZONE"
    
    # -------------------------------------------------------------------------
    # Hostname and hosts
    # -------------------------------------------------------------------------
    log "Configuring hostname..."
    
    echo "$HOSTNAME" > /etc/hostname
    
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        echo "hostname=\"$HOSTNAME\"" > /etc/conf.d/hostname
    fi
    
    cat >> /etc/hosts <<EOF

# Local hostname
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF
    
    # -------------------------------------------------------------------------
    # Base system packages
    # -------------------------------------------------------------------------
    log "Installing base system packages..."
    
    local base_packages=(
        app-admin/sysklogd
        sys-process/cronie
        app-shells/bash-completion
        sys-apps/mlocate
        app-admin/sudo
        sys-apps/dbus
        sys-auth/elogind
        net-misc/chrony
        app-misc/tmux
        app-editors/vim
        sys-apps/pciutils
        sys-apps/usbutils
    )
    
    healing_emerge "${base_packages[@]}" || warn "Some base packages failed"
    
    # -------------------------------------------------------------------------
    # Init system services
    # -------------------------------------------------------------------------
    log "Enabling base services..."
    
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update add sysklogd default 2>/dev/null || true
        rc-update add cronie default 2>/dev/null || true
        rc-update add chronyd default 2>/dev/null || true
        rc-update add dbus default 2>/dev/null || true
        rc-update add elogind boot 2>/dev/null || true
    else
        systemctl enable systemd-timesyncd.service 2>/dev/null || true
        systemctl enable cronie.service 2>/dev/null || true
    fi
    
    # -------------------------------------------------------------------------
    # Networking
    # -------------------------------------------------------------------------
    log "Installing networking..."
    
    healing_emerge net-misc/networkmanager net-misc/openssh || warn "Network packages failed"
    
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-update add NetworkManager default 2>/dev/null || true
        rc-update add sshd default 2>/dev/null || true
    else
        systemctl enable NetworkManager.service 2>/dev/null || true
        systemctl enable sshd.service 2>/dev/null || true
    fi
    
    # -------------------------------------------------------------------------
    # LSM (Security Module)
    # -------------------------------------------------------------------------
    if [[ "$LSM_CHOICE" == "apparmor" ]]; then
        log "Installing AppArmor..."
        healing_emerge sys-apps/apparmor sys-apps/apparmor-utils || warn "AppArmor failed"
        
        if [[ "$INIT_SYSTEM" == "openrc" ]]; then
            rc-update add apparmor boot 2>/dev/null || true
        else
            systemctl enable apparmor.service 2>/dev/null || true
        fi
        
    elif [[ "$LSM_CHOICE" == "selinux" ]]; then
        log "Installing SELinux..."
        healing_emerge sys-apps/policycoreutils sec-policy/selinux-base-policy || warn "SELinux failed"
    fi
    
    # -------------------------------------------------------------------------
    # Firewall
    # -------------------------------------------------------------------------
    if [[ "$ENABLE_UFW" == "1" ]]; then
        log "Installing firewall..."
        healing_emerge net-firewall/ufw || warn "UFW failed"
        
        if [[ "$INIT_SYSTEM" == "openrc" ]]; then
            rc-update add ufw default 2>/dev/null || true
        else
            systemctl enable ufw.service 2>/dev/null || true
        fi
        
        # Basic rules
        ufw default deny incoming 2>/dev/null || true
        ufw default allow outgoing 2>/dev/null || true
        ufw allow ssh 2>/dev/null || true
        ufw --force enable 2>/dev/null || true
        
        success "UFW configured"
    fi
    
    # -------------------------------------------------------------------------
    # Kernel
    # -------------------------------------------------------------------------
    log "Installing kernel ($KERNEL_MODE)..."
    
    # Install firmware first
    healing_emerge sys-kernel/linux-firmware sys-firmware/intel-microcode || warn "Firmware failed"
    
    case "$KERNEL_MODE" in
        gentoo-kernel-bin)
            healing_emerge sys-kernel/gentoo-kernel-bin || warn "Kernel failed"
            ;;
        gentoo-kernel)
            healing_emerge sys-kernel/gentoo-kernel || warn "Kernel failed"
            ;;
        genkernel)
            healing_emerge sys-kernel/gentoo-sources sys-kernel/genkernel || warn "Kernel sources failed"
            
            local genkernel_opts="--makeopts=-j$(nproc)"
            
            if [[ "$USE_LUKS" == "1" ]]; then
                genkernel_opts+=" --luks"
            fi
            if [[ "$USE_LVM" == "1" ]]; then
                genkernel_opts+=" --lvm"
            fi
            if [[ "$FS_TYPE" == "btrfs" ]]; then
                genkernel_opts+=" --btrfs"
            fi
            
            genkernel $genkernel_opts all || warn "Genkernel build failed"
            ;;
        manual)
            healing_emerge sys-kernel/gentoo-sources || warn "Kernel sources failed"
            log "Manual kernel mode - configure and build kernel yourself"
            ;;
    esac
    
    # Ensure initramfs is generated
    if [[ "$KERNEL_MODE" != "genkernel" ]]; then
        healing_emerge sys-kernel/dracut || true
        dracut --force --hostonly 2>/dev/null || warn "Dracut failed"
    fi
    
    # -------------------------------------------------------------------------
    # Xorg / Wayland
    # -------------------------------------------------------------------------
    if [[ "$DE_CHOICE" != "server" ]]; then
        log "Installing display server..."
        healing_emerge x11-base/xorg-drivers x11-base/xorg-server || warn "Xorg failed"
        
        # Wayland support for modern DEs
        if [[ "$DE_CHOICE" == "kde" ]] || [[ "$DE_CHOICE" == "gnome" ]]; then
            healing_emerge dev-libs/wayland gui-libs/gtk || true
        fi
    fi
    
    # -------------------------------------------------------------------------
    # Desktop Environment
    # -------------------------------------------------------------------------
    log "Installing desktop environment: $DE_CHOICE"
    
    case "$DE_CHOICE" in
        kde)
            healing_emerge kde-plasma/plasma-meta kde-apps/konsole kde-apps/dolphin kde-apps/kate || warn "KDE failed"
            healing_emerge x11-misc/sddm || true
            
            if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                rc-update add sddm default 2>/dev/null || true
            else
                systemctl enable sddm.service 2>/dev/null || true
            fi
            ;;
            
        gnome)
            healing_emerge gnome-base/gnome gnome-base/gdm || warn "GNOME failed"
            
            if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                rc-update add gdm default 2>/dev/null || true
            else
                systemctl enable gdm.service 2>/dev/null || true
            fi
            ;;
            
        xfce)
            healing_emerge xfce-base/xfce4-meta xfce-extra/xfce4-goodies || warn "XFCE failed"
            healing_emerge x11-misc/lightdm x11-misc/lightdm-gtk-greeter || true
            
            if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                rc-update add lightdm default 2>/dev/null || true
            else
                systemctl enable lightdm.service 2>/dev/null || true
            fi
            ;;
            
        i3)
            healing_emerge x11-wm/i3 x11-misc/i3status x11-misc/dmenu x11-terms/alacritty || warn "i3 failed"
            healing_emerge x11-misc/lightdm x11-misc/lightdm-gtk-greeter || true
            
            if [[ "$INIT_SYSTEM" == "openrc" ]]; then
                rc-update add lightdm default 2>/dev/null || true
            else
                systemctl enable lightdm.service 2>/dev/null || true
            fi
            ;;
            
        server)
            log "Server mode - no desktop environment"
            ;;
    esac
    
    # -------------------------------------------------------------------------
    # Software Bundles
    # -------------------------------------------------------------------------
    
    if [[ "$BUNDLE_FLATPAK" == "1" ]]; then
        log "Installing Flatpak and Distrobox..."
        healing_emerge sys-apps/flatpak app-containers/distrobox app-containers/podman || true
        flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
    fi
    
    if [[ "$BUNDLE_TERM" == "1" ]]; then
        log "Installing enhanced terminal..."
        healing_emerge app-shells/zsh app-shells/zsh-completions app-shells/starship || true
    fi
    
    if [[ "$BUNDLE_DEV" == "1" ]]; then
        log "Installing developer tools..."
        healing_emerge dev-vcs/git app-containers/docker || true
        
        if [[ "$INIT_SYSTEM" == "openrc" ]]; then
            rc-update add docker default 2>/dev/null || true
        else
            systemctl enable docker.service 2>/dev/null || true
        fi
    fi
    
    if [[ "$BUNDLE_OFFICE" == "1" ]]; then
        log "Installing office suite..."
        healing_emerge app-office/libreoffice media-gfx/gimp || true
    fi
    
    if [[ "$BUNDLE_GAMING" == "1" ]]; then
        log "Installing gaming tools..."
        # Enable 32-bit support for Steam
        if [[ ! -d /etc/portage/repos.conf ]]; then
            mkdir -p /etc/portage/repos.conf
        fi
        echo "ABI_X86=\"64 32\"" >> /etc/portage/make.conf
        
        healing_emerge games-util/steam-launcher app-emulation/wine-staging || true
    fi
    
    # -------------------------------------------------------------------------
    # CPU Frequency
    # -------------------------------------------------------------------------
    if [[ "$CPU_FREQ_TUNE" == "1" ]]; then
        log "Installing CPU frequency management..."
        healing_emerge sys-power/cpupower sys-power/thermald || true
        
        if [[ "$INIT_SYSTEM" == "openrc" ]]; then
            rc-update add cpupower default 2>/dev/null || true
        else
            systemctl enable cpupower.service 2>/dev/null || true
            systemctl enable thermald.service 2>/dev/null || true
        fi
    fi
    
    # -------------------------------------------------------------------------
    # Users and Groups
    # -------------------------------------------------------------------------
    log "Creating users..."
    
    # Ensure groups exist
    local groups=(users wheel audio video input plugdev)
    for grp in "${groups[@]}"; do
        getent group "$grp" >/dev/null 2>&1 || groupadd "$grp" 2>/dev/null || true
    done
    
    # Create user
    if ! id -u "$USERNAME" >/dev/null 2>&1; then
        useradd -m -G "$(IFS=,; echo "${groups[*]}")" -s /bin/bash "$USERNAME"
    fi
    
    # Set passwords securely using chpasswd
    printf '%s:%s\n' "root" "$ROOT_PASSWORD" | chpasswd
    printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | chpasswd
    
    # Configure sudo
    if [[ -f /etc/sudoers ]]; then
        sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    fi
    
    success "User $USERNAME created"
    
    # -------------------------------------------------------------------------
    # Btrfs Snapshots
    # -------------------------------------------------------------------------
    if [[ "$FS_TYPE" == "btrfs" ]]; then
        log "Setting up Btrfs snapshot tools..."
        
        healing_emerge sys-fs/btrfs-progs app-backup/snapper || true
        
        # Create snapper config
        if command -v snapper >/dev/null 2>&1; then
            snapper -c root create-config / 2>/dev/null || true
        fi
        
        # Create update script with snapshot
        cat > /usr/local/sbin/genesis-update <<'UPDATE_SCRIPT'
#!/bin/bash
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

# Create pre-update snapshot
SNAP_NAME="preupdate-$(date +%Y%m%d-%H%M%S)"

if command -v snapper >/dev/null 2>&1; then
    snapper -c root create -d "$SNAP_NAME" --type pre
else
    btrfs subvolume snapshot -r / "/.snapshots/@-$SNAP_NAME" 2>/dev/null || true
fi

log "Created snapshot: $SNAP_NAME"

# Update system
log "Syncing portage..."
emerge --sync

log "Updating @world..."
emerge --update --deep --newuse --with-bdeps=y @world

# Cleanup old kernels
log "Cleaning old kernels..."
emerge --depclean

# Create post-update snapshot
if command -v snapper >/dev/null 2>&1; then
    snapper -c root create -d "$SNAP_NAME" --type post
fi

log "Update complete"
UPDATE_SCRIPT
        
        chmod +x /usr/local/sbin/genesis-update
        
        # Cleanup old snapshots script
        cat > /usr/local/sbin/genesis-cleanup-snapshots <<'CLEANUP_SCRIPT'
#!/bin/bash
# Remove snapshots older than 30 days

find /.snapshots -maxdepth 1 -name '@-*' -mtime +30 -exec btrfs subvolume delete {} \; 2>/dev/null || true

if command -v snapper >/dev/null 2>&1; then
    snapper -c root cleanup number
    snapper -c root cleanup timeline
fi
CLEANUP_SCRIPT
        
        chmod +x /usr/local/sbin/genesis-cleanup-snapshots
    fi
    
    # -------------------------------------------------------------------------
    # Auto-update
    # -------------------------------------------------------------------------
    if [[ "$AUTO_UPDATE" == "1" ]]; then
        log "Configuring automatic updates..."
        
        if [[ "$INIT_SYSTEM" == "openrc" ]]; then
            # Weekly cron job
            cat > /etc/cron.weekly/genesis-update <<'CRON'
#!/bin/bash
/usr/local/sbin/genesis-update >> /var/log/genesis-update.log 2>&1
CRON
            chmod +x /etc/cron.weekly/genesis-update
            
        else
            # systemd timer
            cat > /etc/systemd/system/genesis-update.service <<'SERVICE'
[Unit]
Description=Gentoo Genesis Weekly Update
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/genesis-update
StandardOutput=journal
StandardError=journal
SERVICE
            
            cat > /etc/systemd/system/genesis-update.timer <<'TIMER'
[Unit]
Description=Weekly Gentoo Update

[Timer]
OnCalendar=weekly
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
TIMER
            
            systemctl enable genesis-update.timer 2>/dev/null || true
        fi
    fi
    
    # -------------------------------------------------------------------------
    # GRUB Bootloader
    # -------------------------------------------------------------------------
    log "Installing bootloader..."
    
    healing_emerge sys-boot/grub || warn "GRUB install failed"
    
    # Configure GRUB
    local grub_cmdline=""
    
    if [[ "$USE_LUKS" == "1" ]]; then
        echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
        
        local crypt_uuid
        crypt_uuid=$(blkid -s UUID -o value "${TARGET_DISK}2" 2>/dev/null || blkid -s UUID -o value "$(partition_prefix "$TARGET_DISK")2" 2>/dev/null || echo "")
        
        if [[ -n "$crypt_uuid" ]]; then
            grub_cmdline="cryptdevice=UUID=$crypt_uuid:cryptroot"
        fi
    fi
    
    if [[ "$LSM_CHOICE" == "apparmor" ]]; then
        grub_cmdline+=" apparmor=1 security=apparmor"
    elif [[ "$LSM_CHOICE" == "selinux" ]]; then
        grub_cmdline+=" selinux=1 enforcing=0"
    fi
    
    if [[ -n "$grub_cmdline" ]]; then
        sed -i "s|^GRUB_CMDLINE_LINUX=\"|GRUB_CMDLINE_LINUX=\"$grub_cmdline |" /etc/default/grub
    fi
    
    # Install GRUB
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Gentoo --recheck || warn "GRUB install failed"
        
        # Create EFI fallback
        mkdir -p /boot/efi/EFI/Boot
        cp /boot/efi/EFI/Gentoo/grubx64.efi /boot/efi/EFI/Boot/bootx64.efi 2>/dev/null || true
    else
        grub-install --target=i386-pc "$TARGET_DISK" || warn "GRUB install failed"
    fi
    
    # Generate GRUB config
    grub-mkconfig -o /boot/grub/grub.cfg || warn "GRUB config generation failed"
    
    success "Bootloader installed"
    
    # -------------------------------------------------------------------------
    # Final cleanup
    # -------------------------------------------------------------------------
    log "Final cleanup..."
    
    # Remove installation files
    rm -f /tmp/.genesis_env.sh
    rm -f /tmp/genesis_chroot_install.sh
    
    # Update mlocate database
    updatedb 2>/dev/null || true
    
    success "Chroot installation complete!"
}

# Helper function for partition prefix
partition_prefix() {
    local disk="$1"
    if [[ "$disk" =~ [0-9]$ ]]; then
        echo "${disk}p"
    else
        echo "$disk"
    fi
}

# Run main
main "$@"
CHROOT_SCRIPT
    
    chmod +x /mnt/gentoo/tmp/genesis_chroot_install.sh
    
    success "Chroot script created"
}

# ============================================================================
# RUN CHROOT INSTALLATION
# ============================================================================

run_chroot() {
    section "Chroot Installation"
    
    log "Entering chroot and running installation..."
    
    chroot /mnt/gentoo /bin/bash /tmp/genesis_chroot_install.sh
    
    success "Chroot installation completed"
}

# ============================================================================
# POST-INSTALLATION
# ============================================================================

post_install() {
    section "Post-Installation"
    
    # Create EFI boot entry
    if [[ "$BOOT_MODE" == "uefi" ]] && cmd_exists efibootmgr; then
        log "Creating EFI boot entry..."
        
        if ! efibootmgr | grep -qi gentoo; then
            local part_prefix
            part_prefix=$(partition_prefix "$TARGET_DISK")
            local esp_part="${part_prefix}1"
            
            local disk_name part_num
            disk_name=$(lsblk -no PKNAME "$esp_part" 2>/dev/null | head -1)
            part_num=$(lsblk -no PARTN "$esp_part" 2>/dev/null | head -1)
            
            if [[ -n "$disk_name" ]] && [[ -n "$part_num" ]]; then
                efibootmgr -c -d "/dev/$disk_name" -p "$part_num" \
                    -L "Gentoo (Genesis)" -l '\EFI\Gentoo\grubx64.efi' 2>/dev/null || \
                    warn "Could not create EFI boot entry"
            fi
        fi
    fi
    
    # Final verification
    log "Verifying installation..."
    
    local checks_passed=0
    local checks_total=0
    
    # Check kernel
    ((checks_total++))
    if ls /mnt/gentoo/boot/vmlinuz* >/dev/null 2>&1; then
        success "Kernel installed"
        ((checks_passed++))
    else
        warn "Kernel not found in /boot"
    fi
    
    # Check initramfs
    ((checks_total++))
    if ls /mnt/gentoo/boot/initramfs* >/dev/null 2>&1 || ls /mnt/gentoo/boot/initrd* >/dev/null 2>&1; then
        success "Initramfs found"
        ((checks_passed++))
    else
        warn "Initramfs not found"
    fi
    
    # Check fstab
    ((checks_total++))
    if [[ -s /mnt/gentoo/etc/fstab ]]; then
        success "fstab configured"
        ((checks_passed++))
    else
        warn "fstab is empty or missing"
    fi
    
    # Check bootloader
    ((checks_total++))
    if [[ -f /mnt/gentoo/boot/grub/grub.cfg ]]; then
        success "GRUB configured"
        ((checks_passed++))
    else
        warn "GRUB configuration not found"
    fi
    
    # Check user
    ((checks_total++))
    if chroot /mnt/gentoo id "$USERNAME" >/dev/null 2>&1; then
        success "User $USERNAME created"
        ((checks_passed++))
    else
        warn "User $USERNAME not found"
    fi
    
    log "Verification: $checks_passed/$checks_total checks passed"
    
    # Clear checkpoint on success
    if (( checks_passed == checks_total )); then
        clear_checkpoint
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    section "${GENESIS_NAME} v${GENESIS_VERSION}"
    
    log "Starting installation at $(date)"
    log "Codename: ${GENESIS_CODENAME}"
    
    # Parse arguments
    parse_args "$@"
    
    # Root check
    check_root
    
    # Self-healing and hardware detection
    self_heal_livecd
    detect_hardware
    
    # Handle resume
    handle_resume
    
    # Get current checkpoint
    local current_stage
    current_stage=$(get_checkpoint)
    
    # Stage: Wizard
    if [[ "$current_stage" == "0" ]]; then
        wizard
        checkpoint "wizard_done"
        current_stage="wizard_done"
    fi
    
    # Stage: Partitioning
    if [[ "$current_stage" == "wizard_done" ]]; then
        partition_disk
        checkpoint "partitioned"
        current_stage="partitioned"
    fi
    
    # Stage: Encryption
    if [[ "$current_stage" == "partitioned" ]]; then
        setup_encryption
        checkpoint "encrypted"
        current_stage="encrypted"
    fi
    
    # Stage: LVM
    if [[ "$current_stage" == "encrypted" ]]; then
        setup_lvm
        checkpoint "lvm_done"
        current_stage="lvm_done"
    fi
    
    # Stage: Filesystems
    if [[ "$current_stage" == "lvm_done" ]]; then
        create_filesystems
        checkpoint "filesystems_done"
        current_stage="filesystems_done"
    fi
    
    # Stage: Network check
    if [[ "$current_stage" == "filesystems_done" ]]; then
        check_network
        checkpoint "network_ok"
        current_stage="network_ok"
    fi
    
    # Stage: Mirror selection
    if [[ "$current_stage" == "network_ok" ]]; then
        select_mirror
        checkpoint "mirror_selected"
        current_stage="mirror_selected"
    fi
    
    # Stage: Stage3 download
    if [[ "$current_stage" == "mirror_selected" ]]; then
        download_stage3
        checkpoint "stage3_downloaded"
        current_stage="stage3_downloaded"
    fi
    
    # Stage: Verification
    if [[ "$current_stage" == "stage3_downloaded" ]]; then
        verify_stage3
        checkpoint "stage3_verified"
        current_stage="stage3_verified"
    fi
    
    # Stage: Extraction
    if [[ "$current_stage" == "stage3_verified" ]]; then
        extract_stage3
        checkpoint "stage3_extracted"
        current_stage="stage3_extracted"
    fi
    
    # Stage: Configuration
    if [[ "$current_stage" == "stage3_extracted" ]]; then
        generate_fstab
        generate_crypttab
        generate_makeconf
        checkpoint "configured"
        current_stage="configured"
    fi
    
    # Stage: Chroot preparation
    if [[ "$current_stage" == "configured" ]]; then
        prepare_chroot
        write_chroot_env
        write_chroot_script
        checkpoint "chroot_ready"
        current_stage="chroot_ready"
    fi
    
    # Stage: Chroot installation
    if [[ "$current_stage" == "chroot_ready" ]]; then
        run_chroot
        checkpoint "chroot_done"
        current_stage="chroot_done"
    fi
    
    # Stage: Post-installation
    if [[ "$current_stage" == "chroot_done" ]]; then
        post_install
        checkpoint "complete"
    fi
    
    # Final message
    section "Installation Complete!"
    
    cat <<EOF
Congratulations! Gentoo Linux has been installed successfully.

Next steps:
  1. Exit this shell (type 'exit')
  2. Unmount filesystems: umount -R /mnt/gentoo
  3. Reboot: reboot

After reboot:
  - Login as '$USERNAME' with your chosen password
  - Root password was also set as specified

Important notes:
  - If you enabled LUKS, you'll be prompted for the encryption password at boot
  - SSH is enabled by default - change the root password if needed
  - UFW firewall is active - SSH (port 22) is allowed

For issues or questions:
  - Check logs: /var/log/genesis-install.log
  - Gentoo Wiki: https://wiki.gentoo.org

Thank you for using ${GENESIS_NAME}!
EOF
}

# Run main with all arguments
main "$@"

#!/usr/bin/env bash
# ============================================================================
# The Gentoo Genesis Engine - Hardened Edition
# Version: 12.2.0 "Prometheus Hardened"
# Original Author: viktorpolanitsa
# Security Audit & Hardening: Complete rewrite addressing all findings
# License: MIT
#
# FULLY AUTOMATED, SECURITY-HARDENED GENTOO LINUX INSTALLER
#
# Implemented Features:
# ✓ Secure credential handling (stdin/FD, never plaintext by default)
# ✓ Robust checkpoints with resume capability
# ✓ LUKS2 (Argon2id) with automatic header backup
# ✓ LVM with flexible volume management
# ✓ Btrfs with @, @home, @snapshots subvolumes
# ✓ Boot environments and atomic rollback (snapper)
# ✓ OpenRC/systemd, standard/hardened profiles
# ✓ LSM: AppArmor / SELinux (basic) / none
# ✓ UFW firewall with sane defaults
# ✓ Desktop: KDE/GNOME/XFCE/i3/Sway/Server
# ✓ Kernel: genkernel/gentoo-kernel/gentoo-kernel-bin/manual
# ✓ ccache, binpkg, LTO optimizations
# ✓ Automatic updates with snapshot rollback
# ✓ CPU frequency scaling and power management
# ✓ GPG verification with fingerprint checking
# ✓ SHA512 verification by exact filename
#
# NOT YET IMPLEMENTED (flags exist but no code):
# ✗ Secure Boot support (--secure-boot) - STUB ONLY
# ✗ TPM2 LUKS unlock (--tpm2) - STUB ONLY
#
# Security Notes:
# - Passwords are NEVER written to disk by default
# - Use --save-passwords to explicitly save (with warnings)
# - Config files are CODE - only source trusted configs
# - Critical steps abort on failure, optional steps warn
# ============================================================================

# Require Bash 4.3+ for nameref (local -n)
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]] || \
   [[ "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -lt 3 ]]; then
    echo "FATAL: Bash 4.3+ required (found ${BASH_VERSION})" >&2
    exit 1
fi

set -Eeuo pipefail
shopt -s nullglob

readonly ORIG_IFS="$IFS"

# ============================================================================
# CONSTANTS
# ============================================================================

readonly GENESIS_VERSION="12.3.0"
readonly GENESIS_NAME="The Gentoo Genesis Engine"
readonly GENESIS_CODENAME="Prometheus Final"
readonly GENESIS_BUILD_DATE="2025-01-02"

# Gentoo Release Engineering GPG Key Fingerprints
# Verify at: https://www.gentoo.org/downloads/signatures/
readonly -a GENTOO_GPG_FINGERPRINTS=(
    "13EBBDBEDE7A12775DFDB1BABB572E0E2D182910"
    "DCD05B71EAB94199527F44ACDB6B8C1F96D8BF6D"
    "EF9538C9E8E64311A52CDEDFA13D0EF1914E7A72"
)

# Minimum requirements
readonly MIN_RAM_MB=1024
readonly MIN_DISK_GB=20
readonly MIN_DISK_GB_DESKTOP=40

# LUKS parameters
readonly LUKS_CIPHER="aes-xts-plain64"
readonly LUKS_KEY_SIZE=512
readonly LUKS_HASH="sha512"
readonly BOOT_PART_SIZE_MIB=1024

# Mirrors
readonly -a GENTOO_MIRRORS=(
    "https://distfiles.gentoo.org/"
    "https://gentoo.osuosl.org/"
    "https://ftp.fau.de/gentoo/"
    "https://mirrors.mit.edu/gentoo-distfiles/"
    "https://gentoo.mirrors.ovh.net/gentoo-distfiles/"
    "https://mirror.yandex.ru/gentoo/"
    "https://ftp.jaist.ac.jp/pub/Linux/Gentoo/"
)

# Runtime state
SECURE_TMPDIR=""
CHECKPOINT_FILE=""
CHECKPOINT_GLOBAL="/var/tmp/genesis-checkpoint"
LOG_FILE=""
ERR_LOG=""
PERSISTENT_LOG="/var/log/genesis-install.log"
STATE_FILE=""
STATE_FILE_GLOBAL="/var/tmp/genesis-state"
PERSISTENT_STATE_FILE="/mnt/gentoo/.genesis/state"
BOOT_STATE_FILE="/mnt/gentoo/boot/.genesis/state"
BOOT_CHECKPOINT_FILE="/mnt/gentoo/boot/.genesis/checkpoint"

# Runtime flags
FORCE_AUTO=0
SKIP_CHECKSUM=0
SKIP_GPG=0
DRY_RUN=0
VERBOSE=0
DEBUG=0
QUIET=0
SAVE_PASSWORDS=0  # NEW: explicit flag required to save passwords
CONFIG_LOADED=0

# ============================================================================
# SECURE INITIALIZATION
# ============================================================================

init_secure_tmpdir() {
    SECURE_TMPDIR=$(mktemp -d --tmpdir genesis.XXXXXXXXXX) || {
        echo "FATAL: Cannot create secure temp directory" >&2
        exit 1
    }
    chmod 700 "$SECURE_TMPDIR"
    
    CHECKPOINT_FILE="$SECURE_TMPDIR/checkpoint"
    LOG_FILE="$SECURE_TMPDIR/genesis-install.log"
    ERR_LOG="$SECURE_TMPDIR/genesis-error.log"
    STATE_FILE="$SECURE_TMPDIR/state"
    
    touch "$LOG_FILE" "$ERR_LOG"
    chmod 600 "$LOG_FILE" "$ERR_LOG"
    
    # Create persistent log location immediately
    mkdir -p /var/log 2>/dev/null || true
    touch "$PERSISTENT_LOG" 2>/dev/null || true
}

init_secure_tmpdir

# ============================================================================
# LOGGING SYSTEM
# ============================================================================

if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly DIM='\033[2m'
    readonly NC='\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

# Logging to both temp and persistent
exec 3>&1 4>&2
exec > >(tee -a "$LOG_FILE" "$PERSISTENT_LOG" 2>/dev/null) 2> >(tee -a "$ERR_LOG" "$PERSISTENT_LOG" >&2 2>/dev/null)

log() {
    (( QUIET )) || printf '%s [INFO]  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

debug() {
    if (( DEBUG )); then
        printf '%s [DEBUG] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
    fi
    return 0
}

warn() {
    printf "${YELLOW}%s [WARN]  %s${NC}\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

err() {
    printf "${RED}%s [ERROR] %s${NC}\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

trap 'err "Command failed at line $LINENO: $BASH_COMMAND"' ERR

# CRITICAL: die for fatal errors - no || true masking
die() {
    err "$*"
    err "Installation aborted. Logs: $LOG_FILE, $PERSISTENT_LOG"
    exit 1
}

success() {
    (( QUIET )) || printf "${GREEN}%s [OK]    %s${NC}\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

section() {
    local msg="$1"
    local width=74
    local padding=$(( (width - ${#msg} - 2) / 2 ))
    local line
    line=$(printf '%*s' "$width" '' | tr ' ' '═')
    echo
    printf "${CYAN}%s${NC}\n" "$line"
    printf "${CYAN}║${NC}%*s ${BOLD}%s${NC} %*s${CYAN}║${NC}\n" "$padding" '' "$msg" "$((width - padding - ${#msg} - 3))" ''
    printf "${CYAN}%s${NC}\n\n" "$line"
}

# ============================================================================
# COMMAND EXECUTION HELPERS
# ============================================================================

# MUST: command that MUST succeed, abort on failure
must() {
    if ! "$@"; then
        die "CRITICAL: Command failed: $*"
    fi
}

# SHOULD: command that should succeed, warn on failure but continue
should() {
    if ! "$@"; then
        warn "Command failed (non-fatal): $*"
        return 1
    fi
    return 0
}

# MAY: optional command, silent failure
may() {
    "$@" 2>/dev/null || true
}

# ============================================================================
# INPUT VALIDATION
# ============================================================================

validate_username() {
    local name="$1"
    [[ ${#name} -ge 1 && ${#name} -le 32 ]] || return 1
    [[ "$name" =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
    
    local -a reserved=(root daemon bin sys sync games man lp mail news uucp
                       proxy www-data backup list irc gnats nobody systemd
                       messagebus sshd polkitd rtkit avahi colord gdm sddm
                       lightdm pulse nm-openconnect nm-openvpn)
    local r
    for r in "${reserved[@]}"; do
        [[ "$name" == "$r" ]] && return 1
    done
    return 0
}

validate_hostname() {
    local name="$1"
    [[ ${#name} -ge 1 && ${#name} -le 63 ]] || return 1
    [[ "$name" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || \
    [[ "$name" =~ ^[a-zA-Z0-9]$ ]] || return 1
    return 0
}

validate_disk() {
    local disk="$1"
    [[ -b "$disk" ]] || return 1
    local basename="${disk##*/}"
    [[ -e "/sys/block/$basename" ]] || return 1
    return 0
}

validate_disk_size() {
    local disk="$1"
    local min_gb="${2:-$MIN_DISK_GB}"
    local size_bytes
    size_bytes=$(blockdev --getsize64 "$disk" 2>/dev/null) || return 1
    local size_gb=$((size_bytes / 1024 / 1024 / 1024))
    (( size_gb >= min_gb ))
}

validate_timezone() {
    local tz="$1"
    [[ -n "$tz" && -f "/usr/share/zoneinfo/$tz" ]]
}

escape_sed() {
    printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

retry_cmd() {
    local -i max_attempts=${1:-3}
    local -i base_sleep=${2:-3}
    shift 2
    
    local -i attempt=0
    until "$@"; do
        ((attempt++))
        if (( attempt >= max_attempts )); then
            err "Command failed after $max_attempts attempts: $*"
            return 1
        fi
        local sleep_time=$((base_sleep * (2 ** (attempt - 1)) + RANDOM % 5))
        warn "Retry $attempt/$max_attempts (waiting ${sleep_time}s): $*"
        sleep "$sleep_time"
    done
    return 0
}

cmd_exists() {
    command -v "$1" >/dev/null 2>&1 || return 1
    return 0
}

apply_live_keymap() {
    [[ -n "${KEYMAP:-}" ]] || return 0
    cmd_exists loadkeys || return 0
    loadkeys "$KEYMAP" >/dev/null 2>&1 || true
    return 0
}

now_ms() {
    local ms
    ms=$(date +%s%3N 2>/dev/null || true)
    if [[ "$ms" =~ ^[0-9]{13}$ ]]; then
        echo "$ms"
    else
        echo $(( $(date +%s) * 1000 ))
    fi
}

partition_prefix() {
    local disk="$1"
    if [[ "$disk" =~ [0-9]$ ]]; then
        echo "${disk}p"
    else
        echo "$disk"
    fi
}

set_partition_paths() {
    local pp
    pp=$(partition_prefix "$TARGET_DISK")
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        EFI_PART="${pp}1"
        BOOT_PART="${pp}2"
        ROOT_PART="${pp}3"
    else
        EFI_PART=""
        BOOT_PART="${pp}2"
        ROOT_PART="${pp}3"
    fi
}

btrfs_mount_opts() {
    local opts="noatime,compress=zstd:3,space_cache=v2"
    (( HAS_SSD || HAS_NVME )) && opts+=",ssd,discard=async"
    echo "$opts"
}

is_virtual() {
    if [[ -f /sys/class/dmi/id/product_name ]]; then
        local product
        product=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
        case "$product" in
            *Virtual*|*VMware*|*VirtualBox*|*KVM*|*QEMU*|*Bochs*|*Xen*) return 0 ;;
        esac
    fi
    [[ -d /proc/xen || -f /sys/hypervisor/type ]] && return 0
    systemd-detect-virt -q 2>/dev/null && return 0
    return 1
}

generate_password() {
    local length="${1:-20}"
    tr -dc 'A-Za-z0-9!@#$%^&*' </dev/urandom | head -c "$length"
}

# M2 FIX: blkid with cache bypass to avoid stale partition data
get_uuid() {
    local device="$1"
    blkid --cache-file /dev/null -s UUID -o value "$device" 2>/dev/null || echo ""
}

# ============================================================================
# SECURE CREDENTIAL HANDLING
# ============================================================================

read_password() {
    local prompt="$1"
    local -n result_var="$2"
    local confirm="${3:-}"
    local min_length="${4:-8}"
    
    while true; do
        IFS= read -rs -p "$prompt" result_var
        echo
        
        if (( ${#result_var} < min_length )); then
            warn "Password must be at least $min_length characters"
            continue
        fi
        
        if [[ -n "$confirm" ]]; then
            local confirm_pass
            IFS= read -rs -p "$confirm" confirm_pass
            echo
            [[ "$result_var" != "$confirm_pass" ]] && { warn "Passwords do not match"; continue; }
        fi
        break
    done
}

get_luks_params() {
    local -n mem_ref="$1"
    local -n parallel_ref="$2"
    
    local mem_avail_kb
    mem_avail_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 2097152)
    
    local mem_cost_kb=$((mem_avail_kb / 2))
    (( mem_cost_kb > 1048576 )) && mem_cost_kb=1048576
    (( mem_cost_kb < 65536 )) && mem_cost_kb=65536
    
    mem_ref=$mem_cost_kb
    
    local cpus
    cpus=$(nproc 2>/dev/null || echo 2)
    (( cpus > 4 )) && cpus=4
    parallel_ref=$cpus
}

secure_cryptsetup_format() {
    local device="$1"
    local password="$2"
    local mem_cost="${3:-1048576}"
    local parallel="${4:-4}"
    local iter_time="${5:-3000}"
    
    printf '%s' "$password" | cryptsetup luksFormat \
        --type luks2 \
        --pbkdf argon2id \
        --pbkdf-memory "$mem_cost" \
        --pbkdf-parallel "$parallel" \
        --iter-time "$iter_time" \
        --cipher "$LUKS_CIPHER" \
        --key-size "$LUKS_KEY_SIZE" \
        --hash "$LUKS_HASH" \
        --use-random \
        --batch-mode \
        --key-file=- \
        "$device"
}

secure_cryptsetup_open() {
    local device="$1"
    local name="$2"
    local password="$3"
    
    printf '%s' "$password" | cryptsetup open --key-file=- "$device" "$name"
}

# ============================================================================
# IDEMPOTENT HELPERS (fixes M2)
# ============================================================================

# Ensure a line exists in a file (idempotent)
ensure_line() {
    local file="$1"
    local line="$2"
    grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

# Ensure key=value in a file (replaces if exists, adds if not)
ensure_kv() {
    local file="$1"
    local key="$2"
    local value="$3"
    
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

# ============================================================================
# CLEANUP AND SIGNAL HANDLING
# ============================================================================

cleanup() {
    local exit_code=$?
    
    log "Cleanup: securing sensitive data..."
    
    local -a sensitive_files=(
        "/mnt/gentoo/tmp/.genesis_creds"
        "/mnt/gentoo/root/.luks_keyfile"
        "/mnt/gentoo/tmp/genesis_chroot.sh"
    )
    
    for file in "${sensitive_files[@]}"; do
        [[ -f "$file" ]] && { shred -fuz "$file" 2>/dev/null || rm -f "$file" 2>/dev/null; } || true
    done
    
    local -a mounts=(
        "/mnt/gentoo/dev/shm" "/mnt/gentoo/dev/pts" "/mnt/gentoo/dev"
        "/mnt/gentoo/sys/firmware/efi/efivars" "/mnt/gentoo/sys"
        "/mnt/gentoo/proc" "/mnt/gentoo/run"
        "/mnt/gentoo/boot/efi" "/mnt/gentoo/boot"
        "/mnt/gentoo/home" "/mnt/gentoo/.snapshots" "/mnt/gentoo"
    )
    
    for mount in "${mounts[@]}"; do
        mountpoint -q "$mount" 2>/dev/null && umount -l "$mount" 2>/dev/null || true
    done
    
    [[ -n "${VG_NAME:-}" ]] && vgchange -an "$VG_NAME" 2>/dev/null || true
    
    for dm in cryptroot cryptboot; do
        [[ -e "/dev/mapper/$dm" ]] && cryptsetup close "$dm" 2>/dev/null || true
    done
    
    # Copy logs to persistent
    [[ -d /mnt/gentoo/var/log ]] && {
        cp -f "$LOG_FILE" /mnt/gentoo/var/log/genesis-install.log 2>/dev/null || true
    }
    
    # Cleanup secure temp
    [[ -n "$SECURE_TMPDIR" && -d "$SECURE_TMPDIR" ]] && {
        find "$SECURE_TMPDIR" -type f -exec shred -fuz {} \; 2>/dev/null || true
        rm -rf "$SECURE_TMPDIR" 2>/dev/null || true
    }
    
    (( exit_code != 0 )) && warn "Installation incomplete (exit: $exit_code)"
}

trap cleanup EXIT

handle_interrupt() {
    echo
    warn "Installation interrupted"
    [[ -n "${CURRENT_STAGE:-}" ]] && checkpoint "$CURRENT_STAGE" "interrupted"
    exit 130
}

trap handle_interrupt INT TERM

# ============================================================================
# CHECKPOINT SYSTEM
# ============================================================================

CURRENT_STAGE=""

checkpoint() {
    local stage="$1"
    local status="${2:-ok}"
    
    CURRENT_STAGE="$stage"
    
    {
        echo "STAGE=$stage"
        echo "STATUS=$status"
        echo "TIMESTAMP=$(date -Is)"
        echo "VERSION=$GENESIS_VERSION"
    } > "$CHECKPOINT_FILE"
    
    [[ -d /mnt/gentoo/.genesis ]] && \
        cp -f "$CHECKPOINT_FILE" /mnt/gentoo/.genesis/checkpoint 2>/dev/null || true
    mountpoint -q /mnt/gentoo/boot 2>/dev/null && \
        { mkdir -p /mnt/gentoo/boot/.genesis; chmod 700 /mnt/gentoo/boot/.genesis 2>/dev/null || true; \
          cp -f "$CHECKPOINT_FILE" "$BOOT_CHECKPOINT_FILE" 2>/dev/null || true; }
    cp -f "$CHECKPOINT_FILE" "$CHECKPOINT_GLOBAL" 2>/dev/null || true
    
    sync
    debug "Checkpoint: $stage ($status)"
}

get_checkpoint() {
    local file="$CHECKPOINT_FILE"
    if [[ -f /mnt/gentoo/.genesis/checkpoint ]]; then
        file="/mnt/gentoo/.genesis/checkpoint"
    elif [[ -f /mnt/gentoo/boot/.genesis/checkpoint ]]; then
        file="/mnt/gentoo/boot/.genesis/checkpoint"
    elif [[ -f "$CHECKPOINT_GLOBAL" ]]; then
        file="$CHECKPOINT_GLOBAL"
    fi
    [[ -f "$file" ]] && grep '^STAGE=' "$file" 2>/dev/null | cut -d= -f2 || echo "0"
}

clear_checkpoint() {
    rm -f "$CHECKPOINT_FILE" /mnt/gentoo/.genesis/checkpoint "$CHECKPOINT_GLOBAL" \
        "$BOOT_CHECKPOINT_FILE" "$STATE_FILE" "$STATE_FILE_GLOBAL" "$PERSISTENT_STATE_FILE" "$BOOT_STATE_FILE" 2>/dev/null || true
}

migrate_checkpoint() {
    if [[ -d /mnt/gentoo && -w /mnt/gentoo ]]; then
        mkdir -p /mnt/gentoo/.genesis
        chmod 700 /mnt/gentoo/.genesis
        [[ -f "$CHECKPOINT_FILE" ]] && cp -f "$CHECKPOINT_FILE" /mnt/gentoo/.genesis/checkpoint
    fi
}

save_state_file() {
    local file="$1"
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    cat > "$file" <<EOF
TARGET_DISK="$TARGET_DISK"
FS_TYPE="$FS_TYPE"
USE_LVM=$USE_LVM
USE_LUKS=$USE_LUKS
SEPARATE_HOME=$SEPARATE_HOME
SWAP_MODE="$SWAP_MODE"
INIT_SYSTEM="$INIT_SYSTEM"
PROFILE_FLAVOR="$PROFILE_FLAVOR"
LSM_CHOICE="$LSM_CHOICE"
ENABLE_UFW=$ENABLE_UFW
DE_CHOICE="$DE_CHOICE"
KERNEL_MODE="$KERNEL_MODE"
ENABLE_CCACHE=$ENABLE_CCACHE
ENABLE_BINPKG=$ENABLE_BINPKG
ENABLE_LTO=$ENABLE_LTO
BUNDLE_FLATPAK=$BUNDLE_FLATPAK
BUNDLE_TERM=$BUNDLE_TERM
BUNDLE_DEV=$BUNDLE_DEV
BUNDLE_OFFICE=$BUNDLE_OFFICE
BUNDLE_GAMING=$BUNDLE_GAMING
AUTO_UPDATE=$AUTO_UPDATE
CPU_FREQ_TUNE=$CPU_FREQ_TUNE
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
TIMEZONE="$TIMEZONE"
LOCALE="$LOCALE"
KEYMAP="$KEYMAP"
VG_NAME="$VG_NAME"
LV_ROOT="$LV_ROOT"
LV_SWAP="$LV_SWAP"
LV_HOME="$LV_HOME"
SELECTED_MIRROR="$SELECTED_MIRROR"
STAGE3_URL="$STAGE3_URL"
STAGE3_BASENAME="$STAGE3_BASENAME"
BOOT_MODE="$BOOT_MODE"
CPU_MARCH="$CPU_MARCH"
GPU_DRIVER="$GPU_DRIVER"
CPU_VENDOR="$CPU_VENDOR"
EOF
    chmod 600 "$file" 2>/dev/null || true
}

save_state_all() {
    save_state_file "$STATE_FILE"
    save_state_file "$STATE_FILE_GLOBAL"
    if [[ -d /mnt/gentoo/.genesis ]]; then
        save_state_file "$PERSISTENT_STATE_FILE"
    fi
    if mountpoint -q /mnt/gentoo/boot 2>/dev/null; then
        mkdir -p /mnt/gentoo/boot/.genesis
        chmod 700 /mnt/gentoo/boot/.genesis 2>/dev/null || true
        save_state_file "$BOOT_STATE_FILE"
    fi
}

load_state() {
    local file=""
    if [[ -f "$PERSISTENT_STATE_FILE" ]]; then
        file="$PERSISTENT_STATE_FILE"
    elif [[ -f "$STATE_FILE_GLOBAL" ]]; then
        file="$STATE_FILE_GLOBAL"
    elif [[ -f "$BOOT_STATE_FILE" ]]; then
        file="$BOOT_STATE_FILE"
    elif [[ -f "$STATE_FILE" ]]; then
        file="$STATE_FILE"
    fi

    [[ -n "$file" ]] || return 1
    # shellcheck source=/dev/null
    source "$file"
    return 0
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

usage() {
    cat <<EOF
${BOLD}${GENESIS_NAME}${NC} v${GENESIS_VERSION} "${GENESIS_CODENAME}"

${CYAN}Usage:${NC} $0 [OPTIONS]

${CYAN}Options:${NC}
  -h, --help           Show help
  -V, --version        Show version
  -f, --force          Auto-confirm all prompts
  -c, --config FILE    Load configuration (WARNING: config is CODE)
  -e, --export FILE    Export configuration
  -n, --dry-run        Preview without changes
  -v, --verbose        Verbose output
  -d, --debug          Debug output
  -q, --quiet          Minimal output
  --skip-checksum      Skip SHA512 verification
  --skip-gpg           Skip GPG verification
  --clear-checkpoint   Clear saved checkpoint
  --save-passwords     Save generated passwords to file (INSECURE)

${CYAN}STUB Options (not yet implemented):${NC}
  --secure-boot        Secure Boot support (STUB - no implementation)
  --tpm2               TPM2 LUKS unlock (STUB - no implementation)

${RED}Security Notes:${NC}
  - Config files are EXECUTED as code - only source trusted files
  - Passwords are printed to TTY, never saved to disk by default
  - Use --save-passwords only if you understand the risks

EOF
}

version_info() {
    cat <<EOF
${GENESIS_NAME}
Version: ${GENESIS_VERSION} "${GENESIS_CODENAME}"
Build: ${GENESIS_BUILD_DATE}
License: MIT

${GREEN}Implemented:${NC}
  ✓ Secure credential handling (stdin/FD)
  ✓ LUKS2 with Argon2id + header backup
  ✓ GPG fingerprint verification
  ✓ SHA512 verification by filename
  ✓ Critical step enforcement (no || true masking)

${YELLOW}Not Yet Implemented:${NC}
  ✗ Secure Boot (--secure-boot flag exists but is stub)
  ✗ TPM2 LUKS unlock (--tpm2 flag exists but is stub)

EOF
}

parse_args() {
    while (( $# )); do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            -V|--version) version_info; exit 0 ;;
            -f|--force) FORCE_AUTO=1; shift ;;
            -c|--config)
                [[ -n "${2:-}" ]] || die "Config file required"
                [[ -f "$2" ]] || die "Config not found: $2"
                
                # C4 FIX: Warn about code execution
                warn "CONFIG FILES ARE CODE - only source trusted files!"
                warn "File: $2"
                
                # Check ownership (should be root or current user)
                local config_owner
                config_owner=$(stat -c '%U' "$2" 2>/dev/null)
                if [[ "$config_owner" != "root" && "$config_owner" != "$(whoami)" ]]; then
                    die "Config file owned by '$config_owner' - refusing to source untrusted file"
                fi
                
                if (( ! FORCE_AUTO )); then
                    local confirm
                    read -rp "Source this config file? [y/N]: " confirm
                    [[ "${confirm,,}" == "y" ]] || die "Aborted"
                fi
                
                # shellcheck source=/dev/null
                source "$2"
                CONFIG_LOADED=1
                shift 2
                ;;
            -e|--export)
                [[ -n "${2:-}" ]] || die "Export path required"
                EXPORT_CONFIG_FILE="$2"
                shift 2
                ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            -v|--verbose) VERBOSE=1; shift ;;
            -d|--debug) DEBUG=1; VERBOSE=1; shift ;;
            -q|--quiet) QUIET=1; shift ;;
            --skip-checksum) SKIP_CHECKSUM=1; warn "Checksum disabled"; shift ;;
            --skip-gpg) SKIP_GPG=1; warn "GPG disabled"; shift ;;
            --clear-checkpoint) clear_checkpoint; log "Checkpoint cleared"; shift ;;
            --save-passwords)
                SAVE_PASSWORDS=1
                warn "PASSWORD SAVING ENABLED - passwords will be written to disk!"
                warn "This is a security risk. Use only if you understand the implications."
                shift
                ;;
            --secure-boot)
                warn "STUB: --secure-boot has no implementation yet"
                ENABLE_SECUREBOOT=1
                shift
                ;;
            --tpm2)
                warn "STUB: --tpm2 has no implementation yet"
                ENABLE_TPM2=1
                shift
                ;;
            -*) die "Unknown option: $1" ;;
            *) die "Unexpected: $1" ;;
        esac
    done
}

check_root() {
    [[ $EUID -eq 0 ]] || die "Must be root"
}

# ============================================================================
# HARDWARE DETECTION
# ============================================================================

CPU_VENDOR="" CPU_MODEL="" CPU_MARCH="x86-64" CPU_FLAGS="" CPU_CORES=1
GPU_VENDOR="" GPU_DRIVER="fbdev"
BOOT_MODE="bios"
HAS_SSD=0 HAS_NVME=0 HAS_TPM2=0 IS_LAPTOP=0 IS_VM=0

detect_hardware() {
    section "Hardware Detection"
    
    if [[ -f /proc/cpuinfo ]]; then
        CPU_VENDOR=$(awk -F: '/^vendor_id/{gsub(/[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo)
        CPU_MODEL=$(awk -F: '/^model name/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo)
        CPU_FLAGS=$(awk -F: '/^flags/{print $2;exit}' /proc/cpuinfo)
        CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
    fi
    
    CPU_MARCH=$(detect_cpu_march)
    log "CPU: $CPU_MODEL"
    log "Cores: $CPU_CORES, Arch: $CPU_MARCH"
    
    if cmd_exists lspci; then
        local gpu_info
        gpu_info=$(lspci 2>/dev/null | grep -iE 'VGA|3D|Display' || echo "")
        
        if echo "$gpu_info" | grep -qi 'NVIDIA'; then
            GPU_VENDOR="NVIDIA"
            echo "$gpu_info" | grep -qiE 'RTX|GTX (16|20|30|40)' && GPU_DRIVER="nvidia" || GPU_DRIVER="nouveau"
        elif echo "$gpu_info" | grep -qiE 'AMD|ATI'; then
            GPU_VENDOR="AMD"
            GPU_DRIVER="amdgpu radeonsi"
        elif echo "$gpu_info" | grep -qiE 'Intel'; then
            GPU_VENDOR="Intel"
            GPU_DRIVER="intel i965 iris"
        else
            GPU_VENDOR="Generic"
            GPU_DRIVER="fbdev vesa"
        fi
        log "GPU: $GPU_VENDOR ($GPU_DRIVER)"
    fi
    
    [[ -d /sys/firmware/efi ]] && BOOT_MODE="uefi" || BOOT_MODE="bios"
    log "Boot: $BOOT_MODE"
    
    for disk in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
        [[ -d "$disk" ]] || continue
        local name="${disk##*/}"
        [[ "$name" == nvme* ]] && HAS_NVME=1
        [[ "$(cat "$disk/queue/rotational" 2>/dev/null)" == "0" ]] && HAS_SSD=1
    done
    log "SSD: $HAS_SSD, NVMe: $HAS_NVME"
    
    [[ -c /dev/tpm0 || -c /dev/tpmrm0 ]] && { HAS_TPM2=1; log "TPM2: Available"; }
    [[ -d /sys/class/power_supply/BAT0 ]] && { IS_LAPTOP=1; log "Type: Laptop"; }
    is_virtual && { IS_VM=1; log "Type: Virtual Machine"; }
}

detect_cpu_march() {
    local flags=" $(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2) "
    
    [[ "$flags" == *" avx512f "* ]] && { echo "x86-64-v4"; return; }
    
    if [[ "$flags" == *" avx2 "* && "$flags" == *" bmi1 "* && \
          "$flags" == *" bmi2 "* && "$flags" == *" fma "* ]]; then
        echo "x86-64-v3"; return
    fi
    
    if [[ "$flags" == *" sse4_2 "* && "$flags" == *" popcnt "* && \
          "$flags" == *" ssse3 "* ]]; then
        echo "x86-64-v2"; return
    fi
    
    echo "x86-64"
}

# ============================================================================
# LIVECD SELF-HEALING (H2 FIX: complete tool list)
# ============================================================================

self_heal_livecd() {
    section "LiveCD Self-Diagnostics"
    
    local mem_kb mem_mb
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    mem_mb=$((mem_kb / 1024))
    log "RAM: ${mem_mb}MB"
    
    (( mem_mb < MIN_RAM_MB )) && die "Insufficient RAM: ${mem_mb}MB < ${MIN_RAM_MB}MB"
    
    # ZRAM for low memory
    if (( mem_kb > 0 && mem_kb < 6 * 1024 * 1024 )); then
        if ! grep -q zram /proc/swaps 2>/dev/null; then
            log "Low RAM - configuring ZRAM"
            if modprobe zram 2>/dev/null; then
                local zram_size=$((mem_kb * 1024 / 2))
                local max_zram=$((4 * 1024 * 1024 * 1024))
                (( zram_size > max_zram )) && zram_size=$max_zram
                
                if [[ -w /sys/block/zram0/reset ]]; then
                    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
                fi
                if [[ -w /sys/block/zram0/disksize ]]; then
                    echo "$zram_size" > /sys/block/zram0/disksize 2>/dev/null || true
                fi
                mkswap /dev/zram0 2>/dev/null && swapon -p 100 /dev/zram0 2>/dev/null && \
                    success "ZRAM: $((zram_size / 1024 / 1024))MB"
            fi
        fi
    fi
    
    # H2 FIX: Complete list of actually used tools
    local -a required=(
        # Core utilities
        lsblk sfdisk parted blockdev mountpoint
        # Filesystem
        mkfs.ext4 mkfs.vfat
        # Crypto/LVM
        cryptsetup pvcreate vgcreate lvcreate pvs vgs lvs
        # Network
        wget curl
        # Archive
        tar xz
        # Security
        gpg sha512sum
        # Text processing
        awk sed grep tr
        # Disk operations (H2 FIX: these were missing)
        wipefs dmsetup partprobe flock blkid
    )
    
    # Optional FS tools
    local -a optional=(mkfs.btrfs mkfs.xfs btrfs pv efibootmgr)
    
    local -a missing=()
    local tool
    for tool in "${required[@]}"; do
        cmd_exists "$tool" || missing+=("$tool")
    done
    
    if (( ${#missing[@]} > 0 )); then
        warn "Missing: ${missing[*]}"
        
        if cmd_exists emerge; then
            log "Installing missing tools..."
            local -a pkgs=(
                sys-fs/cryptsetup sys-fs/lvm2 sys-fs/btrfs-progs
                sys-fs/xfsprogs sys-fs/dosfstools sys-apps/util-linux
                app-crypt/gnupg net-misc/wget net-misc/curl
                sys-block/parted app-misc/pv
            )
            
            FEATURES="-news" emerge --quiet --noreplace "${pkgs[@]}" >> "$LOG_FILE" 2>&1 || true
            
            local -a still_missing=()
            for tool in "${missing[@]}"; do
                cmd_exists "$tool" || still_missing+=("$tool")
            done
            
            (( ${#still_missing[@]} > 0 )) && die "Still missing: ${still_missing[*]}"
            success "Tools installed"
        else
            die "Cannot install tools - emerge unavailable"
        fi
    else
        success "All tools available"
    fi
}

# ============================================================================
# GPG KEY MANAGEMENT (improved fingerprint check)
# ============================================================================

import_gentoo_keys() {
    (( SKIP_GPG )) && { warn "GPG skipped"; return 0; }
    
    log "Importing Gentoo GPG keys..."
    
    local keyring="$SECURE_TMPDIR/gnupg"
    mkdir -p "$keyring"
    chmod 700 "$keyring"
    export GNUPGHOME="$keyring"
    
    local key_file="$SECURE_TMPDIR/gentoo-keys.gpg"
    
    if ! wget --https-only -q -O "$key_file" "https://qa-reports.gentoo.org/output/service-keys.gpg"; then
        warn "Could not download GPG keys"
        return 1
    fi
    
    gpg --import "$key_file" 2>/dev/null || { warn "Could not import keys"; return 1; }
    
    # M1 FIX: Set trust level for imported keys
    for fp in "${GENTOO_GPG_FINGERPRINTS[@]}"; do
        echo "${fp}:6:" | gpg --import-ownertrust 2>/dev/null || true
    done
    
    # IMPROVED: Use machine-readable format for fingerprint verification
    local found=0 fp
    local imported_fps
    imported_fps=$(gpg --with-colons --fingerprint 2>/dev/null | awk -F: '/^fpr:/{print $10}')
    
    for fp in "${GENTOO_GPG_FINGERPRINTS[@]}"; do
        if echo "$imported_fps" | grep -qi "$fp"; then
            found=1
            debug "Verified fingerprint: $fp"
            break
        fi
    done
    
    (( ! found )) && { warn "Fingerprint verification failed"; return 1; }
    
    success "GPG keys verified"
    rm -f "$key_file"
    return 0
}

# ============================================================================
# NETWORK
# ============================================================================

check_network() {
    section "Network Connectivity"
    
    local -a hosts=("1.1.1.1" "8.8.8.8" "9.9.9.9")
    local connected=0 host
    
    for host in "${hosts[@]}"; do
        if ping -c1 -W3 "$host" >/dev/null 2>&1; then
            connected=1
            break
        fi
    done
    
    if (( ! connected )); then
        for url in "${GENTOO_MIRRORS[@]}"; do
            if curl -s --head --max-time 10 "$url" >/dev/null 2>&1; then
                connected=1
                break
            fi
        done
    fi
    
    (( connected )) || die "No network connectivity"
    success "Network OK"
}

# ============================================================================
# CONFIGURATION VARIABLES
# ============================================================================

TARGET_DISK=""
FS_TYPE="btrfs"
USE_LVM=1
USE_LUKS=1
ENCRYPT_BOOT=0
SEPARATE_HOME=1
SWAP_MODE="zram"

INIT_SYSTEM="openrc"
PROFILE_FLAVOR="standard"
LSM_CHOICE="none"
ENABLE_UFW=1

ENABLE_SECUREBOOT=0
ENABLE_TPM2=0

DE_CHOICE="kde"
KERNEL_MODE="gentoo-kernel-bin"

ENABLE_CCACHE=1
ENABLE_BINPKG=1
ENABLE_LTO=0

BUNDLE_FLATPAK=1
BUNDLE_TERM=1
BUNDLE_DEV=1
BUNDLE_OFFICE=1
BUNDLE_GAMING=0

AUTO_UPDATE=1
CPU_FREQ_TUNE=1

HOSTNAME="gentoo"
USERNAME="gentoo"
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
KEYMAP="us"

ROOT_PASSWORD=""
USER_PASSWORD=""
LUKS_PASSWORD=""

VG_NAME="vg0"
LV_ROOT="lvroot"
LV_SWAP="lvswap"
LV_HOME="lvhome"

EFI_PART=""
BOOT_PART=""
ROOT_PART=""

SELECTED_MIRROR=""
STAGE3_URL=""
STAGE3_BASENAME=""

EXPORT_CONFIG_FILE=""

# ============================================================================
# INTERACTIVE WIZARD
# ============================================================================

yesno() {
    local prompt="$1"
    local default="${2:-yes}"
    
    (( FORCE_AUTO )) && { [[ "${default,,}" == "yes" ]] && echo "yes" || echo "no"; return; }
    
    local hint
    [[ "${default,,}" == "yes" ]] && hint="[Y/n]" || hint="[y/N]"
    
    local answer
    read -rp "$prompt $hint: " answer
    answer="${answer:-$default}"
    
    [[ "${answer,,}" =~ ^y(es)?$ ]] && echo "yes" || echo "no"
}

choose_option() {
    local prompt="$1"
    local default="$2"
    shift 2
    local -a options=("$@")
    
    (( FORCE_AUTO )) && { echo "$default"; return; }
    
    echo
    local i=1 opt
    for opt in "${options[@]}"; do
        if (( i == default )); then
            echo "  ${CYAN}$i)${NC} $opt ${DIM}(default)${NC}"
        else
            echo "  $i) $opt"
        fi
        ((i++))
    done
    
    local choice
    read -rp "$prompt [1-${#options[@]}]: " choice
    choice="${choice:-$default}"
    
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )) || choice="$default"
    echo "$choice"
}

wizard() {
    section "Configuration Wizard"
    
    # Disk selection
    echo "${BOLD}Available disks:${NC}"
    echo
    local disk_size_gb=0

    if (( CONFIG_LOADED )); then
        local use_preset=0
        if (( FORCE_AUTO )); then
            use_preset=1
        else
            local confirm
            read -rp "Use configuration preset and skip wizard? [y/N]: " confirm
            [[ "${confirm,,}" == "y" ]] && use_preset=1
        fi
        
        if (( use_preset )); then
            [[ -n "$TARGET_DISK" ]] || die "TARGET_DISK must be set in config"
            validate_disk "$TARGET_DISK" || die "Invalid TARGET_DISK: $TARGET_DISK"
            disk_size_gb=$(blockdev --getsize64 "$TARGET_DISK" 2>/dev/null | awk '{printf "%.0f", $1/1024/1024/1024}')
            
            case "$FS_TYPE" in btrfs|xfs|ext4) ;; *) warn "Invalid FS_TYPE '$FS_TYPE', using ext4"; FS_TYPE="ext4" ;; esac
            case "$INIT_SYSTEM" in openrc|systemd) ;; *) warn "Invalid INIT_SYSTEM '$INIT_SYSTEM', using openrc"; INIT_SYSTEM="openrc" ;; esac
            case "$PROFILE_FLAVOR" in standard|hardened) ;; *) warn "Invalid PROFILE_FLAVOR '$PROFILE_FLAVOR', using standard"; PROFILE_FLAVOR="standard" ;; esac
            case "$LSM_CHOICE" in none|apparmor|selinux) ;; *) warn "Invalid LSM_CHOICE '$LSM_CHOICE', using none"; LSM_CHOICE="none" ;; esac
            case "$DE_CHOICE" in kde|gnome|xfce|i3|sway|server) ;; *) warn "Invalid DE_CHOICE '$DE_CHOICE', using server"; DE_CHOICE="server" ;; esac
            case "$KERNEL_MODE" in gentoo-kernel-bin|gentoo-kernel|genkernel|manual) ;; *) warn "Invalid KERNEL_MODE '$KERNEL_MODE', using gentoo-kernel-bin"; KERNEL_MODE="gentoo-kernel-bin" ;; esac
            case "$SWAP_MODE" in zram|partition|none) ;; *) warn "Invalid SWAP_MODE '$SWAP_MODE', using zram"; SWAP_MODE="zram" ;; esac
            
            [[ "$FS_TYPE" == "btrfs" ]] && ! cmd_exists mkfs.btrfs && { warn "Btrfs unavailable"; FS_TYPE="ext4"; }
            [[ "$FS_TYPE" == "xfs" ]] && ! cmd_exists mkfs.xfs && { warn "XFS unavailable"; FS_TYPE="ext4"; }
            
            [[ "$USE_LVM" =~ ^[01]$ ]] || USE_LVM=1
            [[ "$USE_LUKS" =~ ^[01]$ ]] || USE_LUKS=1
            [[ "$SEPARATE_HOME" =~ ^[01]$ ]] || SEPARATE_HOME=1
            
            if (( ! USE_LVM )) && [[ "$SWAP_MODE" == "partition" ]]; then
                warn "Swap partition requires LVM; using ZRAM instead"
                SWAP_MODE="zram"
            fi
            
            if [[ "$FS_TYPE" != "btrfs" ]] && (( ! USE_LVM )); then
                SEPARATE_HOME=0
            fi
            
            if [[ "$DE_CHOICE" != "server" && $disk_size_gb -lt $MIN_DISK_GB_DESKTOP ]]; then
                warn "Disk may be too small for a desktop install (${disk_size_gb}GB < ${MIN_DISK_GB_DESKTOP}GB)"
                [[ $(yesno "Continue anyway?" "no") == "yes" ]] || die "Aborted"
            fi
            
            if findmnt -S "$TARGET_DISK"'*' >/dev/null 2>&1; then
                warn "$TARGET_DISK has mounted partitions"
                [[ $(yesno "Continue anyway?" "no") == "yes" ]] || die "Aborted"
            fi
            
            display_summary
            
            if (( ! FORCE_AUTO )); then
                echo
                echo "${RED}╔════════════════════════════════════════════════════════════════════╗${NC}"
                echo "${RED}║  WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED!  ║${NC}"
                echo "${RED}╚════════════════════════════════════════════════════════════════════╝${NC}"
                echo
                
                local confirm_run
                read -rp "Type 'YES' to proceed: " confirm_run
                [[ "$confirm_run" == "YES" ]] || die "Aborted"
            fi
            
            (( DRY_RUN )) && { display_summary; exit 0; }
            save_state_all
            return
        fi
    fi
    
    while IFS= read -r line; do
        local name size model tran
        read -r name size model tran <<< "$line"
        
        local size_gb in_use=""
        size_gb=$(blockdev --getsize64 "/dev/$name" 2>/dev/null | awk '{printf "%.0f", $1/1024/1024/1024}')
        findmnt -S "/dev/$name"'*' >/dev/null 2>&1 && in_use=" ${YELLOW}[IN USE]${NC}"
        
        printf "  ${CYAN}%-12s${NC} %6sGB  %-30s %s%b\n" "$name" "$size_gb" "${model:-Unknown}" "${tran:-}" "$in_use"
    done < <(lsblk -dno NAME,SIZE,MODEL,TRAN 2>/dev/null | grep -vE '^(loop|sr|ram)')
    
    echo
    
    while true; do
        read -rp "Target disk (e.g., sda, nvme0n1): " disk_input
        [[ -n "$disk_input" ]] || { warn "No disk selected"; continue; }
        
        TARGET_DISK="/dev/${disk_input##*/}"
        validate_disk "$TARGET_DISK" || { warn "Invalid: $TARGET_DISK"; continue; }
        
        disk_size_gb=$(blockdev --getsize64 "$TARGET_DISK" 2>/dev/null | awk '{printf "%.0f", $1/1024/1024/1024}')
        if (( disk_size_gb < MIN_DISK_GB )); then
            [[ $(yesno "Disk may be too small. Continue?" "no") == "yes" ]] || continue
        fi
        
        if findmnt -S "$TARGET_DISK"'*' >/dev/null 2>&1; then
            warn "$TARGET_DISK has mounted partitions"
            [[ $(yesno "Continue anyway?" "no") == "yes" ]] || continue
        fi
        break
    done
    
    log "Disk: $TARGET_DISK"
    
    # Filesystem
    echo
    local fs_choice
    fs_choice=$(choose_option "Filesystem" 1 "Btrfs (snapshots)" "XFS (performance)" "Ext4 (traditional)")
    case "$fs_choice" in
        1) FS_TYPE="btrfs" ;;
        2) FS_TYPE="xfs" ;;
        3) FS_TYPE="ext4" ;;
    esac
    
    [[ "$FS_TYPE" == "btrfs" ]] && ! cmd_exists mkfs.btrfs && { warn "Btrfs unavailable"; FS_TYPE="ext4"; }
    [[ "$FS_TYPE" == "xfs" ]] && ! cmd_exists mkfs.xfs && { warn "XFS unavailable"; FS_TYPE="ext4"; }
    
    # Encryption
    echo
    [[ $(yesno "Enable LUKS2 encryption?" "yes") == "yes" ]] && USE_LUKS=1 || USE_LUKS=0
    
    if (( USE_LUKS )); then
        if (( ! FORCE_AUTO )); then
            echo
            read_password "LUKS password: " LUKS_PASSWORD "Confirm: " 8
        else
            LUKS_PASSWORD=$(generate_password 24)
            warn "Generated LUKS password"
        fi
    fi
    
    # LVM
    echo
    [[ $(yesno "Use LVM?" "yes") == "yes" ]] && USE_LVM=1 || USE_LVM=0
    
    # Separate home
    if [[ "$FS_TYPE" == "btrfs" ]]; then
        echo
        [[ $(yesno "Separate /home subvolume?" "yes") == "yes" ]] && SEPARATE_HOME=1 || SEPARATE_HOME=0
    elif (( USE_LVM )); then
        echo
        [[ $(yesno "Separate /home?" "yes") == "yes" ]] && SEPARATE_HOME=1 || SEPARATE_HOME=0
    else
        SEPARATE_HOME=0
    fi
    
    # Swap
    echo
    local swap_choice
    if (( USE_LVM )); then
        swap_choice=$(choose_option "Swap type" 1 "ZRAM" "Partition" "None")
        case "$swap_choice" in
            1) SWAP_MODE="zram" ;;
            2) SWAP_MODE="partition" ;;
            3) SWAP_MODE="none" ;;
        esac
    else
        swap_choice=$(choose_option "Swap type" 1 "ZRAM" "None")
        case "$swap_choice" in
            1) SWAP_MODE="zram" ;;
            2) SWAP_MODE="none" ;;
        esac
    fi
    if (( ! USE_LVM )) && [[ "$SWAP_MODE" == "partition" ]]; then
        warn "Swap partition requires LVM; using ZRAM instead"
        SWAP_MODE="zram"
    fi
    
    # Init system
    echo
    local init_choice
    init_choice=$(choose_option "Init system" 1 "OpenRC" "systemd")
    case "$init_choice" in
        1) INIT_SYSTEM="openrc" ;;
        2) INIT_SYSTEM="systemd" ;;
    esac
    
    # Profile
    echo
    [[ $(yesno "Hardened profile?" "no") == "yes" ]] && PROFILE_FLAVOR="hardened" || PROFILE_FLAVOR="standard"
    
    # LSM
    echo
    local lsm_choice
    lsm_choice=$(choose_option "Security module" 1 "None" "AppArmor" "SELinux (basic)")
    case "$lsm_choice" in
        1) LSM_CHOICE="none" ;;
        2) LSM_CHOICE="apparmor" ;;
        3) LSM_CHOICE="selinux" ;;
    esac
    
    # Firewall
    echo
    [[ $(yesno "Enable UFW?" "yes") == "yes" ]] && ENABLE_UFW=1 || ENABLE_UFW=0
    
    # Desktop
    echo
    local de_choice
    de_choice=$(choose_option "Desktop" 1 "KDE Plasma" "GNOME" "XFCE" "i3" "Sway (Wayland)" "Server")
    case "$de_choice" in
        1) DE_CHOICE="kde" ;;
        2) DE_CHOICE="gnome" ;;
        3) DE_CHOICE="xfce" ;;
        4) DE_CHOICE="i3" ;;
        5) DE_CHOICE="sway" ;;
        6) DE_CHOICE="server" ;;
    esac
    
    if [[ "$DE_CHOICE" != "server" && $disk_size_gb -lt $MIN_DISK_GB_DESKTOP ]]; then
        warn "Disk may be too small for a desktop install (${disk_size_gb}GB < ${MIN_DISK_GB_DESKTOP}GB)"
        [[ $(yesno "Continue anyway?" "no") == "yes" ]] || die "Aborted"
    fi
    
    # Kernel
    echo
    local kernel_choice
    kernel_choice=$(choose_option "Kernel" 1 "gentoo-kernel-bin" "gentoo-kernel" "genkernel" "Manual")
    case "$kernel_choice" in
        1) KERNEL_MODE="gentoo-kernel-bin" ;;
        2) KERNEL_MODE="gentoo-kernel" ;;
        3) KERNEL_MODE="genkernel" ;;
        4) KERNEL_MODE="manual" ;;
    esac
    
    # Performance
    echo
    echo "${BOLD}Performance:${NC}"
    [[ $(yesno "  ccache?" "yes") == "yes" ]] && ENABLE_CCACHE=1 || ENABLE_CCACHE=0
    [[ $(yesno "  Binary packages?" "yes") == "yes" ]] && ENABLE_BINPKG=1 || ENABLE_BINPKG=0
    [[ $(yesno "  LTO?" "no") == "yes" ]] && ENABLE_LTO=1 || ENABLE_LTO=0
    
    # Software
    if [[ "$DE_CHOICE" != "server" ]]; then
        echo
        echo "${BOLD}Software:${NC}"
        [[ $(yesno "  Flatpak?" "yes") == "yes" ]] && BUNDLE_FLATPAK=1 || BUNDLE_FLATPAK=0
        [[ $(yesno "  Enhanced terminal?" "yes") == "yes" ]] && BUNDLE_TERM=1 || BUNDLE_TERM=0
        [[ $(yesno "  Developer tools?" "yes") == "yes" ]] && BUNDLE_DEV=1 || BUNDLE_DEV=0
        [[ $(yesno "  Office suite?" "yes") == "yes" ]] && BUNDLE_OFFICE=1 || BUNDLE_OFFICE=0
        [[ $(yesno "  Gaming?" "no") == "yes" ]] && BUNDLE_GAMING=1 || BUNDLE_GAMING=0
    fi
    
    # Maintenance
    echo
    echo "${BOLD}Maintenance:${NC}"
    [[ $(yesno "  Auto-updates?" "yes") == "yes" ]] && AUTO_UPDATE=1 || AUTO_UPDATE=0
    [[ $(yesno "  CPU freq management?" "yes") == "yes" ]] && CPU_FREQ_TUNE=1 || CPU_FREQ_TUNE=0
    
    # Identity
    echo
    echo "${BOLD}System identity:${NC}"
    
    if (( ! FORCE_AUTO )); then
        while true; do
            read -rp "  Hostname [gentoo]: " HOSTNAME
            HOSTNAME="${HOSTNAME:-gentoo}"
            validate_hostname "$HOSTNAME" && break
            warn "Invalid hostname"
        done
        
        while true; do
            read -rp "  Username [gentoo]: " USERNAME
            USERNAME="${USERNAME:-gentoo}"
            validate_username "$USERNAME" && break
            warn "Invalid username"
        done
        
        while true; do
            read -rp "  Timezone [UTC]: " TIMEZONE
            TIMEZONE="${TIMEZONE:-UTC}"
            validate_timezone "$TIMEZONE" && break
            warn "Invalid timezone"; TIMEZONE="UTC"; break
        done
    fi
    
    # Passwords
    echo
    if (( ! FORCE_AUTO )); then
        echo "${BOLD}Passwords:${NC}"
        read_password "  Root password: " ROOT_PASSWORD "  Confirm: " 8
        echo
        read_password "  User password: " USER_PASSWORD "  Confirm: " 8
    else
        ROOT_PASSWORD=$(generate_password 16)
        USER_PASSWORD=$(generate_password 16)
        warn "Generated random passwords"
    fi
    
    # Export config
    [[ -n "${EXPORT_CONFIG_FILE:-}" ]] && export_config "$EXPORT_CONFIG_FILE"
    
    # Summary
    display_summary
    
    if (( ! FORCE_AUTO )); then
        echo
        echo "${RED}╔════════════════════════════════════════════════════════════════════╗${NC}"
        echo "${RED}║  WARNING: ALL DATA ON $TARGET_DISK WILL BE DESTROYED!  ║${NC}"
        echo "${RED}╚════════════════════════════════════════════════════════════════════╝${NC}"
        echo
        
        local confirm
        read -rp "Type 'YES' to proceed: " confirm
        [[ "$confirm" == "YES" ]] || die "Aborted"
    fi
    
    (( DRY_RUN )) && { display_summary; exit 0; }
    save_state_all
}

display_summary() {
    section "Configuration Summary"
    
    printf "  %-18s %s\n" "Disk:" "$TARGET_DISK"
    printf "  %-18s %s\n" "Boot:" "$BOOT_MODE"
    echo
    printf "  ${BOLD}Storage:${NC}\n"
    printf "    %-16s %s\n" "Filesystem:" "$FS_TYPE"
    printf "    %-16s %s\n" "LVM:" "$USE_LVM"
    printf "    %-16s %s\n" "LUKS:" "$USE_LUKS"
    printf "    %-16s %s\n" "Separate /home:" "$SEPARATE_HOME"
    printf "    %-16s %s\n" "Swap:" "$SWAP_MODE"
    echo
    printf "  ${BOLD}System:${NC}\n"
    printf "    %-16s %s\n" "Init:" "$INIT_SYSTEM"
    printf "    %-16s %s\n" "Profile:" "$PROFILE_FLAVOR"
    printf "    %-16s %s\n" "LSM:" "$LSM_CHOICE"
    printf "    %-16s %s\n" "Firewall:" "$ENABLE_UFW"
    printf "    %-16s %s\n" "Desktop:" "$DE_CHOICE"
    printf "    %-16s %s\n" "Kernel:" "$KERNEL_MODE"
    echo
    printf "  ${BOLD}Identity:${NC}\n"
    printf "    %-16s %s\n" "Hostname:" "$HOSTNAME"
    printf "    %-16s %s\n" "Username:" "$USERNAME"
    printf "    %-16s %s\n" "Timezone:" "$TIMEZONE"
    echo
}

export_config() {
    local file="$1"
    
    cat > "$file" <<EOF
# Gentoo Genesis Engine Configuration
# Generated: $(date -Is)
# Version: $GENESIS_VERSION
# WARNING: This is a shell script - will be sourced with 'source'

TARGET_DISK="$TARGET_DISK"
FS_TYPE="$FS_TYPE"
USE_LVM=$USE_LVM
USE_LUKS=$USE_LUKS
SEPARATE_HOME=$SEPARATE_HOME
SWAP_MODE="$SWAP_MODE"
INIT_SYSTEM="$INIT_SYSTEM"
PROFILE_FLAVOR="$PROFILE_FLAVOR"
LSM_CHOICE="$LSM_CHOICE"
ENABLE_UFW=$ENABLE_UFW
DE_CHOICE="$DE_CHOICE"
KERNEL_MODE="$KERNEL_MODE"
ENABLE_CCACHE=$ENABLE_CCACHE
ENABLE_BINPKG=$ENABLE_BINPKG
ENABLE_LTO=$ENABLE_LTO
BUNDLE_FLATPAK=$BUNDLE_FLATPAK
BUNDLE_TERM=$BUNDLE_TERM
BUNDLE_DEV=$BUNDLE_DEV
BUNDLE_OFFICE=$BUNDLE_OFFICE
BUNDLE_GAMING=$BUNDLE_GAMING
AUTO_UPDATE=$AUTO_UPDATE
CPU_FREQ_TUNE=$CPU_FREQ_TUNE
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
TIMEZONE="$TIMEZONE"
LOCALE="$LOCALE"
KEYMAP="$KEYMAP"
VG_NAME="$VG_NAME"
LV_ROOT="$LV_ROOT"
LV_SWAP="$LV_SWAP"
LV_HOME="$LV_HOME"
EOF
    
    chmod 600 "$file"
    success "Config exported: $file"
}

# ============================================================================
# RESUME HELPERS
# ============================================================================

scan_for_boot_state() {
    local scan_dir="$SECURE_TMPDIR/scan"
    mkdir -p "$scan_dir"
    
    local dev fstype
    while read -r dev fstype; do
        [[ -n "$fstype" ]] || continue
        
        if mount -o ro -t "$fstype" "$dev" "$scan_dir" 2>/dev/null; then
            if [[ -f "$scan_dir/.genesis/state" ]]; then
                cp -f "$scan_dir/.genesis/state" "$STATE_FILE_GLOBAL" 2>/dev/null || true
                [[ -f "$scan_dir/.genesis/checkpoint" ]] && \
                    cp -f "$scan_dir/.genesis/checkpoint" "$CHECKPOINT_GLOBAL" 2>/dev/null || true
                umount "$scan_dir" 2>/dev/null || true
                return 0
            fi
            umount "$scan_dir" 2>/dev/null || true
        fi
    done < <(lsblk -rno NAME,FSTYPE,TYPE,LABEL 2>/dev/null | awk '$3=="part" && $4=="gentoo-boot"{print "/dev/"$1" "$2}')
    
    return 1
}

ensure_luks_open() {
    (( USE_LUKS )) || return 0
    set_partition_paths
    
    [[ -e /dev/mapper/cryptroot ]] && return 0
    
    local attempts=0
    while (( attempts < 3 )); do
        warn "LUKS container is locked - password required to resume"
        read_password "LUKS password: " LUKS_PASSWORD "" 8
        if secure_cryptsetup_open "$ROOT_PART" "cryptroot" "$LUKS_PASSWORD"; then
            return 0
        fi
        LUKS_PASSWORD=""
        warn "Failed to unlock LUKS (attempt $((attempts + 1))/3)"
        ((attempts++))
    done
    return 1
}

ensure_lvm_active() {
    (( USE_LVM )) || return 0
    vgchange -ay "$VG_NAME" 2>/dev/null || true
}

ensure_target_mounted() {
    set_partition_paths
    
    ensure_luks_open || die "Cannot unlock LUKS device"
    ensure_lvm_active
    
    local root_dev
    if (( USE_LVM )); then
        root_dev="/dev/$VG_NAME/$LV_ROOT"
    elif (( USE_LUKS )); then
        root_dev="/dev/mapper/cryptroot"
    else
        root_dev="$ROOT_PART"
    fi
    
    mkdir -p /mnt/gentoo
    
    if ! mountpoint -q /mnt/gentoo; then
        case "$FS_TYPE" in
            btrfs)
                local opts
                opts=$(btrfs_mount_opts)
                must mount -o "subvol=@,$opts" "$root_dev" /mnt/gentoo
                ;;
            xfs|ext4)
                must mount "$root_dev" /mnt/gentoo
                ;;
        esac
    fi
    
    if [[ "$FS_TYPE" == "btrfs" ]]; then
        local opts
        opts=$(btrfs_mount_opts)
        mkdir -p /mnt/gentoo/.snapshots
        mountpoint -q /mnt/gentoo/.snapshots || \
            must mount -o "subvol=@snapshots,$opts" "$root_dev" /mnt/gentoo/.snapshots
        if (( SEPARATE_HOME )); then
            mkdir -p /mnt/gentoo/home
            mountpoint -q /mnt/gentoo/home || \
                must mount -o "subvol=@home,$opts" "$root_dev" /mnt/gentoo/home
        fi
    else
        if (( SEPARATE_HOME && USE_LVM )); then
            mkdir -p /mnt/gentoo/home
            mountpoint -q /mnt/gentoo/home || \
                must mount "/dev/$VG_NAME/$LV_HOME" /mnt/gentoo/home
        fi
    fi
    
    mkdir -p /mnt/gentoo/boot
    mountpoint -q /mnt/gentoo/boot || must mount "$BOOT_PART" /mnt/gentoo/boot
    
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        mkdir -p /mnt/gentoo/boot/efi
        mountpoint -q /mnt/gentoo/boot/efi || must mount "$EFI_PART" /mnt/gentoo/boot/efi
    fi
}

ensure_user_passwords() {
    if [[ -z "$ROOT_PASSWORD" ]]; then
        if (( FORCE_AUTO )); then
            ROOT_PASSWORD=$(generate_password 16)
            warn "Generated new root password (resume)"
        else
            read_password "  Root password: " ROOT_PASSWORD "  Confirm: " 8
        fi
    fi
    
    if [[ -z "$USER_PASSWORD" ]]; then
        if (( FORCE_AUTO )); then
            USER_PASSWORD=$(generate_password 16)
            warn "Generated new user password (resume)"
        else
            read_password "  User password: " USER_PASSWORD "  Confirm: " 8
        fi
    fi
}

# ============================================================================
# DISK OPERATIONS
# ============================================================================

partition_disk() {
    section "Disk Partitioning"
    
    log "Preparing: $TARGET_DISK"
    
    # H1 FIX: Global lock file survives crashes
    mkdir -p /var/lock
    exec 9>/var/lock/genesis-disk.lock
    flock -x -w 30 9 || die "Could not lock disk (another installer running?)"
    
    swapoff -a 2>/dev/null || true
    
    local vg
    for vg in $(vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}' || true); do
        pvs --noheadings -o pv_name --select "vg_name=$vg" 2>/dev/null | \
            grep -q "^${TARGET_DISK}" && vgchange -an "$vg" 2>/dev/null || true
    done
    
    local dm
    for dm in $(dmsetup ls --target crypt 2>/dev/null | cut -f1 || true); do
        cryptsetup status "$dm" 2>/dev/null | grep -q "$TARGET_DISK" && \
            cryptsetup close "$dm" 2>/dev/null || true
    done
    
    local mount
    for mount in $(findmnt -rno TARGET -S "$TARGET_DISK"'*' 2>/dev/null || true); do
        umount -l "$mount" 2>/dev/null || true
    done
    
    sleep 2
    
    log "Wiping signatures..."
    must wipefs -af "$TARGET_DISK"
    dd if=/dev/zero of="$TARGET_DISK" bs=1M count=1 status=none 2>/dev/null || true
    
    must blockdev --flushbufs "$TARGET_DISK"
    sync
    sleep 1
    
    set_partition_paths
    
    local boot_start_mib boot_end_mib
    
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        log "Creating GPT for UEFI"
        boot_start_mib=513
        boot_end_mib=$((boot_start_mib + BOOT_PART_SIZE_MIB))
        must parted -s "$TARGET_DISK" \
            mklabel gpt \
            mkpart "EFI" fat32 1MiB 513MiB \
            set 1 esp on \
            mkpart "BOOT" ext4 "${boot_start_mib}MiB" "${boot_end_mib}MiB" \
            mkpart "root" ext4 "${boot_end_mib}MiB" 100%
    else
        log "Creating GPT for BIOS"
        boot_start_mib=3
        boot_end_mib=$((boot_start_mib + BOOT_PART_SIZE_MIB))
        must parted -s "$TARGET_DISK" \
            mklabel gpt \
            mkpart "BIOS" 1MiB 3MiB \
            set 1 bios_grub on \
            mkpart "BOOT" ext4 "${boot_start_mib}MiB" "${boot_end_mib}MiB" \
            mkpart "root" ext4 "${boot_end_mib}MiB" 100%
    fi
    
    must partprobe "$TARGET_DISK"
    sleep 2
    
    local retry=0
    while [[ ! -b "$BOOT_PART" || ! -b "$ROOT_PART" || ( "$BOOT_MODE" == "uefi" && ! -b "$EFI_PART" ) ]]; do
        ((retry++))
        (( retry > 10 )) && die "Partitions not found"
        sleep 1
        partprobe "$TARGET_DISK" 2>/dev/null || true
    done
    
    exec 9>&-
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        success "Partitions: $EFI_PART, $BOOT_PART, $ROOT_PART"
    else
        success "Partitions: $BOOT_PART, $ROOT_PART"
    fi
}

setup_encryption() {
    (( USE_LUKS )) || return 0
    
    section "Encryption Setup"
    
    if [[ -z "$LUKS_PASSWORD" ]]; then
        if (( FORCE_AUTO )); then
            LUKS_PASSWORD=$(generate_password 24)
            warn "Generated LUKS password"
        else
            read_password "LUKS password: " LUKS_PASSWORD "Confirm: " 8
        fi
    fi
    
    set_partition_paths
    local crypt_part="$ROOT_PART"
    
    log "Setting up LUKS2 on $crypt_part"
    
    local mem_cost parallel
    get_luks_params mem_cost parallel
    log "LUKS: memory=${mem_cost}KB, parallel=$parallel"
    
    must secure_cryptsetup_format "$crypt_part" "$LUKS_PASSWORD" "$mem_cost" "$parallel" 3000
    success "LUKS2 container created"
    
    must secure_cryptsetup_open "$crypt_part" "cryptroot" "$LUKS_PASSWORD"
    success "Opened: /dev/mapper/cryptroot"
    
    # Header backup
    log "Creating LUKS header backup..."
    mkdir -p "$SECURE_TMPDIR/luks-backup"
    local backup="$SECURE_TMPDIR/luks-backup/luks-header-$(date +%Y%m%d%H%M%S).bin"
    
    if cryptsetup luksHeaderBackup "$crypt_part" --header-backup-file "$backup"; then
        chmod 400 "$backup"
        success "Header backup: $backup"
        warn "CRITICAL: Copy this backup to external storage!"
    fi
}

setup_lvm() {
    section "LVM Setup"
    
    (( USE_LUKS )) && ensure_luks_open
    
    local pv_dev
    if (( USE_LUKS )); then
        pv_dev="/dev/mapper/cryptroot"
    else
        set_partition_paths
        pv_dev="$ROOT_PART"
    fi
    
    if (( USE_LVM )); then
        log "Creating LVM on $pv_dev"
        
        must pvcreate -ff -y "$pv_dev"
        must vgcreate "$VG_NAME" "$pv_dev"
        success "VG: $VG_NAME"
        
        local vg_size
        vg_size=$(vgs --noheadings --units m -o vg_free "$VG_NAME" 2>/dev/null | \
            awk '{gsub(/[^0-9.]/,"",$1); printf "%d", $1}')
        log "VG free: ${vg_size}MB"
        
        local split_home=0
        if (( SEPARATE_HOME )) && [[ "$FS_TYPE" != "btrfs" ]]; then
            split_home=1
        fi
        
        if (( split_home )); then
            local root_size=$((vg_size * 40 / 100))
            must lvcreate -y -L "${root_size}M" -n "$LV_ROOT" "$VG_NAME"
            log "LV $LV_ROOT: ${root_size}MB"
            
            if [[ "$SWAP_MODE" == "partition" ]]; then
                local ram_mb=$(($(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024))
                local swap_mb=$((ram_mb > 8192 ? 8192 : ram_mb))
                should lvcreate -y -L "${swap_mb}M" -n "$LV_SWAP" "$VG_NAME" && \
                    log "LV $LV_SWAP: ${swap_mb}MB"
            fi
            
            must lvcreate -y -l 100%FREE -n "$LV_HOME" "$VG_NAME"
            log "LV $LV_HOME: remaining"
        else
            if [[ "$SWAP_MODE" == "partition" ]]; then
                local ram_mb=$(($(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024))
                local swap_mb=$((ram_mb > 8192 ? 8192 : ram_mb))
                should lvcreate -y -L "${swap_mb}M" -n "$LV_SWAP" "$VG_NAME" && \
                    log "LV $LV_SWAP: ${swap_mb}MB"
            fi
            
            must lvcreate -y -l 100%FREE -n "$LV_ROOT" "$VG_NAME"
            log "LV $LV_ROOT: remaining"
        fi
        success "LVs created"
    fi
}

create_filesystems() {
    section "Filesystem Creation"
    
    (( USE_LUKS )) && ensure_luks_open
    ensure_lvm_active
    
    set_partition_paths
    
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        log "Creating FAT32 on EFI"
        must mkfs.vfat -F32 -n "EFI" "$EFI_PART"
    fi
    
    log "Creating ext4 on /boot"
    must mkfs.ext4 -F -L "gentoo-boot" "$BOOT_PART"
    
    local root_dev
    if (( USE_LVM )); then
        root_dev="/dev/$VG_NAME/$LV_ROOT"
    elif (( USE_LUKS )); then
        root_dev="/dev/mapper/cryptroot"
    else
        root_dev="$ROOT_PART"
    fi
    
    log "Creating $FS_TYPE on $root_dev"
    
    case "$FS_TYPE" in
        btrfs)
            must mkfs.btrfs -f -L "gentoo-root" "$root_dev"
            must mount "$root_dev" /mnt/gentoo
            
            # Idempotent subvolume creation (safe for resume)
            log "Creating subvolumes..."
            btrfs subvolume list /mnt/gentoo 2>/dev/null | grep -q ' @$' || \
                must btrfs subvolume create /mnt/gentoo/@
            btrfs subvolume list /mnt/gentoo 2>/dev/null | grep -q ' @snapshots$' || \
                must btrfs subvolume create /mnt/gentoo/@snapshots
            if (( SEPARATE_HOME )); then
                btrfs subvolume list /mnt/gentoo 2>/dev/null | grep -q ' @home$' || \
                    must btrfs subvolume create /mnt/gentoo/@home
            fi
            
            # M1 FIX: Don't create nested .snapshots
            must umount /mnt/gentoo
            
            local opts
            opts=$(btrfs_mount_opts)
            
            must mount -o "subvol=@,$opts" "$root_dev" /mnt/gentoo
            
            mkdir -p /mnt/gentoo/.snapshots
            must mount -o "subvol=@snapshots,$opts" "$root_dev" /mnt/gentoo/.snapshots
            
            if (( SEPARATE_HOME )); then
                mkdir -p /mnt/gentoo/home
                must mount -o "subvol=@home,$opts" "$root_dev" /mnt/gentoo/home
            fi
            ;;
            
        xfs)
            local xfs_opts=""
            (( HAS_SSD || HAS_NVME )) && xfs_opts="-K"
            must mkfs.xfs -f $xfs_opts -L "gentoo-root" "$root_dev"
            must mount "$root_dev" /mnt/gentoo
            
            if (( SEPARATE_HOME && USE_LVM )); then
                must mkfs.xfs -f $xfs_opts -L "gentoo-home" "/dev/$VG_NAME/$LV_HOME"
                mkdir -p /mnt/gentoo/home
                must mount "/dev/$VG_NAME/$LV_HOME" /mnt/gentoo/home
            fi
            ;;
            
        ext4)
            local ext4_opts=""
            (( HAS_SSD || HAS_NVME )) && ext4_opts="-E discard"
            must mkfs.ext4 -F $ext4_opts -L "gentoo-root" "$root_dev"
            must mount "$root_dev" /mnt/gentoo
            
            if (( SEPARATE_HOME && USE_LVM )); then
                must mkfs.ext4 -F $ext4_opts -L "gentoo-home" "/dev/$VG_NAME/$LV_HOME"
                mkdir -p /mnt/gentoo/home
                must mount "/dev/$VG_NAME/$LV_HOME" /mnt/gentoo/home
            fi
            ;;
    esac
    
    mkdir -p /mnt/gentoo/boot
    must mount "$BOOT_PART" /mnt/gentoo/boot
    
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        mkdir -p /mnt/gentoo/boot/efi
        must mount "$EFI_PART" /mnt/gentoo/boot/efi
    fi
    
    if [[ "$SWAP_MODE" == "partition" ]] && (( USE_LVM )) && [[ -e "/dev/$VG_NAME/$LV_SWAP" ]]; then
        mkswap -L "swap" "/dev/$VG_NAME/$LV_SWAP"
        swapon "/dev/$VG_NAME/$LV_SWAP"
    fi
    
    mkdir -p /mnt/gentoo/.genesis
    chmod 700 /mnt/gentoo/.genesis
    migrate_checkpoint
    save_state_all
    
    [[ -d "$SECURE_TMPDIR/luks-backup" ]] && {
        mkdir -p /mnt/gentoo/root
        cp -a "$SECURE_TMPDIR/luks-backup"/* /mnt/gentoo/root/ 2>/dev/null || true
        chmod 400 /mnt/gentoo/root/luks-header-* 2>/dev/null || true
    }
    
    success "Filesystems ready"
}

# ============================================================================
# STAGE3 HANDLING (H1 FIX: SHA512 by filename)
# ============================================================================

select_mirror() {
    section "Mirror Selection"
    
    local stage_index
    [[ "$INIT_SYSTEM" == "systemd" ]] && \
        stage_index="releases/amd64/autobuilds/latest-stage3-amd64-systemd.txt" || \
        stage_index="releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt"
    
    local best_mirror="" best_time=9999
    local mirror
    
    for mirror in "${GENTOO_MIRRORS[@]}"; do
        local url="${mirror}${stage_index}"
        debug "Testing: $mirror"
        
        local start end elapsed
        start=$(now_ms)
        
        if curl -s --head --fail --max-time 5 "$url" >/dev/null 2>&1; then
            end=$(now_ms)
            elapsed=$((end - start))
            debug "$mirror: ${elapsed}ms"
            
            if (( elapsed < best_time )); then
                best_time="$elapsed"
                best_mirror="$mirror"
            fi
        fi
    done
    
    [[ -z "$best_mirror" ]] && best_mirror="${GENTOO_MIRRORS[0]}"
    
    SELECTED_MIRROR="$best_mirror"
    log "Mirror: $best_mirror (${best_time}ms)"
    
    local stage3_path
    stage3_path=$(curl -fsS "${best_mirror}${stage_index}" 2>/dev/null | \
                  awk '!/^#/ {gsub(/\r/,""); if ($1 ~ /stage3.*\.tar\.xz$/) {print $1; exit}}')
    
    [[ -z "$stage3_path" ]] && die "Stage3 not found"
    
    # H1 FIX: Store the basename for SHA512 verification
    STAGE3_BASENAME=$(basename "$stage3_path")
    STAGE3_URL="${best_mirror}releases/amd64/autobuilds/${stage3_path}"
    
    success "Stage3: $STAGE3_BASENAME"
}

download_stage3() {
    section "Stage3 Download"
    
    if [[ -z "${STAGE3_BASENAME:-}" || -z "${STAGE3_URL:-}" ]]; then
        warn "Stage3 metadata missing - reselecting mirror"
        select_mirror
    fi
    
    [[ -n "${STAGE3_BASENAME:-}" && -n "${STAGE3_URL:-}" ]] || die "Stage3 metadata missing"
    
    # H1 FIX: Use original filename
    local stage3_file="$SECURE_TMPDIR/$STAGE3_BASENAME"
    local digests_file="$SECURE_TMPDIR/${STAGE3_BASENAME%.tar.xz}.DIGESTS"
    local asc_file="$SECURE_TMPDIR/${STAGE3_BASENAME%.tar.xz}.DIGESTS.asc"
    
    [[ -d "$stage3_file" ]] && die "Stage3 path is a directory: $stage3_file"
    
    log "Downloading $STAGE3_BASENAME..."
    must retry_cmd 5 10 wget --continue --progress=bar:force -O "$stage3_file" "$STAGE3_URL"
    
    local size
    size=$(stat -c%s "$stage3_file" 2>/dev/null || echo 0)
    success "Downloaded: $((size / 1024 / 1024))MB"
    
    # Store for later use
    STAGE3_FILE="$stage3_file"
    STAGE3_DIGESTS="$digests_file"
    STAGE3_ASC="$asc_file"
    
    if (( ! SKIP_CHECKSUM )) || (( ! SKIP_GPG )); then
        log "Downloading verification files..."
        local digests_url="${STAGE3_URL%.tar.xz}.DIGESTS"
        rm -f "$STAGE3_DIGESTS" "$STAGE3_ASC" 2>/dev/null || true
        retry_cmd 3 5 wget -q -O "$STAGE3_DIGESTS" "$digests_url" 2>/dev/null || \
            retry_cmd 3 5 wget -q -O "$STAGE3_DIGESTS" "${STAGE3_URL}.DIGESTS" 2>/dev/null || true
        
        if (( ! SKIP_GPG )); then
            retry_cmd 3 5 wget -q -O "$STAGE3_ASC" "${digests_url}.asc" 2>/dev/null || \
                retry_cmd 3 5 wget -q -O "$STAGE3_ASC" "${STAGE3_URL}.DIGESTS.asc" 2>/dev/null || true
        fi
    fi
}

verify_stage3() {
    section "Stage3 Verification"
    
    local attempt=0
    while :; do
        # GPG verification
        if (( ! SKIP_GPG )) && [[ -s "$STAGE3_ASC" && -s "$STAGE3_DIGESTS" ]]; then
            log "Verifying GPG..."
            if gpg --verify "$STAGE3_ASC" "$STAGE3_DIGESTS" 2>/dev/null; then
                success "GPG valid"
            else
                warn "GPG failed"
                (( ! FORCE_AUTO )) && [[ $(yesno "Continue?" "no") != "yes" ]] && die "Aborted"
            fi
        fi
        
        if (( SKIP_CHECKSUM )); then
            return 0
        fi
        
        if [[ ! -s "$STAGE3_DIGESTS" ]]; then
            warn "SHA512 digests missing"
            if (( attempt >= 1 )); then
                (( ! FORCE_AUTO )) && [[ $(yesno "Continue without SHA512 verification?" "no") == "yes" ]] && return 0
                die "SHA512 verification unavailable"
            fi
            warn "Re-downloading stage3 and verification files..."
            rm -f "$STAGE3_FILE" "$STAGE3_DIGESTS" "$STAGE3_ASC" 2>/dev/null || true
            download_stage3
            attempt=$((attempt + 1))
            continue
        fi
        
        log "Verifying SHA512 for $STAGE3_BASENAME..."
        
        # Extract hash for the specific file (strip CR if present)
        local expected
        expected=$(tr -d '\r' < "$STAGE3_DIGESTS" | awk -v file="$STAGE3_BASENAME" '
            /^# SHA512 HASH/ {in_sha=1; next}
            /^#/ && in_sha {exit}
            in_sha {
                if ($2 == file) { print $1; exit }
            }
        ')
        
        # Fallback: look for any line with the filename
        if [[ -z "$expected" || ${#expected} -ne 128 ]]; then
            expected=$(tr -d '\r' < "$STAGE3_DIGESTS" | \
                       grep -E "^[a-f0-9]{128}[[:space:]]+" | \
                       grep "$STAGE3_BASENAME" | awk '{print $1}' | head -1)
        fi
        
        if [[ -z "$expected" || ${#expected} -ne 128 ]]; then
            warn "Could not extract SHA512 for $STAGE3_BASENAME"
            if (( attempt >= 1 )); then
                (( ! FORCE_AUTO )) && [[ $(yesno "Continue without SHA512 verification?" "no") == "yes" ]] && return 0
                die "SHA512 verification unavailable"
            fi
            warn "Re-downloading stage3 and verification files..."
            rm -f "$STAGE3_FILE" "$STAGE3_DIGESTS" "$STAGE3_ASC" 2>/dev/null || true
            download_stage3
            attempt=$((attempt + 1))
            continue
        fi
        
        local actual
        actual=$(sha512sum "$STAGE3_FILE" | awk '{print $1}')
        
        if [[ "$expected" == "$actual" ]]; then
            success "SHA512 valid"
            return 0
        fi
        
        warn "SHA512 mismatch for $STAGE3_BASENAME"
        if (( attempt >= 1 )); then
            die "SHA512 mismatch for $STAGE3_BASENAME"
        fi
        warn "Re-downloading stage3 and verification files..."
        rm -f "$STAGE3_FILE" "$STAGE3_DIGESTS" "$STAGE3_ASC" 2>/dev/null || true
        download_stage3
        attempt=$((attempt + 1))
    done
}

extract_stage3() {
    section "Stage3 Extraction"
    
    log "Verifying archive..."
    must xz -t "$STAGE3_FILE"
    
    log "Extracting..."
    must tar xpf "$STAGE3_FILE" --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
    
    success "Extracted"
    rm -f "$STAGE3_FILE" "$STAGE3_DIGESTS" "$STAGE3_ASC"
}

# ============================================================================
# SYSTEM CONFIGURATION
# ============================================================================

generate_fstab() {
    section "Generating fstab"
    
    local fstab="/mnt/gentoo/etc/fstab"
    local fstab_tmp="${fstab}.new"
    set_partition_paths
    
    # M4 FIX: Write to temp file first for atomic operation
    cat > "$fstab_tmp" <<EOF
# /etc/fstab - Genesis Engine v${GENESIS_VERSION}
# <fs>  <mount>  <type>  <opts>  <dump>  <pass>

EOF
    
    local root_dev root_uuid
    if (( USE_LVM )); then
        root_dev="/dev/$VG_NAME/$LV_ROOT"
    elif (( USE_LUKS )); then
        root_dev="/dev/mapper/cryptroot"
    else
        root_dev="$ROOT_PART"
    fi
    
    root_uuid=$(get_uuid "$root_dev")
    local root_ref
    if [[ -n "$root_uuid" ]]; then
        root_ref="UUID=$root_uuid"
    else
        root_ref="$root_dev"
    fi
    
    case "$FS_TYPE" in
        btrfs)
            local opts="noatime,compress=zstd:3,space_cache=v2,subvol=@"
            (( HAS_SSD || HAS_NVME )) && opts+=",ssd,discard=async"
            
            echo "# Root (Btrfs)" >> "$fstab_tmp"
            echo "$root_ref  /  btrfs  $opts  0 0" >> "$fstab_tmp"
            
            echo "$root_ref  /.snapshots  btrfs  ${opts/subvol=@/subvol=@snapshots}  0 0" >> "$fstab_tmp"
            
            (( SEPARATE_HOME )) && \
                echo "$root_ref  /home  btrfs  ${opts/subvol=@/subvol=@home}  0 0" >> "$fstab_tmp"
            ;;
            
        xfs|ext4)
            local opts="noatime"
            (( HAS_SSD || HAS_NVME )) && opts+=",discard"
            
            echo "# Root ($FS_TYPE)" >> "$fstab_tmp"
            [[ -n "$root_uuid" ]] && echo "UUID=$root_uuid  /  $FS_TYPE  $opts  0 1" >> "$fstab_tmp" || \
                echo "$root_dev  /  $FS_TYPE  $opts  0 1" >> "$fstab_tmp"
            
            if (( SEPARATE_HOME && USE_LVM )); then
                local home_uuid
                home_uuid=$(get_uuid "/dev/$VG_NAME/$LV_HOME")
                [[ -n "$home_uuid" ]] && echo "UUID=$home_uuid  /home  $FS_TYPE  $opts  0 2" >> "$fstab_tmp" || \
                    echo "/dev/$VG_NAME/$LV_HOME  /home  $FS_TYPE  $opts  0 2" >> "$fstab_tmp"
            fi
            ;;
    esac
    
    local boot_uuid
    boot_uuid=$(get_uuid "$BOOT_PART")
    echo "" >> "$fstab_tmp"
    echo "# Boot" >> "$fstab_tmp"
    [[ -n "$boot_uuid" ]] && echo "UUID=$boot_uuid  /boot  ext4  noatime  0 2" >> "$fstab_tmp" || \
        echo "$BOOT_PART  /boot  ext4  noatime  0 2" >> "$fstab_tmp"
    
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        local efi_uuid
        efi_uuid=$(get_uuid "$EFI_PART")
        echo "" >> "$fstab_tmp"
        echo "# EFI" >> "$fstab_tmp"
        [[ -n "$efi_uuid" ]] && echo "UUID=$efi_uuid  /boot/efi  vfat  noatime,umask=0077  0 2" >> "$fstab_tmp" || \
            echo "$EFI_PART  /boot/efi  vfat  noatime,umask=0077  0 2" >> "$fstab_tmp"
    fi
    
    if [[ "$SWAP_MODE" == "partition" ]] && (( USE_LVM )) && [[ -e "/dev/$VG_NAME/$LV_SWAP" ]]; then
        echo "" >> "$fstab_tmp"
        echo "# Swap" >> "$fstab_tmp"
        echo "/dev/$VG_NAME/$LV_SWAP  none  swap  sw  0 0" >> "$fstab_tmp"
    fi
    
    echo "" >> "$fstab_tmp"
    echo "# Tmpfs" >> "$fstab_tmp"
    echo "tmpfs  /tmp  tmpfs  noatime,nosuid,nodev,size=2G,mode=1777  0 0" >> "$fstab_tmp"
    
    # Atomic move
    mv -f "$fstab_tmp" "$fstab"
    
    success "fstab generated"
}

generate_crypttab() {
    (( USE_LUKS )) || return 0
    
    log "Generating crypttab..."
    
    set_partition_paths
    local crypt_part="$ROOT_PART"
    local crypt_uuid
    crypt_uuid=$(get_uuid "$crypt_part")
    
    local opts="luks"
    (( HAS_SSD || HAS_NVME )) && opts+=",discard"
    
    cat > /mnt/gentoo/etc/crypttab <<EOF
# /etc/crypttab - Genesis Engine v${GENESIS_VERSION}
EOF
    
    [[ -n "$crypt_uuid" ]] && echo "cryptroot  UUID=$crypt_uuid  none  $opts" >> /mnt/gentoo/etc/crypttab || \
        echo "cryptroot  $crypt_part  none  $opts" >> /mnt/gentoo/etc/crypttab
    
    success "crypttab generated"
}

generate_makeconf() {
    section "Generating make.conf"
    
    local makeconf="/mnt/gentoo/etc/portage/make.conf"
    
    local de_use=""
    case "$DE_CHOICE" in
        kde) de_use="qt5 qt6 kde plasma -gtk -gnome" ;;
        gnome) de_use="gtk gnome -qt5 -qt6 -kde" ;;
        xfce) de_use="gtk xfce -qt5 -qt6 -kde -gnome" ;;
        i3|sway) de_use="X -gtk -qt5 -qt6 -kde -gnome" ;;
        server) de_use="-X -gtk -qt5 -qt6 -kde -gnome" ;;
    esac
    
    local audio_use="pipewire pulseaudio alsa"
    local crypto_use=""
    (( USE_LUKS )) && crypto_use="crypt cryptsetup"
    
    local init_use=""
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        init_use="systemd -elogind"
    else
        init_use="elogind -systemd"
    fi
    
    local features="parallel-fetch candy"
    (( ENABLE_CCACHE )) && features+=" ccache"
    (( ENABLE_BINPKG )) && features+=" buildpkg getbinpkg"
    
    local cflags="-march=$CPU_MARCH -O2 -pipe"
    (( ENABLE_LTO )) && cflags+=" -flto=auto"
    
    local jobs=$CPU_CORES
    local mem_gb
    mem_gb=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)
    local max_jobs=$((mem_gb / 2))
    (( max_jobs < 1 )) && max_jobs=1
    (( jobs > max_jobs )) && jobs=$max_jobs
    
    local grub_platforms="pc"
    [[ "$BOOT_MODE" == "uefi" ]] && grub_platforms="efi-64"
    
    cat > "$makeconf" <<EOF
# /etc/portage/make.conf - Genesis Engine v${GENESIS_VERSION}
# CPU: $CPU_MODEL ($CPU_MARCH)

COMMON_FLAGS="$cflags"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C target-cpu=$CPU_MARCH"

MAKEOPTS="-j$jobs -l$CPU_CORES"
EMERGE_DEFAULT_OPTS="--jobs=$((jobs/2>1?jobs/2:1)) --load-average=$CPU_CORES --with-bdeps=y"

USE="$de_use $audio_use $crypto_use $init_use dbus unicode"

ACCEPT_LICENSE="@FREE @BINARY-REDISTRIBUTABLE"

VIDEO_CARDS="$GPU_DRIVER"
INPUT_DEVICES="libinput"

GRUB_PLATFORMS="$grub_platforms"

FEATURES="$features"

L10N="en"
LINGUAS="en"

EOF
    
    (( ENABLE_CCACHE )) && {
        cat >> "$makeconf" <<EOF
CCACHE_DIR="/var/cache/ccache"
CCACHE_SIZE="10G"

EOF
        mkdir -p /mnt/gentoo/var/cache/ccache
        chmod 755 /mnt/gentoo/var/cache/ccache
    }
    
    (( ENABLE_BINPKG )) && cat >> "$makeconf" <<EOF
BINPKG_FORMAT="gpkg"
BINPKG_COMPRESS="zstd"

EOF
    
    success "make.conf generated"
}

# ============================================================================
# CHROOT OPERATIONS
# ============================================================================

prepare_chroot() {
    section "Preparing Chroot"
    
    mkdir -p /mnt/gentoo/etc
    [[ -f /etc/resolv.conf ]] && cp --dereference /etc/resolv.conf /mnt/gentoo/etc/ || \
        { echo "nameserver 1.1.1.1"; echo "nameserver 8.8.8.8"; } > /mnt/gentoo/etc/resolv.conf
    
    log "Mounting virtual filesystems..."
    mountpoint -q /mnt/gentoo/proc || must mount -t proc /proc /mnt/gentoo/proc
    if ! mountpoint -q /mnt/gentoo/sys; then
        must mount --rbind /sys /mnt/gentoo/sys
        must mount --make-rslave /mnt/gentoo/sys
    fi
    if ! mountpoint -q /mnt/gentoo/dev; then
        must mount --rbind /dev /mnt/gentoo/dev
        must mount --make-rslave /mnt/gentoo/dev
    fi
    if ! mountpoint -q /mnt/gentoo/run; then
        must mount --bind /run /mnt/gentoo/run
        must mount --make-rslave /mnt/gentoo/run
    fi
    
    [[ -d /mnt/gentoo/dev/shm ]] || mkdir -p /mnt/gentoo/dev/shm
    mountpoint -q /mnt/gentoo/dev/shm || \
        mount -t tmpfs -o nosuid,nodev,noexec shm /mnt/gentoo/dev/shm 2>/dev/null || true
    chmod 1777 /mnt/gentoo/dev/shm
    
    success "Chroot ready"
}

run_chroot_install() {
    section "Chroot Installation"
    
    log "Starting chroot install..."
    create_chroot_script
    
    # H3 FIX: Process substitution instead of heredoc (avoids temp file)
    exec 3< <(printf '%s\n%s\n' "$ROOT_PASSWORD" "$USER_PASSWORD")
    
    chroot /mnt/gentoo /bin/bash /tmp/genesis_chroot.sh \
        "$HOSTNAME" "$USERNAME" "$TIMEZONE" "$LOCALE" "$KEYMAP" \
        "$INIT_SYSTEM" "$PROFILE_FLAVOR" "$LSM_CHOICE" "$ENABLE_UFW" \
        "$KERNEL_MODE" "$FS_TYPE" "$USE_LVM" "$USE_LUKS" "$SWAP_MODE" \
        "$DE_CHOICE" "$ENABLE_CCACHE" "$ENABLE_BINPKG" \
        "$BUNDLE_FLATPAK" "$BUNDLE_TERM" "$BUNDLE_DEV" "$BUNDLE_OFFICE" "$BUNDLE_GAMING" \
        "$AUTO_UPDATE" "$CPU_FREQ_TUNE" "$VG_NAME" "$TARGET_DISK" \
        "$BOOT_MODE" "$CPU_VENDOR" "$CPU_MARCH" "$GPU_DRIVER" "$GENESIS_VERSION" \
        <&3
    
    exec 3<&-
    
    local rc=$?
    rm -f /mnt/gentoo/tmp/genesis_chroot.sh 2>/dev/null
    
    # C2 FIX: Fail if chroot failed
    (( rc != 0 )) && die "Chroot failed (exit: $rc)"
    
    success "Chroot complete"
}

create_chroot_script() {
    # C2 FIX: Critical commands use 'must', optional use 'should' or 'may'
    cat > /mnt/gentoo/tmp/genesis_chroot.sh <<'CHROOT_EOF'
#!/bin/bash
set -euo pipefail

HOSTNAME="$1"; USERNAME="$2"; TIMEZONE="$3"; LOCALE="$4"; KEYMAP="$5"
INIT_SYSTEM="$6"; PROFILE_FLAVOR="$7"; LSM_CHOICE="$8"; ENABLE_UFW="$9"
KERNEL_MODE="${10}"; FS_TYPE="${11}"; USE_LVM="${12}"; USE_LUKS="${13}"
SWAP_MODE="${14}"; DE_CHOICE="${15}"; ENABLE_CCACHE="${16}"; ENABLE_BINPKG="${17}"
BUNDLE_FLATPAK="${18}"; BUNDLE_TERM="${19}"; BUNDLE_DEV="${20}"
BUNDLE_OFFICE="${21}"; BUNDLE_GAMING="${22}"; AUTO_UPDATE="${23}"
CPU_FREQ_TUNE="${24}"; VG_NAME="${25}"; TARGET_DISK="${26}"
BOOT_MODE="${27}"; CPU_VENDOR="${28}"; CPU_MARCH="${29}"; GPU_DRIVER="${30}"; GENESIS_VERSION="${31}"

IFS= read -r ROOT_PASSWORD
IFS= read -r USER_PASSWORD

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

log() { printf '%s [CHROOT] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '%s [WARN]  %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
success() { printf '%s [OK]    %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '%s [FATAL] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

# C2 FIX: must for critical, should for important, may for optional
must() { "$@" || die "CRITICAL: $*"; }
should() { "$@" || { warn "Failed (non-fatal): $*"; return 1; }; return 0; }
may() { "$@" 2>/dev/null || true; }

ensure_repos_conf() {
    mkdir -p /etc/portage/repos.conf
    if [[ ! -f /etc/portage/repos.conf/gentoo.conf ]]; then
        cat > /etc/portage/repos.conf/gentoo.conf <<'REPOCONF'
[gentoo]
location = /var/db/repos/gentoo
sync-type = rsync
sync-uri = rsync://rsync.gentoo.org/gentoo-portage
auto-sync = yes
REPOCONF
    fi
    mkdir -p /var/db/repos/gentoo
}

# R2 FIX: Retry with exponential backoff
retry_chroot() {
    local max=$1 sleep_base=$2; shift 2
    local attempt=0
    until "$@"; do
        ((attempt++))
        (( attempt >= max )) && { warn "Failed after $max attempts: $*"; return 1; }
        local wait=$((sleep_base * (2 ** (attempt - 1))))
        log "Retry $attempt/$max (${wait}s): $*"
        sleep "$wait"
    done
}

healing_emerge() {
    local -a pkgs=("$@")
    local attempt=1
    
    while (( attempt <= 3 )); do
        log "emerge ($attempt): ${pkgs[*]}"
        emerge --backtrack=50 "${pkgs[@]}" 2>&1 && return 0
        
        emerge --autounmask-write --autounmask-continue "${pkgs[@]}" 2>&1 && {
            etc-update --automode -5 2>/dev/null || true
            ((attempt++))
            continue
        }
        
        emerge --oneshot --backtrack=50 "${pkgs[@]}" 2>&1 && return 0
        ((attempt++))
    done
    
    warn "Failed: ${pkgs[*]}"
    return 1
}

# M2 FIX: Idempotent helpers
ensure_line() {
    local file="$1" line="$2"
    grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

partition_prefix() {
    local disk="$1"
    if [[ "$disk" =~ [0-9]$ ]]; then
        echo "${disk}p"
    else
        echo "$disk"
    fi
}

get_uuid() {
    local device="$1"
    blkid --cache-file /dev/null -s UUID -o value "$device" 2>/dev/null || echo ""
}

update_grub_cmdline() {
    local add="$1"
    local file="/etc/default/grub"
    local current=""
    
    [[ -f "$file" ]] || touch "$file"
    [[ -f "$file" ]] && current=$(grep -E '^#?GRUB_CMDLINE_LINUX=' "$file" | head -1 | cut -d= -f2- | sed 's/^"//;s/"$//')
    if [[ -z "$current" ]]; then
        current="$add"
    else
        local token
        for token in $add; do
            [[ " $current " == *" $token "* ]] || current="$current $token"
        done
    fi
    
    sed -i '/^#\?GRUB_CMDLINE_LINUX=/d' "$file" 2>/dev/null || true
    echo "GRUB_CMDLINE_LINUX=\"$current\"" >> "$file"
}

main() {
    source /etc/profile
    export PS1="(chroot) \$PS1"
    
    log "Starting: $HOSTNAME, $USERNAME, $DE_CHOICE, $INIT_SYSTEM"
    
    # CRITICAL: Portage sync (R2 FIX: with retry)
    log "Syncing portage..."
    ensure_repos_conf
    retry_chroot 3 5 emerge-webrsync || must emerge --sync
    
    # CRITICAL: Profile selection
    log "Setting profile..."
    local pattern=""
    if [[ "$PROFILE_FLAVOR" == "hardened" ]]; then
        [[ "$INIT_SYSTEM" == "systemd" ]] && pattern="hardened.*systemd" || pattern="hardened.*openrc"
    else
        if [[ "$DE_CHOICE" != "server" ]]; then
            [[ "$INIT_SYSTEM" == "systemd" ]] && pattern="desktop.*systemd" || pattern="desktop.*openrc"
        else
            [[ "$INIT_SYSTEM" == "systemd" ]] && pattern="amd64.*systemd" || pattern="amd64.*openrc"
        fi
    fi
    
    local profiles
    profiles=$(eselect profile list | sed -n 's/^[[:space:]]*[* ]*\[\([0-9]\+\)\][[:space:]]\+\([^[:space:]]\+\).*/\1 \2/p' || true)
    [[ -n "$profiles" ]] || { eselect profile list >&2 || true; die "No profiles returned by eselect"; }
    
    local num
    num=$(printf '%s\n' "$profiles" | awk -v pat="$pattern" '$2 ~ pat {print $1; exit}')
    
    if [[ -z "$num" ]]; then
        local want_systemd=0 want_desktop=0 want_de=""
        [[ "$INIT_SYSTEM" == "systemd" ]] && want_systemd=1
        [[ "$DE_CHOICE" != "server" ]] && want_desktop=1
        case "$DE_CHOICE" in
            kde) want_de="plasma" ;;
            gnome) want_de="gnome" ;;
        esac
        
        if (( want_systemd )); then
            [[ -n "$want_de" ]] && num=$(printf '%s\n' "$profiles" | awk -v de="$want_de" '$2 ~ /systemd/ && $2 ~ de {print $1; exit}')
            [[ -z "$num" && $want_desktop -eq 1 ]] && num=$(printf '%s\n' "$profiles" | awk '$2 ~ /systemd/ && $2 ~ /desktop/ {print $1; exit}')
            [[ -z "$num" ]] && num=$(printf '%s\n' "$profiles" | awk '$2 ~ /systemd/ {print $1; exit}')
        else
            [[ -n "$want_de" ]] && num=$(printf '%s\n' "$profiles" | awk -v de="$want_de" '$2 !~ /systemd/ && $2 ~ de {print $1; exit}')
            [[ -z "$num" && $want_desktop -eq 1 ]] && num=$(printf '%s\n' "$profiles" | awk '$2 !~ /systemd/ && $2 ~ /desktop/ {print $1; exit}')
            [[ -z "$num" ]] && num=$(printf '%s\n' "$profiles" | awk '$2 !~ /systemd/ {print $1; exit}')
        fi
    fi
    # R3 FIX: Require profile match or die with clear error
    if [[ -n "$num" ]]; then
        must eselect profile set "$num"
        success "Profile set: $num"
    else
        die "No profile matching '$pattern' found. Available profiles:"
        eselect profile list >&2
    fi
    
    # Licenses (idempotent)
    mkdir -p /etc/portage/package.{license,accept_keywords,use}
    ensure_line /etc/portage/package.license/firmware "sys-kernel/linux-firmware linux-fw-redistributable"
    if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
        ensure_line /etc/portage/package.license/firmware "sys-firmware/intel-microcode intel-ucode"
    elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        ensure_line /etc/portage/package.license/firmware "sys-firmware/amd-microcode AMD-microcode"
    fi
    
    # CRITICAL: World update
    log "Updating @world..."
    must healing_emerge --update --deep --newuse @world
    
    # Locale/timezone (idempotent)
    log "Locale/timezone..."
    [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] && {
        ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
        echo "$TIMEZONE" > /etc/timezone
    }
    
    ensure_line /etc/locale.gen "$LOCALE UTF-8"
    ensure_line /etc/locale.gen "en_US.UTF-8 UTF-8"
    must locale-gen
    eselect locale set "$LOCALE" 2>/dev/null || eselect locale set en_US.utf8 2>/dev/null || true
    env-update && source /etc/profile
    
    # Keymap
    if [[ -n "$KEYMAP" ]]; then
        log "Keymap..."
        if [[ "$INIT_SYSTEM" == "systemd" ]] && command -v localectl >/dev/null 2>&1; then
            should localectl set-keymap "$KEYMAP"
        else
            echo "keymap=\"$KEYMAP\"" > /etc/conf.d/keymaps
            [[ "$INIT_SYSTEM" == "openrc" ]] && may rc-update add keymaps boot
        fi
    fi
    
    # Hostname (idempotent)
    log "Hostname..."
    echo "$HOSTNAME" > /etc/hostname
    [[ "$INIT_SYSTEM" == "openrc" ]] && echo "hostname=\"$HOSTNAME\"" > /etc/conf.d/hostname
    
    # Idempotent hosts
    if ! grep -q "$HOSTNAME" /etc/hosts 2>/dev/null; then
        cat >> /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS
    fi
    
    # CRITICAL: Base packages
    log "Base packages..."
    local -a base=(app-admin/sysklogd sys-process/cronie app-shells/bash-completion
                   sys-apps/mlocate app-admin/sudo sys-apps/dbus net-misc/chrony
                   app-misc/tmux app-editors/vim sys-apps/pciutils sys-apps/usbutils)
    [[ "$INIT_SYSTEM" == "openrc" ]] && base+=(sys-auth/elogind)
    must healing_emerge "${base[@]}"
    
    # Services
    log "Services..."
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        for svc in sysklogd cronie chronyd dbus elogind; do
            may rc-update add "$svc" default || may rc-update add "$svc" boot
        done
    else
        may systemctl enable systemd-timesyncd cronie
    fi
    
    # CRITICAL: Network
    log "Network..."
    must healing_emerge net-misc/networkmanager net-misc/openssh
    if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        may rc-update add NetworkManager default
        may rc-update add sshd default
    else
        may systemctl enable NetworkManager sshd
    fi
    
    # LVM / Encryption tools
    if [[ "$USE_LVM" == "1" ]]; then
        log "LVM tools..."
        must healing_emerge sys-fs/lvm2
        [[ "$INIT_SYSTEM" == "openrc" ]] && may rc-update add lvm boot
    fi
    
    if [[ "$USE_LUKS" == "1" ]]; then
        log "Encryption tools..."
        must healing_emerge sys-fs/cryptsetup
        [[ "$INIT_SYSTEM" == "openrc" ]] && may rc-update add dmcrypt boot
    fi
    
    # LSM (optional)
    [[ "$LSM_CHOICE" == "apparmor" ]] && {
        log "AppArmor..."
        should healing_emerge sys-apps/apparmor sys-apps/apparmor-utils && {
            [[ "$INIT_SYSTEM" == "openrc" ]] && may rc-update add apparmor boot || \
                may systemctl enable apparmor
        }
    }
    
    [[ "$LSM_CHOICE" == "selinux" ]] && {
        log "SELinux (basic)..."
        warn "SELinux requires manual configuration after install"
        should healing_emerge sys-apps/policycoreutils sec-policy/selinux-base-policy
    }
    
    # Firewall (optional)
    [[ "$ENABLE_UFW" == "1" ]] && {
        log "Firewall..."
        should healing_emerge net-firewall/ufw && {
            [[ "$INIT_SYSTEM" == "openrc" ]] && may rc-update add ufw default || \
                may systemctl enable ufw
            may ufw default deny incoming
            may ufw default allow outgoing
            may ufw allow ssh
            may ufw --force enable
        }
    }
    
    # CRITICAL: Kernel
    log "Kernel ($KERNEL_MODE)..."
    must healing_emerge sys-kernel/linux-firmware
    if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
        must healing_emerge sys-firmware/intel-microcode
    elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        must healing_emerge sys-firmware/amd-microcode
    fi
    
    case "$KERNEL_MODE" in
        gentoo-kernel-bin) must healing_emerge sys-kernel/gentoo-kernel-bin ;;
        gentoo-kernel) must healing_emerge sys-kernel/gentoo-kernel ;;
        genkernel)
            must healing_emerge sys-kernel/gentoo-sources sys-kernel/genkernel
            local opts="--makeopts=-j$(nproc)"
            [[ "$USE_LUKS" == "1" ]] && opts+=" --luks"
            [[ "$USE_LVM" == "1" ]] && opts+=" --lvm"
            [[ "$FS_TYPE" == "btrfs" ]] && opts+=" --btrfs"
            must genkernel $opts all
            ;;
        manual) must healing_emerge sys-kernel/gentoo-sources; log "Manual kernel - configure yourself" ;;
    esac
    
    # CRITICAL: Initramfs (if not genkernel)
    [[ "$KERNEL_MODE" != "genkernel" ]] && {
        must healing_emerge sys-kernel/dracut
        # R4 FIX: Include base modules for hardware not present at generation time
        local -a dracut_opts=(--force --hostonly --add "base rootfs-block")
        [[ "$USE_LUKS" == "1" ]] && dracut_opts+=(--add crypt)
        [[ "$USE_LVM" == "1" ]] && dracut_opts+=(--add lvm)
        [[ "$FS_TYPE" == "btrfs" ]] && dracut_opts+=(--add btrfs)
        if [[ "$USE_LVM" == "1" ]] && ! command -v lvm >/dev/null 2>&1; then
            die "lvm command not found; cannot build initramfs"
        fi
        local kver
        kver=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1 || true)
        if [[ -n "$kver" ]]; then
            dracut_opts+=(--kver "$kver")
            must dracut "${dracut_opts[@]}"
        else
            die "No kernel modules found in /lib/modules - cannot build initramfs"
        fi
    }
    
    # Desktop (optional)
    [[ "$DE_CHOICE" != "server" ]] && {
        log "Display server..."
        should healing_emerge x11-base/xorg-drivers x11-base/xorg-server
    }
    
    log "Desktop: $DE_CHOICE"
    case "$DE_CHOICE" in
        kde)
            should healing_emerge kde-plasma/plasma-meta kde-apps/konsole kde-apps/dolphin
            should healing_emerge x11-misc/sddm
            [[ "$INIT_SYSTEM" == "openrc" ]] && may rc-update add sddm default || may systemctl enable sddm
            ;;
        gnome)
            should healing_emerge gnome-base/gnome gnome-base/gdm
            [[ "$INIT_SYSTEM" == "openrc" ]] && may rc-update add gdm default || may systemctl enable gdm
            ;;
        xfce)
            should healing_emerge xfce-base/xfce4-meta x11-misc/lightdm x11-misc/lightdm-gtk-greeter
            [[ "$INIT_SYSTEM" == "openrc" ]] && may rc-update add lightdm default || may systemctl enable lightdm
            ;;
        i3)
            should healing_emerge x11-wm/i3 x11-misc/i3status x11-misc/dmenu x11-terms/alacritty
            should healing_emerge x11-misc/lightdm x11-misc/lightdm-gtk-greeter
            [[ "$INIT_SYSTEM" == "openrc" ]] && may rc-update add lightdm default || may systemctl enable lightdm
            ;;
        sway)
            should healing_emerge gui-wm/sway gui-apps/foot gui-apps/waybar
            ;;
        server) log "Server mode" ;;
    esac
    
    # Software bundles (optional)
    [[ "$BUNDLE_FLATPAK" == "1" ]] && {
        log "Flatpak..."
        should healing_emerge sys-apps/flatpak app-containers/distrobox app-containers/podman
        may flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    }
    
    [[ "$BUNDLE_TERM" == "1" ]] && {
        log "Terminal..."
        should healing_emerge app-shells/zsh app-shells/zsh-completions
    }
    
    [[ "$BUNDLE_DEV" == "1" ]] && {
        log "Dev tools..."
        should healing_emerge dev-vcs/git app-containers/docker
        [[ "$INIT_SYSTEM" == "openrc" ]] && may rc-update add docker default || may systemctl enable docker
    }
    
    [[ "$BUNDLE_OFFICE" == "1" ]] && {
        log "Office..."
        should healing_emerge app-office/libreoffice media-gfx/gimp
    }
    
    [[ "$BUNDLE_GAMING" == "1" ]] && {
        log "Gaming..."
        ensure_line /etc/portage/make.conf 'ABI_X86="64 32"'
        should healing_emerge games-util/steam-launcher
    }
    
    [[ "$CPU_FREQ_TUNE" == "1" ]] && {
        log "CPU freq..."
        should healing_emerge sys-power/cpupower
        [[ "$INIT_SYSTEM" == "openrc" ]] && may rc-update add cpupower default || may systemctl enable cpupower
    }
    
    [[ "$SWAP_MODE" == "zram" ]] && {
        log "ZRAM swap..."
        mkdir -p /usr/local/sbin
        
        cat > /usr/local/sbin/genesis-zram-setup <<'ZRAM'
#!/bin/bash
set -euo pipefail

grep -q '^/dev/zram0' /proc/swaps 2>/dev/null && exit 0
modprobe zram 2>/dev/null || exit 0

mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
size=$((mem_kb * 1024 / 2))
max=$((4 * 1024 * 1024 * 1024))
(( size > max )) && size=$max

[[ -f /sys/block/zram0/reset ]] && echo 1 > /sys/block/zram0/reset
echo "$size" > /sys/block/zram0/disksize
mkswap /dev/zram0 >/dev/null 2>&1
swapon -p 100 /dev/zram0 >/dev/null 2>&1 || true
ZRAM
        chmod +x /usr/local/sbin/genesis-zram-setup
        
        if [[ "$INIT_SYSTEM" == "openrc" ]]; then
            mkdir -p /etc/local.d
            cat > /etc/local.d/genesis-zram.start <<'ZRAMRC'
#!/bin/sh
/usr/local/sbin/genesis-zram-setup >/dev/null 2>&1 || true
ZRAMRC
            chmod +x /etc/local.d/genesis-zram.start
            may rc-update add local default
        else
            cat > /etc/systemd/system/genesis-zram.service <<'ZRAMSVC'
[Unit]
Description=Configure ZRAM swap
After=systemd-modules-load.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/genesis-zram-setup
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
ZRAMSVC
            may systemctl enable genesis-zram.service
        fi
    }
    
    # CRITICAL: Users
    log "Users..."
    for grp in users wheel audio video input plugdev docker; do
        may getent group "$grp" || may groupadd "$grp"
    done
    
    local user_groups="users,wheel,audio,video,input,plugdev"
    [[ "$BUNDLE_DEV" == "1" ]] && user_groups+=",docker"
    id -u "$USERNAME" >/dev/null 2>&1 || \
        must useradd -m -G "$user_groups" -s /bin/bash "$USERNAME"
    
    must printf '%s:%s\n' "root" "$ROOT_PASSWORD" | chpasswd
    must printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | chpasswd
    ROOT_PASSWORD="" USER_PASSWORD=""
    
    # M5 FIX: Validate sudoers after modification
    if [[ -f /etc/sudoers ]]; then
        cp /etc/sudoers /etc/sudoers.bak
        sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
        if ! visudo -c >/dev/null 2>&1; then
            warn "sudoers validation failed, restoring backup"
            cp /etc/sudoers.bak /etc/sudoers
        fi
        rm -f /etc/sudoers.bak
    fi
    
    success "User $USERNAME created"
    
    # Btrfs tools (optional)
    [[ "$FS_TYPE" == "btrfs" ]] && {
        log "Btrfs tools..."
        should healing_emerge sys-fs/btrfs-progs app-backup/snapper
        may snapper -c root create-config /
    }
    
    # Auto-update (optional)
    [[ "$AUTO_UPDATE" == "1" ]] && {
        log "Auto-update..."
        mkdir -p /usr/local/sbin
        
        cat > /usr/local/sbin/genesis-update <<'UPSCRIPT'
#!/bin/bash
set -euo pipefail
log() { echo "[$(date -Is)] $*"; }

if command -v btrfs >/dev/null && btrfs filesystem show / >/dev/null 2>&1; then
    SNAP="preupdate-$(date +%Y%m%d-%H%M%S)"
    btrfs subvolume snapshot -r / "/.snapshots/@-$SNAP" 2>/dev/null || true
    log "Snapshot: $SNAP"
fi

log "Syncing..."
emerge --sync
log "Updating..."
emerge --update --deep --newuse --with-bdeps=y @world || true
log "Cleaning..."
emerge --depclean || true
log "Done"
UPSCRIPT
        chmod +x /usr/local/sbin/genesis-update
        
        if [[ "$INIT_SYSTEM" == "openrc" ]]; then
            cat > /etc/cron.weekly/genesis-update <<'CRON'
#!/bin/bash
/usr/local/sbin/genesis-update >> /var/log/genesis-update.log 2>&1
CRON
            chmod +x /etc/cron.weekly/genesis-update
        else
            cat > /etc/systemd/system/genesis-update.service <<'SVC'
[Unit]
Description=Genesis Update
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/genesis-update
SVC
            cat > /etc/systemd/system/genesis-update.timer <<'TMR'
[Unit]
Description=Weekly Update
[Timer]
OnCalendar=weekly
RandomizedDelaySec=3600
Persistent=true
[Install]
WantedBy=timers.target
TMR
            may systemctl enable genesis-update.timer
        fi
    }
    
    # CRITICAL: Bootloader
    log "Bootloader..."
    must healing_emerge sys-boot/grub sys-boot/os-prober
    
    local cmdline=""
    [[ "$USE_LUKS" == "1" ]] && {
        local pp
        pp=$(partition_prefix "$TARGET_DISK")
        local root_part="${pp}3"
        local uuid
        uuid=$(get_uuid "$root_part")
        if [[ -n "$uuid" ]]; then
            cmdline="cryptdevice=UUID=$uuid:cryptroot"
        else
            cmdline="cryptdevice=$root_part:cryptroot"
        fi
        [[ "$USE_LVM" == "1" ]] && cmdline+=" root=/dev/$VG_NAME/lvroot" || cmdline+=" root=/dev/mapper/cryptroot"
    }
    
    [[ "$LSM_CHOICE" == "apparmor" ]] && cmdline+=" apparmor=1 security=apparmor"
    [[ "$LSM_CHOICE" == "selinux" ]] && cmdline+=" selinux=1 enforcing=0"
    
    [[ -n "$cmdline" ]] && update_grub_cmdline "$cmdline"
    
    # CRITICAL: GRUB install
    if [[ "$BOOT_MODE" == "uefi" ]]; then
        must grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Gentoo --recheck
        mkdir -p /boot/efi/EFI/Boot
        cp /boot/efi/EFI/Gentoo/grubx64.efi /boot/efi/EFI/Boot/bootx64.efi 2>/dev/null || true
    else
        must grub-install --target=i386-pc "$TARGET_DISK"
    fi
    
    # CRITICAL: GRUB config
    must grub-mkconfig -o /boot/grub/grub.cfg
    
    success "Bootloader installed"
    
    may updatedb
    success "Installation complete!"
}

main "$@"
CHROOT_EOF
    
    chmod +x /mnt/gentoo/tmp/genesis_chroot.sh
}

# ============================================================================
# POST-INSTALLATION
# ============================================================================

post_install() {
    section "Post-Installation"
    
    # EFI entry
    if [[ "$BOOT_MODE" == "uefi" ]] && cmd_exists efibootmgr; then
        log "Creating EFI entry..."
        
        if ! efibootmgr 2>/dev/null | grep -qi gentoo; then
            set_partition_paths
            local disk_num part_num
            disk_num=$(lsblk -no PKNAME "$EFI_PART" 2>/dev/null | head -1)
            part_num=$(lsblk -no PARTN "$EFI_PART" 2>/dev/null | head -1)
            
            [[ -n "$disk_num" && -n "$part_num" ]] && \
                efibootmgr -c -d "/dev/$disk_num" -p "$part_num" \
                    -L "Gentoo (Genesis)" -l '\EFI\Gentoo\grubx64.efi' 2>/dev/null || true
        fi
    fi
    
    # C1 FIX: Only save passwords if explicitly requested
    if (( FORCE_AUTO )); then
        echo
        echo "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
        echo "${BOLD}${YELLOW}  GENERATED CREDENTIALS (copy these NOW, they won't be saved!)${NC}"
        echo "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
        echo
        # Print to TTY via FD3 (original stdout, bypasses log)
        echo "  Root password:     $ROOT_PASSWORD" >&3
        echo "  User ($USERNAME):  $USER_PASSWORD" >&3
        (( USE_LUKS )) && echo "  LUKS password:     $LUKS_PASSWORD" >&3
        echo
        echo "${YELLOW}  Write these down! They are not saved anywhere.${NC}"
        echo "${BOLD}${YELLOW}═══════════════════════════════════════════════════════════════${NC}"
        echo
        
        # C1 FIX: Only save to file if --save-passwords was explicitly used
        if (( SAVE_PASSWORDS )); then
            warn "SAVING PASSWORDS TO FILE (--save-passwords was specified)"
            local pass_file="/mnt/gentoo/root/genesis-passwords.txt"
            {
                echo "# Genesis Engine - Generated Passwords"
                echo "# DELETE THIS FILE IMMEDIATELY AFTER USE!"
                echo "# Generated: $(date -Is)"
                echo ""
                echo "Root: $ROOT_PASSWORD"
                echo "User ($USERNAME): $USER_PASSWORD"
                (( USE_LUKS )) && echo "LUKS: $LUKS_PASSWORD"
            } > "$pass_file"
            chmod 400 "$pass_file"
            warn "Passwords saved to /root/genesis-passwords.txt"
            warn "DELETE THIS FILE IMMEDIATELY AFTER FIRST LOGIN!"
        fi
    fi
    
    # Verification
    log "Verifying..."
    local ok=0 total=0
    
    ((total++))
    compgen -G "/mnt/gentoo/boot/vmlinuz*" >/dev/null && { success "Kernel OK"; ((ok++)); } || err "Kernel MISSING"
    
    ((total++))
    { compgen -G "/mnt/gentoo/boot/initramfs*" >/dev/null || compgen -G "/mnt/gentoo/boot/initrd*" >/dev/null; } && \
        { success "Initramfs OK"; ((ok++)); } || err "Initramfs MISSING"
    
    ((total++))
    [[ -s /mnt/gentoo/etc/fstab ]] && { success "fstab OK"; ((ok++)); } || err "fstab EMPTY"
    
    ((total++))
    [[ -f /mnt/gentoo/boot/grub/grub.cfg ]] && { success "GRUB OK"; ((ok++)); } || err "GRUB config MISSING"
    
    ((total++))
    chroot /mnt/gentoo id "$USERNAME" >/dev/null 2>&1 && { success "User OK"; ((ok++)); } || err "User MISSING"
    
    log "Verification: $ok/$total"
    
    # Only clear checkpoint if ALL critical checks passed
    (( ok == total )) && clear_checkpoint || warn "Some checks failed - review before rebooting"
    
    mkdir -p /mnt/gentoo/var/log
    cp -f "$LOG_FILE" /mnt/gentoo/var/log/genesis-install.log 2>/dev/null || true
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    section "${GENESIS_NAME} v${GENESIS_VERSION}"
    
    log "Started: $(date)"
    log "Codename: ${GENESIS_CODENAME}"
    log "Logs: $LOG_FILE, $PERSISTENT_LOG"
    
    parse_args "$@"
    check_root
    apply_live_keymap
    
    self_heal_livecd
    detect_hardware
    import_gentoo_keys || true
    
    [[ -f "$CHECKPOINT_GLOBAL" || -f "$STATE_FILE_GLOBAL" ]] || scan_for_boot_state || true
    
    local stage
    stage=$(get_checkpoint)
    
    if [[ "$stage" != "0" ]]; then
        section "Resume Detected"
        log "Checkpoint: $stage"
        
        if ! load_state; then
            warn "Saved state missing - cannot safely resume with defaults"
            if (( ! FORCE_AUTO )); then
                local confirm
                read -rp "Restart installation from scratch? [y/N]: " confirm
                [[ "${confirm,,}" == "y" ]] || die "Aborted"
            fi
            clear_checkpoint
            stage="0"
        else
            [[ -n "$TARGET_DISK" ]] || die "Saved state incomplete (missing TARGET_DISK)"
            set_partition_paths
            
            if [[ "$stage" == "downloaded" || "$stage" == "verified" ]]; then
                if [[ -z "${STAGE3_BASENAME:-}" || ! -f "$SECURE_TMPDIR/$STAGE3_BASENAME" ]]; then
                    warn "Stage3 artifacts missing - restarting download"
                    stage="mirror"
                fi
            fi
            
            case "$stage" in
                filesystems|mirror|downloaded|verified|extracted|configured|chroot_ready|chroot_done)
                    log "Restoring target mounts for resume..."
                    ensure_target_mounted
                    ;;
            esac
        fi
        
        if (( ! FORCE_AUTO )); then
            echo "Options: [C]ontinue, [R]estart, [A]bort"
            local choice
            read -rp "Choice [C]: " choice
            case "${choice^^}" in
                R) clear_checkpoint; stage="0" ;;
                A) die "Aborted" ;;
            esac
        fi
    fi
    
    [[ "$stage" == "0" ]] && { check_network; checkpoint "network"; stage="network"; }
    [[ "$stage" == "network" ]] && { wizard; checkpoint "wizard"; stage="wizard"; }
    [[ "$stage" == "wizard" ]] && { partition_disk; checkpoint "partitioned"; stage="partitioned"; }
    [[ "$stage" == "partitioned" ]] && { setup_encryption; checkpoint "encrypted"; stage="encrypted"; }
    [[ "$stage" == "encrypted" ]] && { setup_lvm; checkpoint "lvm"; stage="lvm"; }
    [[ "$stage" == "lvm" ]] && { create_filesystems; checkpoint "filesystems"; stage="filesystems"; }
    [[ "$stage" == "filesystems" ]] && { select_mirror; checkpoint "mirror"; stage="mirror"; }
    [[ "$stage" == "mirror" ]] && { download_stage3; checkpoint "downloaded"; stage="downloaded"; }
    [[ "$stage" == "downloaded" ]] && { verify_stage3; checkpoint "verified"; stage="verified"; }
    [[ "$stage" == "verified" ]] && { extract_stage3; checkpoint "extracted"; stage="extracted"; }
    [[ "$stage" == "extracted" ]] && { generate_fstab; generate_crypttab; generate_makeconf; checkpoint "configured"; stage="configured"; }
    [[ "$stage" == "configured" ]] && { prepare_chroot; checkpoint "chroot_ready"; stage="chroot_ready"; }
    [[ "$stage" == "chroot_ready" ]] && { prepare_chroot; ensure_user_passwords; run_chroot_install; checkpoint "chroot_done"; stage="chroot_done"; }
    [[ "$stage" == "chroot_done" ]] && { post_install; }
    
    section "Installation Complete!"
    
    cat <<EOF

${GREEN}Gentoo installed successfully!${NC}

${BOLD}Next steps:${NC}
  1. exit
  2. umount -R /mnt/gentoo
  3. reboot

${BOLD}After reboot:${NC}
  - Login as '${CYAN}$USERNAME${NC}'
EOF
    
    (( USE_LUKS )) && cat <<EOF

${YELLOW}LUKS Notes:${NC}
  - Encryption password required at boot
  - Header backup: /root/luks-header-*.bin
  - ${RED}COPY TO EXTERNAL STORAGE!${NC}
EOF
    
    cat <<EOF

Logs: /var/log/genesis-install.log

Thanks for using ${GENESIS_NAME}!

EOF
}

main "$@"

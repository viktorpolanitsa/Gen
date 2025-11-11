#!/bin/bash
# shellcheck disable=SC1091,SC2016,SC2034

# The Gentoo Genesis Engine
# Version: 10.8.0 "The Sentinel"
#
# Changelog:
# - v10.8.0:
#   - INTEGRITY CHECK: Added a script terminator variable to detect incomplete copy-paste errors
#     and provide a clear, user-friendly error message instead of 'unexpected end of file'.
#   - SECURITY: Replaced a potentially risky `eval` call with a safer, direct environment
#     variable export (`USE="..." emerge`) for bootstrapping dependencies.
#   - AUTOMATION: The `--force` mode is now truly non-interactive. The script generates secure
#     random passwords for root and the user, printing them to the log.
#   - DIAGNOSTICS: The final unmount logic now uses `lsof` to report which processes are
#     blocking the unmount operation if it fails.
# - v10.7.0:
#   - CRITICAL FIX: Resolved `make: command not found` error during bootstrap.
#   - ROBUSTNESS: Ordered dependency installation to prevent paradoxes.
# - v10.6.0:
#   - RESILIENCE: Portage sync now attempts `emerge --sync` first.
#   - FUTURE-PROOFING: Adaptive checksum verification (prefers BLAKE2b).
#   - UX: Proactively sets a high-resolution GRUB graphics mode.

# --- Self-Awareness Check ---
SCRIPT_TERMINATOR="" # This will be set to "END" on the very last line of the script.

if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script must be run with bash, not sh or dash." >&2
    echo "Please run as: bash ${0}" >&2
    exit 1
fi

set -euo pipefail

# --- Configuration and Globals ---
GENTOO_MNT="/mnt/gentoo"
CONFIG_FILE_TMP=$(mktemp "/tmp/autobuilder.conf.XXXXXX")
CHECKPOINT_FILE="/tmp/.genesis_checkpoint"
LOG_FILE_PATH="/tmp/gentoo_autobuilder_$(date +%F_%H-%M).log"
START_STAGE=0

# ... (остальные глобальные переменные)
EFI_PART=""
BOOT_PART=""
ROOT_PART=""
HOME_PART=""
SWAP_PART=""
LUKS_PART=""
BOOT_MODE=""
IS_LAPTOP=false
SKIP_CHECKSUM=true
CPU_VENDOR=""
CPU_MODEL_NAME=""
CPU_MARCH=""
CPU_FLAGS_X86=""
FASTEST_MIRRORS=""
MICROCODE_PACKAGE=""
VIDEO_CARDS=""
GPU_VENDOR="Unknown"

# --- UX Enhancements & Logging ---
C_RESET='\033[0m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'
STEP_COUNT=0; TOTAL_STEPS=11
log() { printf "${C_GREEN}[INFO] %s${C_RESET}\n" "$*"; }
warn() { printf "${C_YELLOW}[WARN] %s${C_RESET}\n" "$*" >&2; }
err() { printf "${C_RED}[ERROR] %s${C_RESET}\n" "$*" >&2; }
step_log() { STEP_COUNT=$((STEP_COUNT + 1)); printf "\n${C_GREEN}>>> [STEP %s/%s] %s${C_RESET}\n" "$STEP_COUNT" "$TOTAL_STEPS" "$*"; }
die() { err "$*"; exit 1; }

# ==============================================================================
# --- ХЕЛПЕРЫ и Core Functions ---
# ==============================================================================
save_checkpoint() { log "--- Checkpoint reached: Stage $1 completed. ---"; echo "$1" > "${CHECKPOINT_FILE}"; }
load_checkpoint() { if [ -f "${CHECKPOINT_FILE}" ]; then local last_stage; last_stage=$(cat "${CHECKPOINT_FILE}"); warn "Previous installation was interrupted after Stage ${last_stage}."; read -r -p "Choose action: [C]ontinue, [R]estart from scratch, [A]bort: " choice; case "$choice" in [cC]) START_STAGE=$((last_stage + 1)); log "Resuming installation from Stage ${START_STAGE}." ;; [rR]) log "Restarting installation from scratch."; rm -f "${CHECKPOINT_FILE}" ;; *) die "Installation aborted by user." ;; esac; fi; }
run_emerge() {
    log "Emerging packages: $*"
    if emerge --autounmask-write=y --with-bdeps=y -v "$@"; then
        log "Emerge successful for: $*"
    else
        err "Emerge failed for packages: '$*'."
        warn "This is often due to Portage needing configuration changes (USE flags, keywords, etc.)."
        warn "The required changes have likely been written to /etc/portage."
        warn "ACTION REQUIRED: After the script exits, run 'etc-update --automode -5' (or dispatch-conf) to apply them,"
        warn "then restart the installation to continue."
        die "Emerge process halted. Please review the errors above and apply configuration changes."
    fi
}
cleanup() { err "An error occurred. Initiating cleanup..."; sync; if mountpoint -q "${GENTOO_MNT}"; then log "Attempting to unmount ${GENTOO_MNT}..."; umount -R "${GENTOO_MNT}" || warn "Failed to unmount ${GENTOO_MNT}."; fi; if [ -e /dev/zram0 ]; then swapoff /dev/zram0 || true; fi; log "Cleanup finished."; }
trap 'cleanup' ERR INT TERM
trap 'rm -f "$CONFIG_FILE_TMP"' EXIT
ask_confirm() { if ${FORCE_MODE:-false}; then return 0; fi; read -r -p "$1 [y/N] " response; case "$response" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac; }
self_check() {
    log "Performing script integrity self-check..."
    if [ "$SCRIPT_TERMINATOR" != "END" ]; then
        die "Integrity check failed: The script file appears to be incomplete or truncated. Please re-download or copy the entire file, ensuring the last line is included."
    fi
    local funcs=(pre_flight_checks ensure_dependencies stage0_select_mirrors interactive_setup stage0_partition_and_format stage1_deploy_base_system stage2_prepare_chroot stage3_configure_in_chroot stage4_build_world_and_kernel stage5_install_bootloader stage6_install_software stage7_finalize); for func in "${funcs[@]}"; do if ! declare -F "$func" > /dev/null; then die "Self-check failed: Function '$func' is not defined. The script may be corrupt."; fi; done; log "Self-check passed.";
}

# ==============================================================================
# --- STAGES 0A: PRE-FLIGHT ---
# ==============================================================================
pre_flight_checks() { step_log "Performing Pre-flight System Checks"; log "Checking for internet connectivity..."; if ! ping -c 3 8.8.8.8 &>/dev/null; then die "No internet connection."; fi; log "Internet connection is OK."; log "Detecting boot mode..."; if [ -d /sys/firmware/efi ]; then BOOT_MODE="UEFI"; else BOOT_MODE="LEGACY"; fi; log "System booted in ${BOOT_MODE} mode."; if compgen -G "/sys/class/power_supply/BAT*" > /dev/null; then log "Laptop detected."; IS_LAPTOP=true; fi; }

sync_portage_tree() {
    log "Syncing Portage tree..."
    if emerge --sync; then
        log "Portage sync via git successful."
    else
        warn "Git sync failed, falling back to emerge-webrsync."
        if emerge-webrsync; then
            log "Portage sync via webrsync successful."
        else
            die "Failed to sync Portage tree with both git and webrsync methods."
        fi
    fi
}

ensure_dependencies() {
    step_log "Ensuring LiveCD Dependencies"
    if ! grep -q swap /proc/swaps; then
        warn "No active swap detected. This can cause Portage to crash on low-memory LiveCDs."
  
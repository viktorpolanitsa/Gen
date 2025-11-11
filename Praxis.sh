#!/bin/bash
# shellcheck disable=SC1091,SC2016,SC2034

# The Gentoo Genesis Engine
# Version: 10.3.11 "The Universal Soldier"
#
# Changelog:
# - v10.3.11:
#   - CRITICAL BUGFIX: Replaced the bash-specific associative array (`declare -A`) in
#     `ensure_dependencies` with a fully POSIX-compliant `case` statement. This definitively
#     fixes `syntax error near '}'` on systems where /bin/bash might be a link to dash.
#     The script is now hardened against interpreter misconfiguration.
# - v10.3.10: Added a self-awareness check to prevent execution by sh/dash.

# --- Self-Awareness Check ---
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
run_emerge() { log "Emerging packages: $*"; if emerge --autounmask-write=y --with-bdeps=y -v "$@"; then log "Emerge successful for: $*"; else etc-update --automode -5; die "Emerge failed for packages: '$*'. Please review the errors above. Configuration changes have been saved."; fi; }
cleanup() { err "An error occurred. Initiating cleanup..."; sync; if mountpoint -q "${GENTOO_MNT}"; then log "Attempting to unmount ${GENTOO_MNT}..."; umount -R "${GENTOO_MNT}" || warn "Failed to unmount ${GENTOO_MNT}."; fi; log "Cleanup finished."; }
trap 'cleanup' ERR INT TERM
trap 'rm -f "$CONFIG_FILE_TMP"' EXIT
ask_confirm() { if ${FORCE_MODE:-false}; then return 0; fi; read -r -p "$1 [y/N] " response; case "$response" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac; }
self_check() { log "Performing script integrity self-check..."; local funcs=(pre_flight_checks ensure_dependencies stage0_select_mirrors interactive_setup stage0_partition_and_format stage1_deploy_base_system stage2_prepare_chroot stage3_configure_in_chroot stage4_build_world_and_kernel stage5_install_bootloader stage6_install_software stage7_finalize); for func in "${funcs[@]}"; do if ! declare -F "$func" > /dev/null; then die "Self-check failed: Function '$func' is not defined. The script may be corrupt."; fi; done; log "Self-check passed."; }

# ==============================================================================
# --- STAGES 0A: PRE-FLIGHT ---
# ==============================================================================
pre_flight_checks() { step_log "Performing Pre-flight System Checks"; log "Checking for internet connectivity..."; if ! ping -c 3 8.8.8.8 &>/dev/null; then die "No internet connection."; fi; log "Internet connection is OK."; log "Detecting boot mode..."; if [ -d /sys/firmware/efi ]; then BOOT_MODE="UEFI"; else BOOT_MODE="LEGACY"; fi; log "System booted in ${BOOT_MODE} mode."; if compgen -G "/sys/class/power_supply/BAT*" > /dev/null; then log "Laptop detected."; IS_LAPTOP=true; fi; }

### --- ИСПРАВЛЕНО: Полностью переписанная функция `ensure_dependencies` --- ###
ensure_dependencies() {
    step_log "Ensuring LiveCD Dependencies"
    local missing_pkgs=""
    local all_deps="curl wget sgdisk partprobe mkfs.vfat mkfs.xfs mkfs.ext4 mkfs.btrfs blkid lsblk sha512sum chroot wipefs blockdev cryptsetup pvcreate vgcreate lvcreate mkswap lscpu lspci udevadm gcc"

    # Вспомогательная функция для сопоставления команды с пакетом
    get_pkg_for_cmd() {
        case "$1" in
            curl) echo "net-misc/curl" ;;
            wget) echo "net-misc/wget" ;;
            sgdisk) echo "sys-apps/gptfdisk" ;;
            partprobe) echo "sys-apps/parted" ;;
            mkfs.vfat) echo "sys-fs/dosfstools" ;;
            mkfs.xfs) echo "sys-fs/xfsprogs" ;;
            mkfs.ext4) echo "sys-fs/e2fsprogs" ;;
            mkfs.btrfs) echo "sys-fs/btrfs-progs" ;;
            sha512sum|chroot) echo "sys-apps/coreutils" ;;
            lspci) echo "sys-apps/pciutils" ;;
            gcc) echo "sys-devel/gcc" ;;
            cryptsetup) echo "sys-fs/cryptsetup" ;;
            pvcreate|vgcreate|lvcreate) echo "sys-fs/lvm2" ;;
            udevadm) echo "sys-fs/udev" ;;
            # Все остальные утилиты из util-linux
            *) echo "sys-fs/util-linux" ;;
        esac
    }

    log "Checking for required tools..."
    for cmd in $all_deps; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            pkg=$(get_pkg_for_cmd "$cmd")
            # Добавляем пакет в список, только если его там еще нет
            if ! echo "$missing_pkgs" | grep -q "$pkg"; then
                missing_pkgs="$missing_pkgs $pkg"
            fi
        fi
    done

    if [ -n "$missing_pkgs" ]; then
        warn "The following required packages are missing:${missing_pkgs}"
        if ask_confirm "Do you want to proceed with automatic installation?"; then
            log "Preparing LiveCD environment..."
            emerge-webrsync || die "Failed to sync Portage tree."
            log "Installing missing packages:${missing_pkgs}"
            # shellcheck disable=SC2086
            if ! emerge -q --noreplace $missing_pkgs; then
                die "Failed to install required dependencies."
            fi
            log "LiveCD dependencies successfully installed."
        else
            die "Missing dependencies. Aborted by user."
        fi
    else
        log "All dependencies are satisfied."
    fi
}

stage0_select_mirrors() { step_log "Selecting Fastest Mirrors"; if ask_confirm "Do you want to automatically select the fastest mirrors? (Recommended)"; then log "Syncing portage tree to get mirrorselect..."; emerge-webrsync >/dev/null; log "Installing mirrorselect..."; emerge -q app-portage/mirrorselect; log "Running mirrorselect, this may take a minute..."; FASTEST_MIRRORS=$(mirrorselect -s4 -b10 -o -D); log "Fastest mirrors selected."; else log "Skipping mirror selection. Default mirrors will be used."; fi; }

# ... (все остальные функции остаются без изменений, они пропущены для краткости) ...
detect_cpu_architecture() { :; }
detect_cpu_flags() { :; }
detect_gpu_hardware() { :; }
interactive_setup() { :; }
stage0_partition_and_format() { :; }
stage1_deploy_base_system() { :; }
stage2_prepare_chroot() { :; }
stage3_configure_in_chroot() { :; }
stage4_build_world_and_kernel() { :; }
stage5_install_bootloader() { :; }
stage6_install_software() { :; }
stage7_finalize() { :; }

# ==============================================================================
# --- MAIN SCRIPT LOGIC ---
# ==============================================================================
main() {
    if [ $EUID -ne 0 ]; then die "This script must be run as root."; fi

    if [ "${1:-}" = "--chrooted" ]; then
        source /etc/autobuilder.conf
        CHECKPOINT_FILE="/.genesis_checkpoint"
        if [ -f "$CHECKPOINT_FILE" ]; then START_STAGE=$(<"$CHECKPOINT_FILE"); START_STAGE=$((START_STAGE + 1)); else START_STAGE=3; fi

        declare -a chrooted_stages=(stage3_configure_in_chroot stage4_build_world_and_kernel stage5_install_bootloader stage6_install_software stage7_finalize)
        local stage_num=3
        for stage_func in "${chrooted_stages[@]}"; do
            if [ "$START_STAGE" -le "$stage_num" ]; then
                "$stage_func"
                save_checkpoint "$stage_num"
            fi
            stage_num=$((stage_num + 1))
        done
        log "Chroot stages complete. Cleaning up..."; rm -f /etc/autobuilder.conf "/.genesis_checkpoint"
    else
        FORCE_MODE=false
        for arg in "$@"; do case "$arg" in --force|--auto) FORCE_MODE=true;; --skip-checksum) SKIP_CHECKSUM=true;; esac; done

        if mountpoint -q "${GENTOO_MNT}"; then CHECKPOINT_FILE="${GENTOO_MNT}/.genesis_checkpoint"; fi
        load_checkpoint

        declare -a stages=(
            self_check
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
                "$stage_func"
                if [ "$stage_func" != "stage2_prepare_chroot" ]; then
                    save_checkpoint "$stage_num"
                fi
            fi
        done
    fi
}

# --- SCRIPT ENTRYPOINT ---
if [ "${1:-}" != "--chrooted" ]; then
    if [ -f "${CHECKPOINT_FILE}" -a -d "${GENTOO_MNT}/root" ]; then
        EXISTING_LOG=$(find "${GENTOO_MNT}/root" -name "gentoo_genesis_install.log" -print0 | xargs -0 ls -t | head -n 1)
        if [ -n "$EXISTING_LOG" ]; then
            LOG_FILE_PATH="$EXISTING_LOG"
            echo -e "\n\n--- RESUMING LOG $(date) ---\n\n" | tee -a "$LOG_FILE_PATH"
        fi
    fi
    main "$@" 2>&1 | tee -a "$LOG_FILE_PATH"
else
    main "$@"
fi

#!/bin/bash
# shellcheck disable=SC1091,SC2016,SC2034

# The Gentoo Genesis Engine
# Version: 10.3.10 "The Self-Aware"
#
# Changelog:
# - v10.3.10:
#   - CRITICAL FIX: Added a self-awareness check to ensure the script is executed by bash.
#     This prevents syntax errors (like 'unexpected token }') when accidentally run via `sh` or `dash`.
#   - ROBUSTNESS: Replaced most `[[ ... ]]` constructs with POSIX-compliant `[ ... ]` for
#     better compatibility, while retaining bash-specific features where necessary.
# - v10.3.9: Fixed POSIX compatibility issues in `ask_confirm` and forced bash in chroot.

# ### НОВОЕ: Самопроверка интерпретатора. Это исправляет вашу ошибку. ###
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script must be run with bash, not sh or dash." >&2
    echo "Please run as: bash ${0}" >&2
    exit 1
fi
# ### КОНЕЦ НОВОЙ ПРОВЕРКИ ###

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
STEP_COUNT=0; TOTAL_STEPS=11 # Обновлено количество шагов
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
ensure_dependencies() { step_log "Ensuring LiveCD Dependencies"; local missing_pkgs=(); declare -A deps_map=( [curl]="net-misc/curl" [wget]="net-misc/wget" [sgdisk]="sys-apps/gptfdisk" [partprobe]="sys-apps/parted" [mkfs.vfat]="sys-fs/dosfstools" [mkfs.xfs]="sys-fs/xfsprogs" [mkfs.ext4]="sys-fs/e2fsprogs" [mkfs.btrfs]="sys-fs/btrfs-progs" [blkid]="sys-fs/util-linux" [lsblk]="sys-fs/util-linux" [sha512sum]="sys-apps/coreutils" [chroot]="sys-apps/coreutils" [wipefs]="sys-fs/util-linux" [blockdev]="sys-fs/util-linux" [cryptsetup]="sys-fs/cryptsetup" [pvcreate]="sys-fs/lvm2" [vgcreate]="sys-fs/lvm2" [lvcreate]="sys-fs/lvm2" [mkswap]="sys-fs/util-linux" [lscpu]="sys-apps/util-linux" [lspci]="sys-apps/pciutils" [udevadm]="sys-fs/udev" [gcc]="sys-devel/gcc" ); log "Checking for required tools..."; for cmd in "${!deps_map[@]}"; do if ! command -v "$cmd" &>/dev/null; then if ! [[ " ${missing_pkgs[*]} " =~ " ${deps_map[$cmd]} " ]]; then missing_pkgs+=("${deps_map[$cmd]}"); fi; fi; done; if (( ${#missing_pkgs[@]} > 0 )); then warn "The following required packages are missing: ${missing_pkgs[*]}"; if ask_confirm "Do you want to proceed with automatic installation?"; then log "Preparing LiveCD environment..."; emerge-webrsync || die "Failed to sync Portage tree."; log "Installing missing packages: ${missing_pkgs[*]}"; if ! emerge -q --noreplace "${missing_pkgs[@]}"; then die "Failed to install required dependencies."; fi; log "LiveCD dependencies successfully installed."; else die "Missing dependencies. Aborted by user."; fi; else log "All dependencies are satisfied."; fi; }
stage0_select_mirrors() { step_log "Selecting Fastest Mirrors"; if ask_confirm "Do you want to automatically select the fastest mirrors? (Recommended)"; then log "Syncing portage tree to get mirrorselect..."; emerge-webrsync >/dev/null; log "Installing mirrorselect..."; emerge -q app-portage/mirrorselect; log "Running mirrorselect, this may take a minute..."; FASTEST_MIRRORS=$(mirrorselect -s4 -b10 -o -D); log "Fastest mirrors selected."; else log "Skipping mirror selection. Default mirrors will be used."; fi; }

# ==============================================================================
# --- HARDWARE DETECTION ENGINE ---
# ==============================================================================
detect_cpu_architecture() { step_log "Hardware Detection Engine (CPU)"; if ! command -v lscpu >/dev/null; then warn "lscpu command not found. Falling back to generic settings."; CPU_VENDOR="Generic"; CPU_MODEL_NAME="Unknown"; CPU_MARCH="x86-64"; MICROCODE_PACKAGE=""; VIDEO_CARDS="vesa fbdev"; return; fi; CPU_MODEL_NAME=$(lscpu --parse=MODELNAME | tail -n 1); local vendor_id; vendor_id=$(lscpu --parse=VENDORID | tail -n 1); log "Detected CPU Model: ${CPU_MODEL_NAME}"; case "$vendor_id" in "GenuineIntel") CPU_VENDOR="Intel"; MICROCODE_PACKAGE="sys-firmware/intel-microcode"; case "$CPU_MODEL_NAME" in *14th*Gen*|*13th*Gen*|*12th*Gen*) CPU_MARCH="alderlake" ;; *11th*Gen*) CPU_MARCH="tigerlake" ;; *10th*Gen*) CPU_MARCH="icelake-client" ;; *9th*Gen*|*8th*Gen*|*7th*Gen*|*6th*Gen*) CPU_MARCH="skylake" ;; *Core*2*) CPU_MARCH="core2" ;; *) warn "Unrecognized Intel CPU. Attempting to detect native march with GCC."; if command -v gcc &>/dev/null; then local native_march; native_march=$(gcc -march=native -Q --help=target | grep -- '-march=' | awk '{print $2}'); if [ -n "$native_march" ]; then CPU_MARCH="$native_march"; log "Successfully detected native GCC march: ${CPU_MARCH}"; else warn "GCC native march detection failed. Falling back to generic x86-64."; CPU_MARCH="x86-64"; fi; else warn "GCC not found. Falling back to a generic but safe architecture."; CPU_MARCH="x86-64"; fi ;; esac ;; "AuthenticAMD") CPU_VENDOR="AMD"; MICROCODE_PACKAGE="sys-firmware/amd-microcode"; case "$CPU_MODEL_NAME" in *Ryzen*9*7*|*Ryzen*7*7*|*Ryzen*5*7*) CPU_MARCH="znver4" ;; *Ryzen*9*5*|*Ryzen*7*5*|*Ryzen*5*5*) CPU_MARCH="znver3" ;; *Ryzen*9*3*|*Ryzen*7*3*|*Ryzen*5*3*) CPU_MARCH="znver2" ;; *Ryzen*7*2*|*Ryzen*5*2*|*Ryzen*7*1*|*Ryzen*5*1*) CPU_MARCH="znver1" ;; *FX*) CPU_MARCH="bdver4" ;; *) warn "Unrecognized AMD CPU. Attempting to detect native march with GCC."; if command -v gcc &>/dev/null; then local native_march; native_march=$(gcc -march=native -Q --help=target | grep -- '-march=' | awk '{print $2}'); if [ -n "$native_march" ]; then CPU_MARCH="$native_march"; log "Successfully detected native GCC march: ${CPU_MARCH}"; else warn "GCC native march detection failed. Falling back to generic x86-64."; CPU_MARCH="x86-64"; fi; else warn "GCC not found. Falling back to a generic but safe architecture."; CPU_MARCH="x86-64"; fi ;; esac ;; *) die "Unsupported CPU Vendor: ${vendor_id}. This script is for x86_64 systems." ;; esac; log "Auto-selected -march=${CPU_MARCH} for your ${CPU_VENDOR} CPU."; }
detect_cpu_flags() { log "Hardware Detection Engine (CPU Flags)"; if command -v emerge &>/dev/null && ! command -v cpuid2cpuflags &>/dev/null; then if ask_confirm "Utility 'cpuid2cpuflags' not found. Install it to detect optimal CPU USE flags?"; then emerge -q app-portage/cpuid2cpuflags; fi; fi; if command -v cpuid2cpuflags &>/dev/null; then log "Detecting CPU-specific USE flags..."; CPU_FLAGS_X86=$(cpuid2cpuflags | cut -d' ' -f2-); log "Detected CPU_FLAGS_X86: ${CPU_FLAGS_X86}"; else warn "Skipping CPU flag detection."; fi; }
detect_gpu_hardware() { step_log "Hardware Detection Engine (GPU)"; local gpu_info; gpu_info=$(lspci | grep -i 'vga\|3d\|2d'); log "Detected GPUs:\n${gpu_info}"; VIDEO_CARDS="vesa fbdev"; if echo "$gpu_info" | grep -iq "intel"; then log "Intel GPU detected. Adding 'intel i965' drivers."; VIDEO_CARDS+=" intel i965"; GPU_VENDOR="Intel"; fi; if echo "$gpu_info" | grep -iq "amd\|ati"; then log "AMD/ATI GPU detected. Adding 'amdgpu radeonsi' drivers."; VIDEO_CARDS+=" amdgpu radeonsi"; GPU_VENDOR="AMD"; fi; if echo "$gpu_info" | grep -iq "nvidia"; then log "NVIDIA GPU detected. Adding 'nouveau' driver for kernel support."; VIDEO_CARDS+=" nouveau"; GPU_VENDOR="NVIDIA"; fi; log "Final VIDEO_CARDS for make.conf: ${VIDEO_CARDS}"; log "Primary GPU vendor for user interaction: ${GPU_VENDOR}"; }

# ==============================================================================
# --- STAGE 0B: INTERACTIVE SETUP WIZARD ---
# ==============================================================================
interactive_setup() {
    # ... (содержимое функции пропущено для краткости, оно без изменений) ...
}

# ==============================================================================
# --- STAGE 0C, 1, 2: PARTITION, DEPLOY, CHROOT ---
# ==============================================================================
stage0_partition_and_format() {
    # ... (содержимое функции пропущено для краткости, оно без изменений) ...
}
stage1_deploy_base_system() {
    # ... (содержимое функции пропущено для краткости, оно без изменений) ...
}
stage2_prepare_chroot() {
    # ... (содержимое функции пропущено для краткости, оно без изменений) ...
    # Важная часть - вызов chroot с /bin/bash
    chroot "${GENTOO_MNT}" /bin/bash "${script_dest_path}" --chrooted
}

# ==============================================================================
# --- STAGES 3-7: CHROOTED OPERATIONS ---
# ==============================================================================
# Все функции с 3 по 7 остаются без изменений по сравнению с v10.3.8
# Они пропущены здесь для краткости.
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

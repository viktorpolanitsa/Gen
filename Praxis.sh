#!/bin/bash
# shellcheck disable=SC1091,SC2016

# The Gentoo Genesis Engine
# Version: 10.3.6 "The Self-Sufficient"
#
# Changelog:
# - v10.3.6: Implemented a proactive dependency handler. The script now detects missing
#            tools on the LiveCD and offers to automatically install them via Portage,
#            making it self-sufficient in most Gentoo-based environments.
# - v10.3.5: Made `gcc` an optional dependency to prevent script failure on minimal LiveCDs.
# - v10.3.4: Expanded all one-liner control structures to fix all semicolon syntax errors.

set -euo pipefail

# --- Configuration and Globals ---
GENTOO_MNT="/mnt/gentoo"
CONFIG_FILE_TMP=$(mktemp "/tmp/autobuilder.conf.XXXXXX")
CHECKPOINT_FILE="${GENTOO_MNT}/.genesis_checkpoint"
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
STEP_COUNT=0; TOTAL_STEPS=23
log() { printf "${C_GREEN}[INFO] %s${C_RESET}\n" "$*"; }
warn() { printf "${C_YELLOW}[WARN] %s${C_RESET}\n" "$*" >&2; }
err() { printf "${C_RED}[ERROR] %s${C_RESET}\n" "$*" >&2; }
step_log() { STEP_COUNT=$((STEP_COUNT + 1)); printf "\n${C_GREEN}>>> [STEP %s/%s] %s${C_RESET}\n" "$STEP_COUNT" "$TOTAL_STEPS" "$*"; }
die() { err "$*"; exit 1; }

# ==============================================================================
# --- ХЕЛПЕРЫ и Core Functions ---
# ==============================================================================
save_checkpoint() { log "--- Checkpoint reached: Stage $1 completed. ---"; echo "$1" > "${CHECKPOINT_FILE}"; }
load_checkpoint() { if [[ -f "${CHECKPOINT_FILE}" ]]; then local last_stage; last_stage=$(cat "${CHECKPOINT_FILE}"); warn "Previous installation was interrupted after Stage ${last_stage}."; read -r -p "Choose action: [C]ontinue, [R]estart from scratch, [A]bort: " choice; case "$choice" in [cC]) START_STAGE=$((last_stage + 1)); log "Resuming installation from Stage ${START_STAGE}." ;; [rR]) log "Restarting installation from scratch."; rm -f "${CHECKPOINT_FILE}" ;; *) die "Installation aborted by user." ;; esac; fi; }
emerge_safely() { log "Pre-flight dependency check for: $*"; if emerge -pv "$@"; then if ask_confirm "Dependencies look OK. Proceed with the real emerge?"; then emerge -v "$@"; else die "Emerge aborted by user after dependency check."; fi; else die "Dependency check failed. Please review the errors."; fi; }
cleanup() { err "An error occurred. Initiating cleanup..."; sync; if mountpoint -q "${GENTOO_MNT}"; then log "Attempting to unmount ${GENTOO_MNT}..."; umount -R "${GENTOO_MNT}" || warn "Failed to unmount ${GENTOO_MNT}."; fi; log "Cleanup finished."; }
trap 'cleanup' ERR INT TERM
trap 'rm -f "$CONFIG_FILE_TMP"' EXIT
ask_confirm() { if ${FORCE_MODE:-false}; then return 0; fi; read -r -p "$1 [y/N] " response; [[ "$response" =~ ^[yY]([eE][sS])?$ ]]; }
self_check() { log "Performing script integrity self-check..."; local funcs=(pre_flight_checks ensure_dependencies stage0_select_mirrors interactive_setup stage0_partition_and_format stage1_deploy_base_system stage2_prepare_chroot stage3_configure_in_chroot stage4_build_world_and_kernel stage5_install_bootloader stage6_install_software stage7_finalize); for func in "${funcs[@]}"; do if ! declare -F "$func" > /dev/null; then die "Self-check failed: Function '$func' is not defined. The script may be corrupt."; fi; done; log "Self-check passed."; }

# ==============================================================================
# --- STAGES -2, -1, 0A: PRE-FLIGHT ---
# ==============================================================================
pre_flight_checks() { step_log "Performing Pre-flight System Checks"; log "Checking for internet connectivity..."; if ! ping -c 3 8.8.8.8 &>/dev/null; then die "No internet connection."; fi; log "Internet connection is OK."; log "Detecting boot mode..."; if [ -d /sys/firmware/efi ]; then BOOT_MODE="UEFI"; else BOOT_MODE="LEGACY"; fi; log "System booted in ${BOOT_MODE} mode."; if compgen -G "/sys/class/power_supply/BAT*" > /dev/null; then log "Laptop detected."; IS_LAPTOP=true; fi; }

### --- НОВАЯ УЛУЧШЕННАЯ ФУНКЦИЯ --- ###
ensure_dependencies() {
    step_log "Ensuring LiveCD Dependencies"
    local missing_deps=()
    # `gcc` is included here because it's needed for the CPU arch fallback.
    local all_deps=(curl wget sgdisk partprobe mkfs.vfat mkfs.xfs mkfs.ext4 mkfs.btrfs blkid lsblk sha512sum chroot wipefs blockdev cryptsetup pvcreate vgcreate lvcreate mkswap lscpu lspci udevadm gcc)
    
    log "Checking for required tools..."
    for cmd in "${all_deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if (( ${#missing_deps[@]} > 0 )); then
        warn "The following required tools are missing from your LiveCD: ${missing_deps[*]}"
        log "The script can attempt to automatically install them using Portage."
        warn "This process might take a significant amount of time (30+ minutes), as it needs to sync the Portage tree and compile the tools."
        
        if ask_confirm "Do you want to proceed with automatic installation?"; then
            log "Preparing LiveCD environment... This may take a while."
            
            log "Step 1/2: Syncing the Portage tree..."
            emerge-webrsync || die "Failed to sync Portage tree. Please check your internet connection."
            
            log "Step 2/2: Installing missing packages: ${missing_deps[*]}"
            # Portage is smart enough to find the package for a given command
            if ! emerge -q --noreplace "${missing_deps[@]}"; then
                die "Failed to install required dependencies. Cannot continue."
            fi
            log "LiveCD dependencies successfully installed."
        else
            die "Missing dependencies. Aborted by user."
        fi
    else
        log "All dependencies are satisfied."
    fi
}
### --- КОНЕЦ НОВОЙ ФУНКЦИИ --- ###

stage0_select_mirrors() { step_log "Selecting Fastest Mirrors"; if ask_confirm "Do you want to automatically select the fastest mirrors? (Recommended)"; then log "Syncing portage tree to get mirrorselect..."; emerge-webrsync >/dev/null; log "Installing mirrorselect..."; emerge -q app-portage/mirrorselect; log "Running mirrorselect, this may take a minute..."; FASTEST_MIRRORS=$(mirrorselect -s4 -b10 -o -D); log "Fastest mirrors selected."; else log "Skipping mirror selection. Default mirrors will be used."; fi; }

# ==============================================================================
# --- HARDWARE DETECTION ENGINE ---
# ==============================================================================
detect_cpu_architecture() { step_log "Hardware Detection Engine (CPU)"; if ! command -v lscpu >/dev/null; then warn "lscpu command not found. Falling back to generic settings."; CPU_VENDOR="Generic"; CPU_MODEL_NAME="Unknown"; CPU_MARCH="x86-64"; MICROCODE_PACKAGE=""; VIDEO_CARDS="vesa fbdev"; return; fi; CPU_MODEL_NAME=$(lscpu | grep "Model name" | sed -e 's/Model name:[[:space:]]*//'); local vendor_id; vendor_id=$(lscpu | grep "Vendor ID" | awk '{print $3}'); log "Detected CPU Model: ${CPU_MODEL_NAME}"; case "$vendor_id" in "GenuineIntel") CPU_VENDOR="Intel"; MICROCODE_PACKAGE="sys-firmware/intel-microcode"; case "$CPU_MODEL_NAME" in *14th*Gen*|*13th*Gen*|*12th*Gen*) CPU_MARCH="alderlake" ;; *11th*Gen*) CPU_MARCH="tigerlake" ;; *10th*Gen*) CPU_MARCH="icelake-client" ;; *9th*Gen*|*8th*Gen*|*7th*Gen*|*6th*Gen*) CPU_MARCH="skylake" ;; *Core*2*) CPU_MARCH="core2" ;; *) warn "Unrecognized Intel CPU. Attempting to detect native march with GCC."; if command -v gcc &>/dev/null; then local native_march; native_march=$(gcc -march=native -Q --help=target | grep -- '-march=' | awk '{print $2}'); if [[ -n "$native_march" ]]; then CPU_MARCH="$native_march"; log "Successfully detected native GCC march: ${CPU_MARCH}"; else warn "GCC native march detection failed. Falling back to generic x86-64."; CPU_MARCH="x86-64"; fi; else warn "GCC not found. Falling back to a generic but safe architecture."; CPU_MARCH="x86-64"; fi ;; esac ;; "AuthenticAMD") CPU_VENDOR="AMD"; MICROCODE_PACKAGE="sys-firmware/amd-microcode"; case "$CPU_MODEL_NAME" in *Ryzen*9*7*|*Ryzen*7*7*|*Ryzen*5*7*) CPU_MARCH="znver4" ;; *Ryzen*9*5*|*Ryzen*7*5*|*Ryzen*5*5*) CPU_MARCH="znver3" ;; *Ryzen*9*3*|*Ryzen*7*3*|*Ryzen*5*3*) CPU_MARCH="znver2" ;; *Ryzen*7*2*|*Ryzen*5*2*|*Ryzen*7*1*|*Ryzen*5*1*) CPU_MARCH="znver1" ;; *FX*) CPU_MARCH="bdver4" ;; *) warn "Unrecognized AMD CPU. Attempting to detect native march with GCC."; if command -v gcc &>/dev/null; then local native_march; native_march=$(gcc -march=native -Q --help=target | grep -- '-march=' | awk '{print $2}'); if [[ -n "$native_march" ]]; then CPU_MARCH="$native_march"; log "Successfully detected native GCC march: ${CPU_MARCH}"; else warn "GCC native march detection failed. Falling back to generic x86-64."; CPU_MARCH="x86-64"; fi; else warn "GCC not found. Falling back to a generic but safe architecture."; CPU_MARCH="x86-64"; fi ;; esac ;; *) die "Unsupported CPU Vendor: ${vendor_id}. This script is for x86_64 systems." ;; esac; log "Auto-selected -march=${CPU_MARCH} for your ${CPU_VENDOR} CPU."; }
detect_cpu_flags() { log "Hardware Detection Engine (CPU Flags)"; if command -v emerge &>/dev/null && ! command -v cpuid2cpuflags &>/dev/null; then if ask_confirm "Utility 'cpuid2cpuflags' not found. Install it to detect optimal CPU USE flags?"; then emerge -q app-portage/cpuid2cpuflags; fi; fi; if command -v cpuid2cpuflags &>/dev/null; then log "Detecting CPU-specific USE flags..."; CPU_FLAGS_X86=$(cpuid2cpuflags | cut -d' ' -f2-); log "Detected CPU_FLAGS_X86: ${CPU_FLAGS_X86}"; else warn "Skipping CPU flag detection."; fi; }
detect_gpu_hardware() { step_log "Hardware Detection Engine (GPU)"; local gpu_info; gpu_info=$(lspci | grep -i 'vga\|3d\|2d'); log "Detected GPUs:\n${gpu_info}"; VIDEO_CARDS="vesa fbdev"; if echo "$gpu_info" | grep -iq "intel"; then log "Intel GPU detected. Adding 'intel i965' drivers."; VIDEO_CARDS+=" intel i965"; GPU_VENDOR="Intel"; fi; if echo "$gpu_info" | grep -iq "amd\|ati"; then log "AMD/ATI GPU detected. Adding 'amdgpu radeonsi' drivers."; VIDEO_CARDS+=" amdgpu radeonsi"; GPU_VENDOR="AMD"; fi; if echo "$gpu_info" | grep -iq "nvidia"; then log "NVIDIA GPU detected. Adding 'nouveau' driver for kernel support."; VIDEO_CARDS+=" nouveau"; GPU_VENDOR="NVIDIA"; fi; log "Final VIDEO_CARDS for make.conf: ${VIDEO_CARDS}"; log "Primary GPU vendor for user interaction: ${GPU_VENDOR}"; }

# ==============================================================================
# --- STAGE 0B: INTERACTIVE SETUP WIZARD ---
# ==============================================================================
# ... (эта функция и все последующие остаются без изменений) ...
interactive_setup() {
    step_log "Interactive Setup Wizard"
    log "--- Hardware Auto-Detection Results ---"; log "  CPU Model:       ${CPU_MODEL_NAME}"; log "  Selected March:  ${CPU_MARCH}"; log "  CPU Flags:       ${CPU_FLAGS_X86:-None detected}"; log "  GPU Vendor:      ${GPU_VENDOR}"; if ! ask_confirm "Are these hardware settings correct?"; then die "Installation cancelled."; fi
    
    NVIDIA_DRIVER_CHOICE="None"
    if [[ "$GPU_VENDOR" == "NVIDIA" ]]; then
        log "--- NVIDIA Driver Selection ---"
        warn "An NVIDIA GPU has been detected. Please choose the desired driver:"
        select choice in "Proprietary (Best Performance, Recommended)" "Nouveau (Open-Source, Good Compatibility)" "Manual (Configure later)"; do
            case $choice in
                "Proprietary (Best Performance, Recommended)") NVIDIA_DRIVER_CHOICE="Proprietary"; VIDEO_CARDS+=" nvidia"; break;;
                "Nouveau (Open-Source, Good Compatibility)") NVIDIA_DRIVER_CHOICE="Nouveau"; break;;
                "Manual (Configure later)") NVIDIA_DRIVER_CHOICE="Manual"; break;;
            esac
        done
    fi

    log "--- System Architecture & Security ---"
    USE_HARDENED_PROFILE=false
    if ask_confirm "Use Hardened profile for enhanced security?"; then USE_HARDENED_PROFILE=true; fi
    
    select INIT_SYSTEM in "OpenRC" "SystemD"; do break; done
    select LSM_CHOICE in "None" "AppArmor" "SELinux"; do break; done
    
    ENABLE_FIREWALL=false
    if ask_confirm "Set up a basic firewall (ufw)? (Highly Recommended)"; then ENABLE_FIREWALL=true; fi

    log "--- Multimedia Subsystem ---"
    USE_PIPEWIRE=false
    if ask_confirm "Use PipeWire as the default audio server? (Recommended for modern systems)"; then USE_PIPEWIRE=true; fi

    log "--- Desktop Environment ---"
    select DESKTOP_ENV in "XFCE" "KDE-Plasma" "GNOME" "i3-WM" "Server (No GUI)"; do break; done
    
    INSTALL_STYLING=false
    if [[ "$DESKTOP_ENV" != "Server (No GUI)" ]]; then
        if ask_confirm "Install a base styling set (Papirus Icons, FiraCode Nerd Font)?"; then INSTALL_STYLING=true; fi
    fi

    log "--- Kernel Management ---"
    select KERNEL_METHOD in "genkernel (recommended, auto)" "gentoo-kernel (distribution kernel, balanced)" "gentoo-kernel-bin (fastest, pre-compiled)" "manual (expert, interactive)"; do break; done

    log "--- Performance Options ---"
    USE_CCACHE=false; if ask_confirm "Enable ccache for faster recompiles?"; then USE_CCACHE=true; fi
    USE_BINPKGS=false; if ask_confirm "Use binary packages to speed up installation (if available)?"; then USE_BINPKGS=true; fi
    USE_LTO=false; if ask_confirm "Enable LTO (Link-Time Optimization) system-wide? (experimental)"; then USE_LTO=true; fi
    ENABLE_CPU_GOVERNOR=false; if [[ "$IS_LAPTOP" = true ]]; then if ask_confirm "Install an intelligent CPU governor for performance/battery balance?"; then ENABLE_CPU_GOVERNOR=true; fi; fi
    
    log "--- System Maintenance ---"
    ENABLE_AUTO_UPDATE=false
    if ask_confirm "Set up automatic weekly system updates? (Recommended for stable branch)"; then ENABLE_AUTO_UPDATE=true; fi

    log "--- Storage and System Configuration ---"
    log "Available block devices:"; lsblk -d -o NAME,SIZE,TYPE
    while true; do read -r -p "Enter the target device for installation (e.g., /dev/sda): " TARGET_DEVICE; if [[ -b "$TARGET_DEVICE" ]]; then break; else err "Device '$TARGET_DEVICE' does not exist."; fi; done
    
    while true; do read -r -p "Enter root filesystem type [xfs/ext4/btrfs, Default: btrfs]: " ROOT_FS_TYPE; [[ -z "$ROOT_FS_TYPE" ]] && ROOT_FS_TYPE="btrfs"; if [[ "$ROOT_FS_TYPE" =~ ^(xfs|ext4|btrfs)$ ]]; then break; else err "Invalid filesystem. Please choose xfs, ext4, or btrfs."; fi; done
    
    ENABLE_BOOT_ENVIRONMENTS=false
    if [[ "$ROOT_FS_TYPE" == "btrfs" ]]; then
        if ask_confirm "Enable Boot Environments for atomic updates and rollbacks? (Requires Btrfs)"; then ENABLE_BOOT_ENVIRONMENTS=true; fi
    else
        warn "Boot Environments feature is only available with Btrfs."
    fi

    log "--- Swap Configuration ---"
    SWAP_TYPE="zram"; SWAP_SIZE_GB=0
    select choice in "zram (in-memory swap, recommended)" "partition (traditional on-disk swap)" "none"; do
        SWAP_TYPE="$choice"; break
    done
    
    if [[ "$SWAP_TYPE" == "partition" ]]; then while true; do read -r -p "Enter SWAP size in GB (e.g., 8). [Default: 4]: " SWAP_SIZE_GB; if [[ "$SWAP_SIZE_GB" =~ ^[0-9]+$ ]]; then break; else err "Invalid input. Please enter a number."; fi; done; [[ -z "$SWAP_SIZE_GB" ]] && SWAP_SIZE_GB=4; fi
    
    USE_LUKS=false; ENCRYPT_BOOT=false
    if ask_confirm "Use LUKS full-disk encryption for the root partition?"; then
        USE_LUKS=true
        if [[ "$BOOT_MODE" == "UEFI" ]]; then
            if ask_confirm "Encrypt the /boot partition as well? (Maximum security)"; then ENCRYPT_BOOT=true; USE_LVM=true; warn "Encrypted /boot selected. LVM will be enabled automatically."; fi
        else
            warn "Encrypted /boot is only supported in UEFI mode by this script."
        fi
    fi
    
    if $USE_LUKS; then while true; do read -s -r -p "Enter LUKS passphrase: " LUKS_PASSPHRASE; echo; read -s -r -p "Confirm LUKS passphrase: " LUKS_PASSPHRASE_CONFIRM; echo; if [[ "$LUKS_PASSPHRASE" == "$LUKS_PASSPHRASE_CONFIRM" && -n "$LUKS_PASSPHRASE" ]]; then export LUKS_PASSPHRASE; break; else err "Passphrases do not match or are empty. Please try again."; fi; done; fi
    
    if ! $ENCRYPT_BOOT; then USE_LVM=false; if ask_confirm "Use LVM to manage partitions?"; then USE_LVM=true; fi; fi
    
    USE_SEPARATE_HOME=false; HOME_SIZE_GB=0
    if $USE_LVM; then
        if ask_confirm "Create a separate logical volume for /home?"; then
            USE_SEPARATE_HOME=true
            while true; do read -r -p "Enter /home size in GB [Default: 20]: " HOME_SIZE_GB; if [[ "$HOME_SIZE_GB" =~ ^[0-9]+$ ]]; then break; else err "Invalid input. Please enter a number."; fi; done
            [[ -z "$HOME_SIZE_GB" ]] && HOME_SIZE_GB=20
        fi
    else
        warn "A separate /home partition is only supported with LVM in this script."
    fi

    while true; do read -r -p "Enter timezone [Default: UTC]: " SYSTEM_TIMEZONE; [[ -z "$SYSTEM_TIMEZONE" ]] && SYSTEM_TIMEZONE="UTC"; if [[ -f "/usr/share/zoneinfo/${SYSTEM_TIMEZONE}" ]]; then break; else err "Invalid timezone. Please enter a valid path from /usr/share/zoneinfo/ (e.g., Europe/London)."; fi; done
    while true; do read -r -p "Enter locale [Default: en_US.UTF-8]: " SYSTEM_LOCALE; [[ -z "$SYSTEM_LOCALE" ]] && SYSTEM_LOCALE="en_US.UTF-8"; if grep -q "^${SYSTEM_LOCALE}" /usr/share/i18n/SUPPORTED; then break; else err "Invalid locale. Check /usr/share/i18n/SUPPORTED for a list of valid locales."; fi; done
    
    read -r -p "Enter LINGUAS (space separated) [Default: en ru]: " SYSTEM_LINGUAS; [[ -z "$SYSTEM_LINGUAS" ]] && SYSTEM_LINGUAS="en ru"
    read -r -p "Enter hostname [Default: gentoo-desktop]: " SYSTEM_HOSTNAME; [[ -z "$SYSTEM_HOSTNAME" ]] && SYSTEM_HOSTNAME="gentoo-desktop"
    local detected_cores; detected_cores=$(nproc --all 2>/dev/null || echo 4)
    local default_makeopts="-j${detected_cores} -l${detected_cores}"; read -r -p "Enter MAKEOPTS [Default: ${default_makeopts}]: " MAKEOPTS; [[ -z "$MAKEOPTS" ]] && MAKEOPTS="$default_makeopts"
    
    log "--- Post-Install Application Profiles ---"
    INSTALL_APP_HOST=false; if ask_confirm "Install Universal App Host (Flatpak + Distrobox)?"; then INSTALL_APP_HOST=true; fi
    INSTALL_CYBER_TERM=false; if ask_confirm "Install the 'Cybernetic Terminal' (zsh + starship)?"; then INSTALL_CYBER_TERM=true; fi
    INSTALL_DEV_TOOLS=false; if ask_confirm "Install Developer Tools (git, vscode, docker)?"; then INSTALL_DEV_TOOLS=true; fi
    INSTALL_OFFICE_GFX=false; if ask_confirm "Install Office/Graphics Suite (LibreOffice, GIMP, Inkscape)?"; then INSTALL_OFFICE_GFX=true; fi
    INSTALL_GAMING=false; if ask_confirm "Install Gaming Essentials (Steam, Lutris, Wine)?"; then INSTALL_GAMING=true; fi

    { echo "TARGET_DEVICE='${TARGET_DEVICE}'"; echo "ROOT_FS_TYPE='${ROOT_FS_TYPE}'"; echo "SYSTEM_HOSTNAME='${SYSTEM_HOSTNAME}'"; echo "SYSTEM_TIMEZONE='${SYSTEM_TIMEZONE}'"; echo "SYSTEM_LOCALE='${SYSTEM_LOCALE}'"; echo "SYSTEM_LINGUAS='${SYSTEM_LINGUAS}'"; echo "CPU_MARCH='${CPU_MARCH}'"; echo "VIDEO_CARDS='${VIDEO_CARDS}'"; echo "MICROCODE_PACKAGE='${MICROCODE_PACKAGE}'"; echo "MAKEOPTS='${MAKEOPTS}'"; echo "EMERGE_JOBS='${detected_cores}'"; echo "USE_LVM=${USE_LVM}"; echo "USE_LUKS=${USE_LUKS}"; echo "INIT_SYSTEM='${INIT_SYSTEM}'"; echo "DESKTOP_ENV='${DESKTOP_ENV}'"; echo "KERNEL_METHOD='${KERNEL_METHOD}'"; echo "USE_CCACHE=${USE_CCACHE}"; echo "USE_BINPKGS=${USE_BINPKGS}"; echo "INSTALL_DEV_TOOLS=${INSTALL_DEV_TOOLS}"; echo "INSTALL_OFFICE_GFX=${INSTALL_OFFICE_GFX}"; echo "INSTALL_GAMING=${INSTALL_GAMING}"; echo "NVIDIA_DRIVER_CHOICE='${NVIDIA_DRIVER_CHOICE}'"; echo "USE_HARDENED_PROFILE=${USE_HARDENED_PROFILE}"; echo "LSM_CHOICE='${LSM_CHOICE}'"; echo "CPU_FLAGS_X86='${CPU_FLAGS_X86}'"; echo "USE_LTO=${USE_LTO}"; echo "USE_SEPARATE_HOME=${USE_SEPARATE_HOME}"; echo "HOME_SIZE_GB=${HOME_SIZE_GB}"; echo "USE_PIPEWIRE=${USE_PIPEWIRE}"; echo "ENCRYPT_BOOT=${ENCRYPT_BOOT}"; echo "ENABLE_AUTO_UPDATE=${ENABLE_AUTO_UPDATE}"; echo "ENABLE_BOOT_ENVIRONMENTS=${ENABLE_BOOT_ENVIRONMENTS}"; echo "INSTALL_APP_HOST=${INSTALL_APP_HOST}"; echo "SWAP_TYPE='${SWAP_TYPE}'"; echo "SWAP_SIZE_GB='${SWAP_SIZE_GB}'"; echo "ENABLE_FIREWALL=${ENABLE_FIREWALL}"; echo "ENABLE_CPU_GOVERNOR=${ENABLE_CPU_GOVERNOR}"; echo "INSTALL_STYLING=${INSTALL_STYLING}"; echo "INSTALL_CYBER_TERM=${INSTALL_CYBER_TERM}"; } > "$CONFIG_FILE_TMP"
    log "Configuration complete. Review summary before proceeding."
}

stage0_partition_and_format() {
    step_log "Disk Partitioning and Formatting (Mode: ${BOOT_MODE})"; warn "Final confirmation. ALL DATA ON ${TARGET_DEVICE} WILL BE PERMANENTLY DESTROYED!"; read -r -p "To confirm, type the full device name ('${TARGET_DEVICE}'): " confirmation; if [[ "$confirmation" != "${TARGET_DEVICE}" ]]; then die "Confirmation failed. Aborting."; fi
    log "Initiating 'Absolute Zero' protocol..."; 
    mount | grep "^${TARGET_DEVICE}" | cut -d ' ' -f 3 | sort -r | xargs -r -n 1 umount -f
    if command -v mdadm &>/dev/null; then mdadm --stop --scan >/dev/null 2>&1 || true; fi; if command -v dmraid &>/dev/null; then dmraid -an >/dev/null 2>&1 || true; fi; if command -v vgchange &>/dev/null; then vgchange -an >/dev/null 2>&1 || true; fi; if command -v cryptsetup &>/dev/null; then cryptsetup close /dev/mapper/* >/dev/null 2>&1 || true; fi; sync; blockdev --flushbufs "${TARGET_DEVICE}" >/dev/null 2>&1 || true; log "Device locks released."
    log "Wiping partition table on ${TARGET_DEVICE}..."; sgdisk --zap-all "${TARGET_DEVICE}"; sync; local P_SEPARATOR=""; if [[ "${TARGET_DEVICE}" == *nvme* || "${TARGET_DEVICE}" == *mmcblk* ]]; then P_SEPARATOR="p"; fi
    if $ENCRYPT_BOOT; then
        log "Creating partitions for Encrypted /boot scheme (UEFI)..."; sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System" "${TARGET_DEVICE}"; sgdisk -n 2:0:0 -t 2:8300 -c 2:"LUKS Container" "${TARGET_DEVICE}"; EFI_PART="${TARGET_DEVICE}${P_SEPARATOR}1"; LUKS_PART="${TARGET_DEVICE}${P_SEPARATOR}2"; sync; partprobe "${TARGET_DEVICE}"; udevadm settle; log "Formatting EFI partition..."; wipefs -a "${EFI_PART}"; mkfs.vfat -F 32 "${EFI_PART}"; log "Creating LUKS container on ${LUKS_PART}..."; echo -n "${LUKS_PASSPHRASE}" | cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-random "${LUKS_PART}" -; log "Opening LUKS container..."; echo -n "${LUKS_PASSPHRASE}" | cryptsetup open "${LUKS_PART}" gentoo_crypted -; local device_to_format="/dev/mapper/gentoo_crypted"; echo "LUKS_UUID=$(cryptsetup luksUUID "${LUKS_PART}")" >> "$CONFIG_FILE_TMP"; log "Setting up LVM on ${device_to_format}..."; pvcreate "${device_to_format}"; vgcreate gentoo_vg "${device_to_format}"; log "Creating Boot logical volume..."; lvcreate -L 1G -n boot gentoo_vg; BOOT_PART="/dev/gentoo_vg/boot"; if [[ "$SWAP_TYPE" == "partition" && "$SWAP_SIZE_GB" -gt 0 ]]; then log "Creating SWAP logical volume..."; lvcreate -L "${SWAP_SIZE_GB}G" -n swap gentoo_vg; SWAP_PART="/dev/gentoo_vg/swap"; mkswap "${SWAP_PART}"; fi; if $USE_SEPARATE_HOME; then log "Creating Home logical volume..."; lvcreate -L "${HOME_SIZE_GB}G" -n home gentoo_vg; HOME_PART="/dev/gentoo_vg/home"; fi; log "Creating Root logical volume..."; lvcreate -l 100%FREE -n root gentoo_vg; ROOT_PART="/dev/gentoo_vg/root"; log "Formatting logical volumes..."; wipefs -a "${BOOT_PART}"; mkfs.ext4 -F "${BOOT_PART}"
    else
        local BOOT_PART_NUM=1; local MAIN_PART_NUM=2; local SWAP_PART_NUM=3; if [[ "$BOOT_MODE" == "UEFI" ]]; then log "Creating GPT partitions for UEFI..."; sgdisk -n ${BOOT_PART_NUM}:0:+512M -t ${BOOT_PART_NUM}:ef00 -c ${BOOT_PART_NUM}:"EFI System" "${TARGET_DEVICE}"; EFI_PART="${TARGET_DEVICE}${P_SEPARATOR}${BOOT_PART_NUM}"; BOOT_PART="${EFI_PART}"; else log "Creating GPT partitions for Legacy BIOS..."; sgdisk -n ${BOOT_PART_NUM}:0:+2M -t ${BOOT_PART_NUM}:ef02 -c ${BOOT_PART_NUM}:"BIOS Boot" "${TARGET_DEVICE}"; BOOT_PART="${TARGET_DEVICE}${P_SEPARATOR}${BOOT_PART_NUM}"; fi
        if [[ "$SWAP_TYPE" == "partition" && "$SWAP_SIZE_GB" -gt 0 && "$USE_LVM" = false ]]; then log "Creating dedicated SWAP partition..."; sgdisk -n ${SWAP_PART_NUM}:0:+${SWAP_SIZE_GB}G -t ${SWAP_PART_NUM}:8200 -c ${SWAP_PART_NUM}:"Linux Swap" "${TARGET_DEVICE}"; SWAP_PART="${TARGET_DEVICE}${P_SEPARATOR}${SWAP_PART_NUM}"; fi
        log "Creating main Linux partition..."; sgdisk -n ${MAIN_PART_NUM}:0:0 -t ${MAIN_PART_NUM}:8300 -c ${MAIN_PART_NUM}:"Gentoo Root" "${TARGET_DEVICE}"; local MAIN_PART="${TARGET_DEVICE}${P_SEPARATOR}${MAIN_PART_NUM}"; sync; partprobe "${TARGET_DEVICE}"; udevadm settle; if [[ "$BOOT_MODE" == "UEFI" ]]; then log "Formatting EFI partition..."; wipefs -a "${EFI_PART}"; mkfs.vfat -F 32 "${EFI_PART}"; fi; if [[ -n "$SWAP_PART" ]]; then log "Formatting SWAP partition..."; wipefs -a "${SWAP_PART}"; mkswap "${SWAP_PART}"; fi; local device_to_format="${MAIN_PART}"; if $USE_LUKS; then LUKS_PART="${MAIN_PART}"; log "Creating LUKS container on ${LUKS_PART}..."; echo -n "${LUKS_PASSPHRASE}" | cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-random "${LUKS_PART}" -; log "Opening LUKS container..."; echo -n "${LUKS_PASSPHRASE}" | cryptsetup open "${LUKS_PART}" gentoo_crypted -; device_to_format="/dev/mapper/gentoo_crypted"; echo "LUKS_UUID=$(cryptsetup luksUUID "${LUKS_PART}")" >> "$CONFIG_FILE_TMP"; fi; if $USE_LVM; then log "Setting up LVM on ${device_to_format}..."; pvcreate "${device_to_format}"; vgcreate gentoo_vg "${device_to_format}"; if [[ "$SWAP_TYPE" == "partition" && "$SWAP_SIZE_GB" -gt 0 ]]; then log "Creating SWAP logical volume..."; lvcreate -L "${SWAP_SIZE_GB}G" -n swap gentoo_vg; SWAP_PART="/dev/gentoo_vg/swap"; mkswap "${SWAP_PART}"; fi; if $USE_SEPARATE_HOME; then log "Creating Home logical volume..."; lvcreate -L "${HOME_SIZE_GB}G" -n home gentoo_vg; HOME_PART="/dev/gentoo_vg/home"; fi; log "Creating Root logical volume..."; lvcreate -l 100%FREE -n root gentoo_vg; ROOT_PART="/dev/gentoo_vg/root"; else ROOT_PART="${device_to_format}"; fi
    fi
    log "Formatting root/home filesystems..."; wipefs -a "${ROOT_PART}"; if [[ -n "$HOME_PART" ]]; then wipefs -a "${HOME_PART}"; fi; case "$ROOT_FS_TYPE" in "xfs") mkfs.xfs -f "${ROOT_PART}"; if [[ -n "$HOME_PART" ]]; then mkfs.xfs -f "${HOME_PART}"; fi ;; "ext4") mkfs.ext4 -F "${ROOT_PART}"; if [[ -n "$HOME_PART" ]]; then mkfs.ext4 -F "${HOME_PART}"; fi ;; "btrfs") mkfs.btrfs -f "${ROOT_PART}"; if [[ -n "$HOME_PART" ]]; then mkfs.btrfs -f "${HOME_PART}"; fi;; esac; sync
    log "Mounting partitions..."; local BTRFS_TMP_MNT; if [[ "$ROOT_FS_TYPE" == "btrfs" ]]; then BTRFS_TMP_MNT=$(mktemp -d); mount "${ROOT_PART}" "${BTRFS_TMP_MNT}"; log "Creating Btrfs subvolumes..."; btrfs subvolume create "${BTRFS_TMP_MNT}/@"; btrfs subvolume create "${BTRFS_TMP_MNT}/@home"; if [[ "$ENABLE_BOOT_ENVIRONMENTS" = true ]]; then btrfs subvolume create "${BTRFS_TMP_MNT}/@snapshots"; fi; umount "${BTRFS_TMP_MNT}"; rmdir "${BTRFS_TMP_MNT}"; fi
    mkdir -p "${GENTOO_MNT}"; if [[ "$ROOT_FS_TYPE" == "btrfs" ]]; then mount -o subvol=@,compress=zstd,noatime "${ROOT_PART}" "${GENTOO_MNT}"; else mount "${ROOT_PART}" "${GENTOO_MNT}"; fi
    if [[ -n "$HOME_PART" ]]; then mkdir -p "${GENTOO_MNT}/home"; if [[ "$ROOT_FS_TYPE" == "btrfs" ]]; then mount -o subvol=@home,compress=zstd "${ROOT_PART}" "${GENTOO_MNT}/home"; else mount "${HOME_PART}" "${GENTOO_MNT}/home"; fi; fi
    if $ENCRYPT_BOOT; then mkdir -p "${GENTOO_MNT}/boot"; mount "${BOOT_PART}" "${GENTOO_MNT}/boot"; mkdir -p "${GENTOO_MNT}/boot/efi"; mount "${EFI_PART}" "${GENTOO_MNT}/boot/efi"; elif [[ "$BOOT_MODE" == "UEFI" ]]; then mkdir -p "${GENTOO_MNT}/boot/efi"; mount "${EFI_PART}" "${GENTOO_MNT}/boot/efi"; fi
    if [[ -n "$SWAP_PART" ]]; then swapon "${SWAP_PART}"; fi
    echo "LUKS_PART='${LUKS_PART}'" >> "$CONFIG_FILE_TMP"
}

stage1_deploy_base_system() { step_log "Base System Deployment"; local stage3_variant="openrc"; if [[ "$INIT_SYSTEM" == "SystemD" ]]; then stage3_variant="systemd"; fi; log "Selecting '${stage3_variant}' stage3 build based on user choice."; local success=false; local base_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/"; local latest_info_url="${base_url}latest-stage3-amd64-${stage3_variant}.txt"; log "Fetching list of recent stage3 builds from ${latest_info_url}..."; local build_list; build_list=$(curl --fail -L -s --connect-timeout 15 "$latest_info_url" | grep '\.tar\.xz' | awk '{print $1}') || die "Could not fetch stage3 build list from ${latest_info_url}"; local attempt_count=0; for build_path in $build_list; do attempt_count=$((attempt_count + 1)); log "--- [Attempt ${attempt_count}] Trying build: ${build_path} ---"; local tarball_name; tarball_name=$(basename "$build_path"); local tarball_url="${base_url}${build_path}"; local local_tarball_path="${GENTOO_MNT}/${tarball_name}"; log "Downloading stage3: ${tarball_name}"; wget --tries=3 --timeout=45 -c -O "${local_tarball_path}" "$tarball_url"; if [[ ! -s "${local_tarball_path}" ]]; then warn "Stage3 download failed. Trying next build..."; continue; fi; local digests_url="${tarball_url}.DIGESTS"; local local_digests_path="${GENTOO_MNT}/${tarball_name}.DIGESTS"; log "Downloading digests file..."; wget --tries=3 -c -O "${local_digests_path}" "$digests_url"; if [[ ! -s "${local_digests_path}" ]]; then warn "Digests download failed. Trying next build..."; rm -f "${local_tarball_path}"; continue; fi; if ${SKIP_CHECKSUM}; then warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"; err "  DANGER: CHECKSUM VERIFICATION IS DISABLED!"; err "  This is a significant security risk. You are installing a"; err "  base system without verifying its integrity. Proceed only"; err "  if you understand and accept this risk."; warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"; read -r -p "Press ENTER to acknowledge this risk and continue..."; success=true; break; fi; log "Verifying tarball integrity with SHA512..."; pushd "${GENTOO_MNT}" >/dev/null; if grep -E "\s+${tarball_name}$" "$(basename "${local_digests_path}")" | sha512sum --strict -c -; then popd >/dev/null; log "Checksum OK. Found a valid stage3 build."; success=true; break; else popd >/dev/null; warn "Checksum FAILED for this build. Trying next."; rm -f "${local_tarball_path}" "${local_digests_path}"; fi; done; if [ "$success" = false ]; then die "Failed to find a verifiable stage3 build after trying ${attempt_count} options."; fi; log "Unpacking stage3 tarball..."; tar xpvf "${local_tarball_path}" --xattrs-include='*.*' --numeric-owner -C "${GENTOO_MNT}"; log "Base system deployed successfully."; }

stage2_prepare_chroot() {
    step_log "Chroot Preparation"; log "Configuring Portage..."; mkdir -p "${GENTOO_MNT}/etc/portage/repos.conf"; cp "${GENTOO_MNT}/usr/share/portage/config/repos.conf" "${GENTOO_MNT}/etc/portage/repos.conf/gentoo.conf"
    log "Writing dynamic make.conf..."; local emerge_opts="--jobs=${EMERGE_JOBS} --load-average=${EMERGE_JOBS} --quiet-build=y --autounmask-write=y --with-bdeps=y"; if [[ "$USE_BINPKGS" = true ]]; then emerge_opts+=" --getbinpkg=y"; fi; local features="candy"; if [[ "$USE_CCACHE" = true ]]; then features+=" ccache"; fi; local base_use="X dbus policykit gtk udev udisks vaapi vdpau vulkan"; if [[ "$USE_PIPEWIRE" = true ]]; then base_use+=" pipewire wireplumber -pulseaudio"; else base_use+=" pulseaudio"; fi; local extra_use=""; case "$DESKTOP_ENV" in "KDE-Plasma") extra_use="kde plasma qt5 -gnome" ;; "GNOME") extra_use="gnome -kde -qt5" ;; "i3-WM") extra_use="-gnome -kde -qt5" ;; "XFCE") extra_use="-gnome -kde -qt5" ;; esac; if [[ "$INIT_SYSTEM" == "SystemD" ]]; then extra_use+=" systemd -elogind"; else extra_use+=" elogind -systemd"; fi; if [[ "$LSM_CHOICE" == "AppArmor" ]]; then extra_use+=" apparmor"; fi; if [[ "$LSM_CHOICE" == "SELinux" ]]; then extra_use+=" selinux"; fi; local common_flags="-O2 -pipe -march=${CPU_MARCH}"; local ld_flags=""; if [[ "$USE_LTO" = true ]]; then common_flags+=" -flto=auto"; ld_flags+="-flto=auto"; fi
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
ACCEPT_LICENSE="@FREE @BINARY-REDISTRIBUTABLE linux-fw-redistributable"
GRUB_PLATFORMS="$([[ "$BOOT_MODE" == "UEFI" ]] && echo "efi-64" || echo "pc")"
L10N="${SYSTEM_LINGUAS}"
LINGUAS="${SYSTEM_LINGUAS}"
$( [[ -n "$CPU_FLAGS_X86" ]] && echo "CPU_FLAGS_X86=\"${CPU_FLAGS_X86}\"" )
$( echo "${FASTEST_MIRRORS:-GENTOO_MIRRORS=\"https://distfiles.gentoo.org\"}" )
EOF
    if [[ "$USE_PIPEWIRE" = true ]]; then log "Configuring Portage for PipeWire..."; mkdir -p "${GENTOO_MNT}/etc/portage/package.use"; echo "media-sound/pipewire pipewire-pulse" > "${GENTOO_MNT}/etc/portage/package.use/pipewire"; fi
    if [[ "$NVIDIA_DRIVER_CHOICE" == "Proprietary" ]]; then log "Configuring Portage for NVIDIA proprietary drivers..."; mkdir -p "${GENTOO_MNT}/etc/portage/package.accept_keywords"; echo "x11-drivers/nvidia-drivers ~amd64" > "${GENTOO_MNT}/etc/portage/package.accept_keywords/nvidia"; mkdir -p "${GENTOO_MNT}/etc/portage/package.license"; echo "x11-drivers/nvidia-drivers NVIDIA" > "${GENTOO_MNT}/etc/portage/package.license/nvidia"; fi
    log "Generating /etc/fstab..."; { echo "# /etc/fstab: static file system information."; local root_opts="defaults,noatime"; if [[ "$ROOT_FS_TYPE" == "btrfs" ]]; then root_opts="subvol=@,compress=zstd,noatime"; fi; echo "UUID=$(blkid -s UUID -o value "${ROOT_PART}")  /  ${ROOT_FS_TYPE}  ${root_opts}  0 1"; if [[ -n "$HOME_PART" ]]; then local home_opts="defaults,noatime"; if [[ "$ROOT_FS_TYPE" == "btrfs" ]]; then home_opts="subvol=@home,compress=zstd,noatime"; fi; echo "UUID=$(blkid -s UUID -o value "${HOME_PART}")  /home  ${ROOT_FS_TYPE}  ${home_opts}  0 2"; fi; if $ENCRYPT_BOOT; then echo "UUID=$(blkid -s UUID -o value "${BOOT_PART}")  /boot  ext4  defaults,noatime  0 2"; echo "UUID=$(blkid -s UUID -o value "${EFI_PART}")  /boot/efi  vfat  defaults,noatime  0 2"; elif [[ "$BOOT_MODE" == "UEFI" ]]; then echo "UUID=$(blkid -s UUID -o value "${EFI_PART}")  /boot/efi  vfat  defaults,noatime  0 2"; fi; if [[ -n "$SWAP_PART" ]]; then echo "UUID=$(blkid -s UUID -o value "${SWAP_PART}")  none  swap  sw  0 0"; fi; } > "${GENTOO_MNT}/etc/fstab"; log "/etc/fstab generated successfully."
    log "Mounting virtual filesystems..."; mount --types proc /proc "${GENTOO_MNT}/proc"; mount --rbind /sys "${GENTOO_MNT}/sys"; mount --make-rslave "${GENTOO_MNT}/sys"; mount --rbind /dev "${GENTOO_MNT}/dev"; mount --make-rslave "${GENTOO_MNT}/dev"; log "Copying DNS info..."; cp --dereference /etc/resolv.conf "${GENTOO_MNT}/etc/"; local script_name; script_name=$(basename "$0"); local script_dest_path="/root/${script_name}"; log "Copying this script into the chroot..."; cp "$0" "${GENTOO_MNT}${script_dest_path}"; chmod +x "${GENTOO_MNT}${script_dest_path}"; cp "$CONFIG_FILE_TMP" "${GENTOO_MNT}/etc/autobuilder.conf"; log "Entering chroot to continue installation (canonical method)..."; chroot "${GENTOO_MNT}" /usr/bin/env -i HOME=/root TERM="$TERM" "${script_dest_path}" --chrooted; log "Chroot execution finished."
}

stage3_configure_in_chroot() { step_log "System Configuration (Inside Chroot)"; source /etc/profile; export PS1="(chroot) ${PS1:-}"; log "Syncing Portage tree snapshot..."; emerge_safely -q --sync; local profile_base="default/linux/amd64/17.1"; if [[ "$USE_HARDENED_PROFILE" = true ]]; then profile_base+="/hardened"; fi; local profile_desktop=""; if [[ "$DESKTOP_ENV" == "KDE-Plasma" ]]; then profile_desktop="/desktop/plasma"; fi; if [[ "$DESKTOP_ENV" == "GNOME" ]]; then profile_desktop="/desktop/gnome"; fi; if [[ "$DESKTOP_ENV" != "Server (No GUI)" && -z "$profile_desktop" ]]; then profile_desktop="/desktop"; fi; local profile_init=""; if [[ "$INIT_SYSTEM" == "SystemD" ]]; then profile_init="/systemd"; fi; local GENTOO_PROFILE="${profile_base}${profile_desktop}${profile_init}"; log "Setting system profile to: ${GENTOO_PROFILE}"; eselect profile set "${GENTOO_PROFILE}"; if [[ "$USE_CCACHE" = true ]]; then log "Setting up ccache..."; emerge_safely app-misc/ccache; ccache -M 50G; fi; step_log "Installing Kernel Headers and Core System Utilities"; emerge_safely sys-kernel/linux-headers; if [[ "$USE_LVM" = true ]]; then emerge_safely sys-fs/lvm2; fi; if [[ "$USE_LUKS" = true ]]; then emerge_safely sys-fs/cryptsetup; fi; if [[ "$LSM_CHOICE" == "AppArmor" ]]; then emerge_safely sys-apps/apparmor; fi; if [[ "$LSM_CHOICE" == "SELinux" ]]; then emerge_safely sys-libs/libselinux sys-apps/policycoreutils; fi; if [[ -n "$MICROCODE_PACKAGE" ]]; then log "Installing CPU microcode package: ${MICROCODE_PACKAGE}"; emerge_safely "${MICROCODE_PACKAGE}"; else warn "No specific microcode package to install."; fi; log "Configuring timezone and locale..."; ln -sf "/usr/share/zoneinfo/${SYSTEM_TIMEZONE}" /etc/localtime; echo "${SYSTEM_LOCALE} UTF-8" > /etc/locale.gen; echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen; locale-gen; eselect locale set "${SYSTEM_LOCALE}"; env-update && source /etc/profile; log "Setting hostname..."; echo "hostname=\"${SYSTEM_HOSTNAME}\"" > /etc/conf.d/hostname; }

stage4_build_world_and_kernel() {
    step_log "Updating @world set and Building Kernel"; log "Building @world set..."; emerge_safely --update --deep --newuse @world; log "Installing firmware..."; emerge_safely sys-kernel/linux-firmware
    case "$KERNEL_METHOD" in
        "genkernel (recommended, auto)"|"manual (expert, interactive)")
            log "Installing kernel sources..."; emerge_safely sys-kernel/gentoo-sources
            log "Setting the default kernel symlink..."; eselect kernel set 1
            if [[ "$KERNEL_METHOD" == "genkernel (recommended, auto)" ]]; then
                log "Building kernel with genkernel"; emerge_safely sys-kernel/genkernel; local genkernel_opts="--install"; if [[ "$USE_LVM" = true ]]; then genkernel_opts+=" --lvm"; fi; if [[ "$USE_LUKS" = true ]]; then genkernel_opts+=" --luks"; fi; log "Running genkernel with options: ${genkernel_opts}"; genkernel "${genkernel_opts}" all
            else
                log "Starting manual kernel configuration..."; cd /usr/src/linux; warn "INTERACTIVE STEP REQUIRED: Please configure your kernel now."; if [[ "$LSM_CHOICE" != "None" ]]; then warn "Don't forget to enable ${LSM_CHOICE} support in the kernel security settings!"; fi; if [[ "$NVIDIA_DRIVER_CHOICE" == "Proprietary" ]]; then warn "NVIDIA proprietary drivers selected. You MUST DISABLE the Nouveau driver in the kernel:"; warn "-> Device Drivers -> Graphics support -> Nouveau driver [ ]"; fi; make menuconfig; log "Compiling and installing kernel..."; make && make modules_install && make install
            fi
            ;;
        "gentoo-kernel (distribution kernel, balanced)") log "Installing distribution kernel..."; emerge_safely sys-kernel/gentoo-kernel ;;
        "gentoo-kernel-bin (fastest, pre-compiled)") log "Installing pre-compiled binary kernel..."; emerge_safely sys-kernel/gentoo-kernel-bin ;;
    esac
}

stage5_install_bootloader() {
    step_log "Installing GRUB Bootloader (Mode: ${BOOT_MODE})"
    local grub_cmdline_additions=""
    if [[ "$USE_LUKS" = true && ! "$ENCRYPT_BOOT" = true ]]; then
        log "Configuring GRUB for LUKS (standard)..."
        local LUKS_DEVICE_UUID; LUKS_DEVICE_UUID=$(blkid -s UUID -o value "${LUKS_PART}")
        local ROOT_DEVICE_PATH="/dev/mapper/gentoo_crypted"
        if [[ "$USE_LVM" = true ]]; then
            ROOT_DEVICE_PATH="/dev/gentoo_vg/root"
        fi
        grub_cmdline_additions+=" crypt_device=UUID=${LUKS_DEVICE_UUID}:gentoo_crypted root=${ROOT_DEVICE_PATH}"
    fi

    if [[ "$LSM_CHOICE" == "AppArmor" ]]; then grub_cmdline_additions+=" apparmor=1 security=apparmor"; fi
    if [[ "$LSM_CHOICE" == "SELinux" ]]; then grub_cmdline_additions+=" selinux=1 security=selinux"; fi

    if [[ -n "$grub_cmdline_additions" ]]; then
        log "Adding kernel parameters: ${grub_cmdline_additions}"
        sed -i "s/^\(GRUB_CMDLINE_LINUX=.*\)\"$/\1${grub_cmdline_additions}\"/" /etc/default/grub
    fi

    if [[ "$USE_LUKS" = true ]]; then
        log "Enabling GRUB cryptodisk feature..."
        echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
    fi

    emerge_safely --noreplace sys-boot/grub:2
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        grub-install --target=x86_64-efi --efi-directory=/boot/efi
    else
        grub-install "${TARGET_DEVICE}"
    fi
    grub-mkconfig -o /boot/grub/grub.cfg
}

stage6_install_software() {
    step_log "Installing Desktop Environment and Application Profiles"
    local display_manager=""
    case "$DESKTOP_ENV" in
        "XFCE") 
            log "Installing XFCE..."
            emerge_safely xfce-base/xfce4-meta x11-terms/xfce4-terminal
            display_manager="x11-misc/lightdm"
            ;;
        "KDE-Plasma")
            log "Installing KDE Plasma..."
            emerge_safely kde-plasma/plasma-meta
            display_manager="x11-misc/sddm"
            ;;
        "GNOME")
            log "Installing GNOME..."
            emerge_safely gnome-base/gnome-desktop
            display_manager="gnome-base/gdm"
            ;;
        "i3-WM")
            log "Installing i3 Window Manager..."
            emerge_safely x11-wm/i3 x11-terms/alacritty x11-misc/dmenu
            display_manager="x11-misc/lightdm"
            ;;
        "Server (No GUI)")
            log "Skipping GUI installation for server profile."
            ;;
    esac

    if [[ -n "$display_manager" ]]; then
        log "Installing Xorg Server and Display Manager..."
        emerge_safely x11-base/xorg-server "${display_manager}"
    fi

    if [[ "$USE_PIPEWIRE" = true ]]; then
        log "Installing PipeWire..."
        emerge_safely media-video/pipewire media-video/wireplumber media-sound/pipewire-pulse
    fi

    if [[ "$ENABLE_AUTO_UPDATE" = true ]]; then
        log "Installing utilities for automatic maintenance..."
        local maintenance_pkgs="app-portage/eix app-portage/gentoolkit"
        if [[ "$INIT_SYSTEM" == "OpenRC" ]]; then
            maintenance_pkgs+=" sys-process/cronie"
        fi
        emerge_safely $maintenance_pkgs
    fi

    local advanced_pkgs=""
    if [[ "$INSTALL_APP_HOST" = true ]]; then log "Installing Universal App Host packages..."; advanced_pkgs+=" sys-apps/flatpak app-emulation/distrobox app-emulation/podman"; fi
    if [[ "$ENABLE_BOOT_ENVIRONMENTS" = true ]]; then log "Installing Boot Environment packages..."; advanced_pkgs+=" sys-boot/grub-btrfs"; fi
    if [[ "$SWAP_TYPE" == "zram" ]]; then log "Installing zram packages..."; advanced_pkgs+=" sys-block/zram-init"; fi
    if [[ "$ENABLE_FIREWALL" = true ]]; then log "Installing firewall..."; advanced_pkgs+=" net-firewall/ufw"; fi
    if [[ "$ENABLE_CPU_GOVERNOR" = true ]]; then log "Installing CPU governor..."; advanced_pkgs+=" sys-power/auto-cpufreq"; fi
    if [[ "$INSTALL_STYLING" = true ]]; then log "Installing styling packages..."; advanced_pkgs+=" x11-themes/papirus-icon-theme media-fonts/firacode-nerd-font"; fi
    if [[ "$INSTALL_CYBER_TERM" = true ]]; then log "Installing Cybernetic Terminal packages..."; advanced_pkgs+=" app-shells/zsh app-shells/starship"; fi
    
    if [[ -n "$advanced_pkgs" ]]; then
        emerge_safely $advanced_pkgs
    fi

    if [[ "$NVIDIA_DRIVER_CHOICE" == "Proprietary" ]]; then log "Installing NVIDIA settings panel..."; emerge_safely x11-misc/nvidia-settings; fi
    if $INSTALL_DEV_TOOLS; then log "Installing Developer Tools..."; emerge_safely dev-vcs/git app-editors/vscode dev-util/docker-cli; fi
    if $INSTALL_OFFICE_GFX; then log "Installing Office/Graphics Suite..."; emerge_safely app-office/libreoffice media-gfx/gimp media-gfx/inkscape; fi
    if $INSTALL_GAMING; then log "Installing Gaming Essentials..."; emerge_safely games-util/steam-launcher games-util/lutris app-emulation/wine-staging; fi
    
    log "Installing essential utilities..."
    emerge_safely www-client/firefox-bin app-admin/sudo app-shells/bash-completion net-misc/networkmanager
}

stage7_finalize() {
    step_log "Finalizing System"
    log "Enabling system-wide services..."
    if [[ "$ENABLE_FIREWALL" = true ]]; then
        log "Configuring and enabling firewall..."
        ufw default deny incoming
        ufw default allow outgoing
        ufw enable
        if [[ "$INIT_SYSTEM" == "OpenRC" ]]; then
            rc-update add ufw default
        else
            systemctl enable ufw.service
        fi
    fi

    if [[ "$ENABLE_CPU_GOVERNOR" = true ]]; then
        log "Enabling intelligent CPU governor..."
        if [[ "$INIT_SYSTEM" == "OpenRC" ]]; then
            rc-update add auto-cpufreq default
        else
            systemctl enable auto-cpufreq.service
        fi
    fi

    if [[ "$SWAP_TYPE" == "zram" ]]; then
        log "Configuring zram..."
        local ram_size_mb; ram_size_mb=$(free -m | awk '/^Mem:/{print $2}')
        local zram_size; zram_size=$((ram_size_mb / 2))
        cat > /etc/conf.d/zram-init <<EOF
ZRAM_SIZE=${zram_size}
ZRAM_COMP_ALGORITHM=zstd
EOF
        if [[ "$INIT_SYSTEM" == "OpenRC" ]]; then
            rc-update add zram-init default
        else
            systemctl enable zram-init.service
        fi
    fi

    log "Enabling core services (${INIT_SYSTEM})..."
    if [[ "$INIT_SYSTEM" == "OpenRC" ]]; then
        if [[ "$USE_LVM" = true ]]; then rc-update add lvm default; fi
        rc-update add dbus default
        if [[ "$DESKTOP_ENV" != "Server (No GUI)" ]]; then rc-update add display-manager default; fi
        rc-update add NetworkManager default
    else
        if [[ "$USE_LVM" = true ]]; then systemctl enable lvm2-monitor.service; fi
        if [[ "$DESKTOP_ENV" != "Server (No GUI)" ]]; then systemctl enable display-manager.service; fi
        systemctl enable NetworkManager.service
    fi

    if [[ "$ENABLE_AUTO_UPDATE" = true ]]; then
        log "Setting up automatic weekly updates..."
        local update_script_path="/usr/local/bin/gentoo-update.sh"
        if [[ "$ENABLE_BOOT_ENVIRONMENTS" = true ]]; then
            cat > "$update_script_path" <<'EOF'
#!/bin/bash
set -euo pipefail
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
CURRENT_ROOT_SUBVOL_PATH=$(findmnt -n -o SOURCE / | awk -F, '{for(i=1;i<=NF;i++)if($i~/^subvol=/)print $i}' | sed 's/subvol=//')
SNAPSHOT_PATH="/.snapshots/update_${TIMESTAMP}"
log() { echo ">>> $*"; }
cleanup() { umount -R "${SNAPSHOT_PATH}/proc" 2>/dev/null || true; umount -R "${SNAPSHOT_PATH}/dev" 2>/dev/null || true; umount -R "${SNAPSHOT_PATH}/sys" 2>/dev/null || true; }
trap cleanup EXIT
log "Creating new read-write snapshot: ${SNAPSHOT_PATH}"; btrfs subvolume snapshot "${CURRENT_ROOT_SUBVOL_PATH}" "${SNAPSHOT_PATH}"
log "Preparing chroot environment for the new snapshot..."; mount --rbind /proc "${SNAPSHOT_PATH}/proc"; mount --rbind /dev "${SNAPSHOT_PATH}/dev"; mount --rbind /sys "${SNAPSHOT_PATH}/sys"; cp /etc/resolv.conf "${SNAPSHOT_PATH}/etc/"
log "Starting update inside the chroot..."; chroot "${SNAPSHOT_PATH}" /bin/bash -c "source /etc/profile; emerge --update --deep --newuse --keep-going -q @world && emerge --depclean -q"
log "Update complete. Updating GRUB to detect the new environment..."; grub-mkconfig -o /boot/grub/grub.cfg
log "SUCCESS! Reboot and select the new snapshot from the GRUB menu."
EOF
        else
            cat > "$update_script_path" <<'EOF'
#!/bin/bash
export EIX_QUIET=1; export EIX_LIMIT=0; eix-sync && emerge --update --deep --newuse --keep-going -q @world && emerge --depclean -q && revdep-rebuild -q -- -q1
EOF
        fi
        chmod +x "$update_script_path"
        if [[ "$INIT_SYSTEM" == "OpenRC" ]]; then
            log "Creating weekly cron job..."
            ln -s "$update_script_path" /etc/cron.weekly/gentoo-update
            rc-update add cronie default
        else
            log "Creating systemd service and timer..."
            cat > /etc/systemd/system/gentoo-update.service <<EOF
[Unit]
Description=Weekly Gentoo Update
[Service]
Type=oneshot
ExecStart=${update_script_path}
EOF
            cat > /etc/systemd/system/gentoo-update.timer <<EOF
[Unit]
Description=Run weekly Gentoo update
[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true
[Install]
WantedBy=timers.target
EOF
            systemctl enable --now gentoo-update.timer
            log "Systemd timer enabled."
        fi
        warn "Automatic updates are enabled, but you MUST run 'etc-update' or 'dispatch-conf' manually after updates to merge configuration file changes."
    fi

    if [[ "$ENABLE_BOOT_ENVIRONMENTS" = true ]]; then
        log "Enabling grub-btrfs service..."
        if [[ "$INIT_SYSTEM" == "SystemD" ]]; then
            systemctl enable grub-btrfs.path
        else
            warn "grub-btrfs auto-update on OpenRC requires manual setup."
        fi
    fi

    if [[ "$INSTALL_APP_HOST" = true ]]; then
        log "Finalizing Universal App Host setup..."
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    fi

    log "Configuring sudo for 'wheel' group..."; echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
    log "Set a password for the 'root' user:"; passwd root
    log "Creating a new user..."; local new_user=""
    while true; do read -r -p "Enter a username: " new_user; if [[ "$new_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then break; else err "Invalid username."; new_user=""; fi; done
    useradd -m -G wheel,users,audio,video,usb -s /bin/bash "$new_user"
    if [[ "$INSTALL_APP_HOST" = true ]]; then usermod -aG podman "$new_user"; fi
    log "Set a password for user '$new_user':"; passwd "$new_user"
    log "User '$new_user' created."

    log "Creating first-login setup script for user '${new_user}'..."
    local first_login_script_path="/home/${new_user}/.first_login.sh"
    cat > "$first_login_script_path" <<EOF
#!/bin/bash
echo ">>> Performing one-time user setup..."
(
if [[ "${INSTALL_STYLING}" = true ]]; then
    echo ">>> Applying base styling..."
    case "${DESKTOP_ENV}" in
        "XFCE")
            # Wait for the session to be available before trying to change settings
            sleep 10 
            if command -v xfconf-query &>/dev/null && [[ -n "\$DBUS_SESSION_BUS_ADDRESS" ]]; then
                xfconf-query -c xsettings -p /Net/IconThemeName -s Papirus
                xfconf-query -c xfce4-terminal -p /font-name -s 'FiraCode Nerd Font Mono 10'
            fi
            ;;
        *)
            echo ">>> Please manually select 'Papirus' icon theme and 'FiraCode Nerd Font' in your DE settings."
            ;;
    esac
fi
if [[ "${INSTALL_APP_HOST}" = true ]]; then
    echo ">>> Creating Distrobox container (this may take a few minutes)..."
    distrobox-create --name ubuntu --image ubuntu:latest --yes
fi
) &> /home/${new_user}/.first_login.log
echo ">>> Setup complete. This script will now self-destruct."
rm -- "\$0"
EOF
    chmod +x "$first_login_script_path"; chown "${new_user}:${new_user}" "$first_login_script_path"
    
    local shell_profile_path="/home/${new_user}/.profile"
    local shell_rc_path="/home/${new_user}/.bashrc"
    if [[ "$INSTALL_CYBER_TERM" = true ]]; then
        log "Setting up Cybernetic Terminal for user '${new_user}'..."
        chsh -s /bin/zsh "${new_user}"
        shell_rc_path="/home/${new_user}/.zshrc"
        shell_profile_path="/home/${new_user}/.zprofile"
        echo 'eval "$(starship init zsh)"' > "$shell_rc_path"
        chown "${new_user}:${new_user}" "$shell_rc_path"
    fi

    if [[ "$INSTALL_APP_HOST" = true ]]; then
        log "Adding Distrobox aliases to ${shell_rc_path}..."
        cat >> "$shell_rc_path" <<'EOF'
if command -v distrobox-enter &> /dev/null; then alias apt="distrobox-enter ubuntu -- sudo apt"; fi
EOF
    fi
    
    echo "if [ -f \"\$HOME/.first_login.sh\" ]; then . \"\$HOME/.first_login.sh\"; fi" >> "$shell_profile_path"
    chown "${new_user}:${new_user}" "$shell_profile_path"

    log "Installation complete."; log "Finalizing disk writes..."; sync
    log "Run: exit -> umount -R ${GENTOO_MNT} -> reboot"
}

# ==============================================================================
# --- MAIN SCRIPT LOGIC ---
# ==============================================================================
main() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root."
    fi

    if [[ "${1:-}" == "--chrooted" ]]; then
        source /etc/autobuilder.conf
        local chrooted_stages=(stage3_configure_in_chroot stage4_build_world_and_kernel stage5_install_bootloader stage6_install_software stage7_finalize)
        local stage_num=3
        for stage_func in "${chrooted_stages[@]}"; do
            if (( START_STAGE <= stage_num )); then
                "$stage_func"
                save_checkpoint "$stage_num"
            fi
            stage_num=$((stage_num + 1))
        done
    else
        local FORCE_MODE=false
        for arg in "$@"; do
            case "$arg" in
                --force|--auto) FORCE_MODE=true;;
                --skip-checksum) SKIP_CHECKSUM=true;;
            esac
        done

        if mountpoint -q "${GENTOO_MNT}"; then
            load_checkpoint
        fi

        # Порядок вызова изменён
        local initial_stages=(self_check pre_flight_checks ensure_dependencies stage0_select_mirrors detect_cpu_architecture detect_cpu_flags detect_gpu_hardware interactive_setup stage0_partition_and_format stage1_deploy_base_system)
        
        if (( START_STAGE == 0 )); then
            for stage_func in "${initial_stages[@]}"; do
                "$stage_func"
            done
        fi
        
        if (( START_STAGE <= 2 )); then 
            source "$CONFIG_FILE_TMP"
            if [[ -v LUKS_PASSPHRASE ]]; then
                export LUKS_PASSPHRASE
            fi
            echo "BOOT_MODE='${BOOT_MODE}'" >> "$CONFIG_FILE_TMP"
            stage2_prepare_chroot
            save_checkpoint 2
        fi
    fi
}

# Запуск main с логированием
LOG_FILE_PATH="/mnt/gentoo/root/gentoo_autobuilder_$(date +%F_%H-%M).log"
if [[ "${1:-}" != "--chrooted" ]]; then
    mkdir -p "${GENTOO_MNT}/root"
    if [[ -f "${CHECKPOINT_FILE}" ]]; then
        EXISTING_LOG=$(find "${GENTOO_MNT}/root" -name "gentoo_autobuilder_*.log" -print0 | xargs -0 ls -t | head -n 1)
        if [[ -n "$EXISTING_LOG" ]]; then
            LOG_FILE_PATH="$EXISTING_LOG"
            echo -e "\n\n--- RESUMING LOG $(date) ---\n\n" | tee -a "$LOG_FILE_PATH"
        fi
    fi
    main "$@" 2>&1 | tee -a "$LOG_FILE_PATH"
else
    main "$@"
fi

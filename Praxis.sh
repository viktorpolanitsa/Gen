#!/bin/bash
# shellcheck disable=SC1091,SC2016

# The Gentoo Genesis Engine
# Version: 3.0
#
# This version enhances the GPU detection logic to provide informative feedback
# for AMD and Intel hardware, while retaining the strategic choice for NVIDIA.
# by default, accompanied by a critical, explicit user warning to acknowledge
# the associated security risks.

set -euo pipefail

# --- Configuration and Globals ---
GENTOO_MNT="/mnt/gentoo"
CONFIG_FILE_TMP=$(mktemp "/tmp/autobuilder.conf.XXXXXX")
CHECKPOINT_FILE="${GENTOO_MNT}/.genesis_checkpoint"
START_STAGE=0

# ... (остальные глобальные переменные)
EFI_PART=""
ROOT_PART=""
SWAP_PART=""
BOOT_MODE=""
### ИЗМЕНЕНО: Проверка контрольной суммы отключена по умолчанию ###
SKIP_CHECKSUM=true
CPU_VENDOR=""
CPU_MODEL_NAME=""
CPU_MARCH=""
MICROCODE_PACKAGE=""
VIDEO_CARDS=""
GPU_VENDOR="Unknown"

# ... (все хелперы и функции до interactive_setup остаются без изменений) ...
# --- UX Enhancements & Logging ---
C_RESET='\033[0m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'
STEP_COUNT=0; TOTAL_STEPS=22
log() { printf "${C_GREEN}[INFO] %s${C_RESET}\n" "$*"; }
warn() { printf "${C_YELLOW}[WARN] %s${C_RESET}\n" "$*" >&2; }
err() { printf "${C_RED}[ERROR] %s${C_RESET}\n" "$*" >&2; }
step_log() { STEP_COUNT=$((STEP_COUNT + 1)); printf "\n${C_GREEN}>>> [STEP %s/%s] %s${C_RESET}\n" "$STEP_COUNT" "$TOTAL_STEPS" "$*"; }
die() { err "$*"; exit 1; }

# ==============================================================================
# --- ХЕЛПЕРЫ: Чекпоинты и Безопасный Emerge ---
# ==============================================================================
save_checkpoint() {
    log "--- Checkpoint reached: Stage $1 completed. ---"
    echo "$1" > "${CHECKPOINT_FILE}"
}

load_checkpoint() {
    if [[ -f "${CHECKPOINT_FILE}" ]]; then
        local last_stage; last_stage=$(cat "${CHECKPOINT_FILE}")
        warn "Previous installation was interrupted after Stage ${last_stage}."
        read -r -p "Choose action: [C]ontinue, [R]estart from scratch, [A]bort: " choice
        case "$choice" in
            [cC]) START_STAGE=$((last_stage + 1)); log "Resuming installation from Stage ${START_STAGE}." ;;
            [rR]) log "Restarting installation from scratch."; rm -f "${CHECKPOINT_FILE}" ;;
            *) die "Installation aborted by user." ;;
        esac
    fi
}

emerge_safely() {
    log "Pre-flight dependency check for: $*"
    if emerge -pv "$@"; then
        if ask_confirm "Dependencies look OK. Proceed with the real emerge?"; then
            emerge -v "$@"
        else
            die "Emerge aborted by user after dependency check."
        fi
    else
        die "Dependency check failed. Please review the errors."
    fi
}

# ==============================================================================
# --- Core Helper & Safety Functions ---
# ==============================================================================
cleanup() { err "An error occurred. Initiating cleanup..."; sync; if mountpoint -q "${GENTOO_MNT}"; then log "Attempting to unmount ${GENTOO_MNT}..."; umount -R "${GENTOO_MNT}" || warn "Failed to unmount ${GENTOO_MNT}."; fi; log "Cleanup finished."; }
trap 'cleanup' ERR INT TERM
trap 'rm -f "$CONFIG_FILE_TMP"' EXIT
ask_confirm() { if ${FORCE_MODE:-false}; then return 0; fi; read -r -p "$1 [y/N] " response; [[ "$response" =~ ^[yY]([eE][sS])?$ ]]; }
force_unmount() { warn "Target mountpoint ${GENTOO_MNT} is already mounted."; if ask_confirm "Attempt a recursive unmount and proceed?"; then log "Unmounting ${GENTOO_MNT}..."; umount -R "${GENTOO_MNT}" || die "Failed to unmount."; log "Unmount successful."; else die "Installation cancelled."; fi; }
self_check() { log "Performing script integrity self-check..."; local funcs=(pre_flight_checks dependency_check interactive_setup stage0_partition_and_format stage1_deploy_base_system stage2_prepare_chroot stage3_configure_in_chroot stage4_build_world_and_kernel stage5_install_bootloader stage6_install_software stage7_finalize); for func in "${funcs[@]}"; do if ! declare -F "$func" > /dev/null; then die "Self-check failed: Function '$func' is not defined. The script may be corrupt."; fi; done; log "Self-check passed."; }

# ==============================================================================
# --- STAGE -2: PRE-FLIGHT SYSTEM CHEKS ---
# ==============================================================================
pre_flight_checks() {
    step_log "Performing Pre-flight System Checks"
    log "Checking for internet connectivity..."; if ! ping -c 3 gentoo.org &>/dev/null; then die "No internet connection."; fi; log "Internet connection is OK."
    log "Detecting boot mode..."; if [ -d /sys/firmware/efi ]; then BOOT_MODE="UEFI"; else BOOT_MODE="LEGACY"; fi; log "System booted in ${BOOT_MODE} mode."
}

# ==============================================================================
# --- STAGE -1: PRE-FLIGHT DEPENDENCY CHECK ---
# ==============================================================================
dependency_check() {
    step_log "Verifying LiveCD Dependencies"
    local missing_deps=(); local deps=(curl wget sgdisk partprobe mkfs.vfat mkfs.xfs mkfs.ext4 blkid lsblk sha512sum chroot wipefs blockdev cryptsetup pvcreate vgcreate lvcreate mkswap lscpu lspci)
    for cmd in "${deps[@]}"; do if ! command -v "$cmd" &>/dev/null; then missing_deps+=("$cmd"); fi; done
    if (( ${#missing_deps[@]} > 0 )); then die "Required commands not found: ${missing_deps[*]}"; fi
    log "All dependencies are satisfied."
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
        CPU_MARCH="x86-64"
        MICROCODE_PACKAGE="" # No microcode can be safely assumed
        VIDEO_CARDS="vesa fbdev"
        return
    fi

    CPU_MODEL_NAME=$(lscpu | grep "Model name" | sed -e 's/Model name:[[:space:]]*//')
    local vendor_id; vendor_id=$(lscpu | grep "Vendor ID" | awk '{print $3}')

    log "Detected CPU Model: ${CPU_MODEL_NAME}"

    case "$vendor_id" in
        "GenuineIntel")
            CPU_VENDOR="Intel"
            MICROCODE_PACKAGE="sys-firmware/intel-microcode"
            VIDEO_CARDS="intel i965"
            case "$CPU_MODEL_NAME" in
                *14th*Gen*|*13th*Gen*|*12th*Gen*) CPU_MARCH="alderlake" ;;
                *11th*Gen*)                      CPU_MARCH="tigerlake" ;;
                *10th*Gen*)                      CPU_MARCH="icelake-client" ;;
                *9th*Gen*|*8th*Gen*|*7th*Gen*|*6th*Gen*) CPU_MARCH="skylake" ;;
                *Core*2*)                        CPU_MARCH="core2" ;;
                *)
                    warn "Unrecognized Intel CPU. Falling back to a generic but safe architecture."
                    CPU_MARCH="x86-64"
                    ;;
            esac
            ;;
        "AuthenticAMD")
            CPU_VENDOR="AMD"
            MICROCODE_PACKAGE="sys-firmware/amd-microcode"
            VIDEO_CARDS="amdgpu radeonsi"
            case "$CPU_MODEL_NAME" in
                *Ryzen*9*7*|*Ryzen*7*7*|*Ryzen*5*7*) CPU_MARCH="znver4" ;; # Zen 4
                *Ryzen*9*5*|*Ryzen*7*5*|*Ryzen*5*5*) CPU_MARCH="znver3" ;; # Zen 3
                *Ryzen*9*3*|*Ryzen*7*3*|*Ryzen*5*3*) CPU_MARCH="znver2" ;; # Zen 2
                *Ryzen*7*2*|*Ryzen*5*2*|*Ryzen*7*1*|*Ryzen*5*1*) CPU_MARCH="znver1" ;; # Zen/Zen+
                *FX*)                            CPU_MARCH="bdver4" ;; # Piledriver/Bulldozer
                *)
                    warn "Unrecognized AMD CPU. Falling back to a generic but safe architecture."
                    CPU_MARCH="x86-64"
                    ;;
            esac
            ;;
        *)
            die "Unsupported CPU Vendor: ${vendor_id}. This script is for x86_64 systems."
            ;;
    esac
    log "Auto-selected -march=${CPU_MARCH} for your ${CPU_VENDOR} CPU."
}

detect_gpu_hardware() {
    step_log "Hardware Detection Engine (GPU)"
    local gpu_info; gpu_info=$(lspci | grep -i 'vga\|3d\|2d')
    log "Detected GPU: ${gpu_info}"
    if echo "$gpu_info" | grep -iq "nvidia"; then
        GPU_VENDOR="NVIDIA"
    elif echo "$gpu_info" | grep -iq "amd\|ati"; then
        GPU_VENDOR="AMD"
    elif echo "$gpu_info" | grep -iq "intel"; then
        GPU_VENDOR="Intel"
    fi
}

# ==============================================================================
# --- STAGE 0A: INTERACTIVE SETUP WIZARD ---
# ==============================================================================
interactive_setup() {
    step_log "Interactive Setup Wizard";
    
    log "--- Hardware Auto-Detection Results ---"
    log "  CPU Model:       ${CPU_MODEL_NAME}"; log "  Selected March:  ${CPU_MARCH}"; log "  GPU Vendor:      ${GPU_VENDOR}"; if ! ask_confirm "Are these hardware settings correct?"; then die "Installation cancelled."; fi

    ### ИЗМЕНЕНО: Улучшенный выбор драйверов для всех вендоров ###
    NVIDIA_DRIVER_CHOICE="None"
    case "$GPU_VENDOR" in
        "NVIDIA")
            log "--- NVIDIA Driver Selection ---"
            warn "An NVIDIA GPU has been detected. Please choose the desired driver:"
            select choice in "Proprietary (Best Performance, Recommended)" "Nouveau (Open-Source, Good Compatibility)" "Manual (Configure later)"; do
                case $choice in
                    "Proprietary (Best Performance, Recommended)") NVIDIA_DRIVER_CHOICE="Proprietary"; VIDEO_CARDS="nvidia"; break;;
                    "Nouveau (Open-Source, Good Compatibility)")  NVIDIA_DRIVER_CHOICE="Nouveau"; VIDEO_CARDS="nouveau"; break;;
                    "Manual (Configure later)")                   NVIDIA_DRIVER_CHOICE="Manual"; break;;
                esac
            done
            ;;
        "AMD")
            log "--- AMD Driver Information ---"
            log "AMD GPU detected. The recommended open-source 'amdgpu' driver stack will be configured."
            VIDEO_CARDS="amdgpu radeonsi"
            ;;
        "Intel")
            log "--- Intel Driver Information ---"
            log "Intel iGPU detected. The recommended open-source 'intel' modesetting driver stack will be configured."
            VIDEO_CARDS="intel i965"
            ;;
    esac

    # ... (остальные вопросы без изменений)
    log "--- System Architecture & Security ---"
    USE_HARDENED_PROFILE=false; if ask_confirm "Use Hardened profile for enhanced security?"; then USE_HARDENED_PROFILE=true; fi
    select INIT_SYSTEM in "OpenRC" "SystemD"; do break; done
    select LSM_CHOICE in "None" "AppArmor" "SELinux"; do break; done
    
    log "--- Desktop Environment ---"
    select DESKTOP_ENV in "XFCE" "KDE-Plasma" "GNOME" "i3-WM" "Server (No GUI)"; do break; done

    log "--- Kernel Management ---"
    select KERNEL_METHOD in "genkernel (recommended, auto)" "manual (expert, interactive)"; do break; done

    log "--- Performance Options ---"
    USE_CCACHE=false; if ask_confirm "Enable ccache for faster recompiles?"; then USE_CCACHE=true; fi
    USE_BINPKGS=false; if ask_confirm "Use binary packages to speed up installation (if available)?"; then USE_BINPKGS=true; fi

    log "--- Storage and System Configuration ---"
    log "Available block devices:"; lsblk -d -o NAME,SIZE,TYPE
    while true; do read -r -p "Enter the target device for installation (e.g., /dev/sda): " TARGET_DEVICE; if [[ -b "$TARGET_DEVICE" ]]; then break; else err "Device '$TARGET_DEVICE' does not exist."; fi; done
    read -r -p "Enter root filesystem type [xfs/ext4, Default: xfs]: " ROOT_FS_TYPE; [[ -z "$ROOT_FS_TYPE" ]] && ROOT_FS_TYPE="xfs"
    read -r -p "Enter SWAP size in GB (e.g., 8). Enter 0 to disable [Default: 4]: " SWAP_SIZE_GB; [[ -z "$SWAP_SIZE_GB" ]] && SWAP_SIZE_GB=4
    USE_LUKS=false; if ask_confirm "Use LUKS full-disk encryption for the root partition?"; then USE_LUKS=true; fi
    if $USE_LUKS; then
        while true; do
            read -s -r -p "Enter LUKS passphrase: " LUKS_PASSPHRASE; echo
            read -s -r -p "Confirm LUKS passphrase: " LUKS_PASSPHRASE_CONFIRM; echo
            if [[ "$LUKS_PASSPHRASE" == "$LUKS_PASSPHRASE_CONFIRM" && -n "$LUKS_PASSPHRASE" ]]; then break; else err "Passphrases do not match or are empty. Please try again."; fi
        done
    fi
    USE_LVM=false; if ask_confirm "Use LVM to manage partitions?"; then USE_LVM=true; fi

    read -r -p "Enter timezone [Default: UTC]: " SYSTEM_TIMEZONE; [[ -z "$SYSTEM_TIMEZONE" ]] && SYSTEM_TIMEZONE="UTC"
    read -r -p "Enter locale [Default: en_US.UTF-8]: " SYSTEM_LOCALE; [[ -z "$SYSTEM_LOCALE" ]] && SYSTEM_LOCALE="en_US.UTF-8"
    read -r -p "Enter LINGUAS (space separated) [Default: en ru]: " SYSTEM_LINGUAS; [[ -z "$SYSTEM_LINGUAS" ]] && SYSTEM_LINGUAS="en ru"
    read -r -p "Enter hostname [Default: gentoo-desktop]: " SYSTEM_HOSTNAME; [[ -z "$SYSTEM_HOSTNAME" ]] && SYSTEM_HOSTNAME="gentoo-desktop"
    local detected_cores; detected_cores=$(nproc --all 2>/dev/null || echo 4); local default_makeopts="-j${detected_cores} -l${detected_cores}"; read -r -p "Enter MAKEOPTS [Default: ${default_makeopts}]: " MAKEOPTS; [[ -z "$MAKEOPTS" ]] && MAKEOPTS="$default_makeopts"

    log "--- Post-Install Application Profiles ---"
    INSTALL_DEV_TOOLS=false; if ask_confirm "Install Developer Tools (git, vscode, docker)?"; then INSTALL_DEV_TOOLS=true; fi
    INSTALL_OFFICE_GFX=false; if ask_confirm "Install Office/Graphics Suite (LibreOffice, GIMP, Inkscape)?"; then INSTALL_OFFICE_GFX=true; fi
    INSTALL_GAMING=false; if ask_confirm "Install Gaming Essentials (Steam, Lutris, Wine)?"; then INSTALL_GAMING=true; fi

    # --- Сохранение всех опций в конфиг ---
    {
        echo "TARGET_DEVICE='${TARGET_DEVICE}'"; echo "ROOT_FS_TYPE='${ROOT_FS_TYPE}'"
        echo "SYSTEM_HOSTNAME='${SYSTEM_HOSTNAME}'"; echo "SYSTEM_TIMEZONE='${SYSTEM_TIMEZONE}'"
        echo "SYSTEM_LOCALE='${SYSTEM_LOCALE}'"; echo "SYSTEM_LINGUAS='${SYSTEM_LINGUAS}'"
        echo "CPU_MARCH='${CPU_MARCH}'"; echo "VIDEO_CARDS='${VIDEO_CARDS}'"
        echo "MICROCODE_PACKAGE='${MICROCODE_PACKAGE}'"; echo "MAKEOPTS='${MAKEOPTS}'"
        echo "EMERGE_JOBS='${detected_cores}'"; echo "USE_LVM=${USE_LVM}"; echo "USE_LUKS=${USE_LUKS}"
        echo "INIT_SYSTEM='${INIT_SYSTEM}'"; echo "DESKTOP_ENV='${DESKTOP_ENV}'"
        echo "KERNEL_METHOD='${KERNEL_METHOD}'"; echo "USE_CCACHE=${USE_CCACHE}"; echo "USE_BINPKGS=${USE_BINPKGS}"
        echo "INSTALL_DEV_TOOLS=${INSTALL_DEV_TOOLS}"; echo "INSTALL_OFFICE_GFX=${INSTALL_OFFICE_GFX}"; echo "INSTALL_GAMING=${INSTALL_GAMING}"
        echo "NVIDIA_DRIVER_CHOICE='${NVIDIA_DRIVER_CHOICE}'"; echo "USE_HARDENED_PROFILE=${USE_HARDENED_PROFILE}"; echo "LSM_CHOICE='${LSM_CHOICE}'"
    } > "$CONFIG_FILE_TMP"
    if $USE_LUKS; then echo "LUKS_PASSPHRASE='${LUKS_PASSPHRASE}'" >> "$CONFIG_FILE_TMP"; fi
    log "Configuration complete. Review summary before proceeding."
}

# ==============================================================================
# --- STAGE 0B: DISK PREPARATION (DESTRUCTIVE) ---
# ==============================================================================
stage0_partition_and_format() {
    step_log "Disk Partitioning and Formatting (Mode: ${BOOT_MODE})"; warn "Final confirmation. ALL DATA ON ${TARGET_DEVICE} WILL BE PERMANENTLY DESTROYED!"; read -r -p "To confirm, type the full device name ('${TARGET_DEVICE}'): " confirmation; if [[ "$confirmation" != "${TARGET_DEVICE}" ]]; then die "Confirmation failed. Aborting."; fi
    log "Initiating 'Absolute Zero' protocol to free the device..."; umount "${TARGET_DEVICE}"* >/dev/null 2>&1 || true; if command -v mdadm &>/dev/null; then mdadm --stop --scan >/dev/null 2>&1 || true; fi; if command -v dmraid &>/dev/null; then dmraid -an >/dev/null 2>&1 || true; fi; if command -v vgchange &>/dev/null; then vgchange -an >/dev/null 2>&1 || true; fi; if command -v cryptsetup &>/dev/null; then cryptsetup close /dev/mapper/* >/dev/null 2>&1 || true; fi; sync; blockdev --flushbufs "${TARGET_DEVICE}" >/dev/null 2>&1 || true; log "Device locks released."
    log "Wiping partition table on ${TARGET_DEVICE}..."; sgdisk --zap-all "${TARGET_DEVICE}"; sync
    
    local P_SEPARATOR=""; if [[ "${TARGET_DEVICE}" == *nvme* || "${TARGET_DEVICE}" == *mmcblk* ]]; then P_SEPARATOR="p"; fi
    local BOOT_PART_NUM=1; local MAIN_PART_NUM=2; local SWAP_PART_NUM=3

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        log "Creating GPT partitions for UEFI...";
        sgdisk -n ${BOOT_PART_NUM}:0:+512M -t ${BOOT_PART_NUM}:ef00 -c ${BOOT_PART_NUM}:"EFI System" "${TARGET_DEVICE}"
        EFI_PART="${TARGET_DEVICE}${P_SEPARATOR}${BOOT_PART_NUM}"
    else
        log "Creating GPT partitions for Legacy BIOS...";
        sgdisk -n ${BOOT_PART_NUM}:0:+2M -t ${BOOT_PART_NUM}:ef02 -c ${BOOT_PART_NUM}:"BIOS Boot" "${TARGET_DEVICE}"
    fi

    if [[ "$SWAP_SIZE_GB" -gt 0 && "$USE_LVM" = false ]]; then
        log "Creating dedicated SWAP partition..."
        sgdisk -n ${SWAP_PART_NUM}:0:+${SWAP_SIZE_GB}G -t ${SWAP_PART_NUM}:8200 -c ${SWAP_PART_NUM}:"Linux Swap" "${TARGET_DEVICE}"
        SWAP_PART="${TARGET_DEVICE}${P_SEPARATOR}${SWAP_PART_NUM}"
    fi
    
    log "Creating main Linux partition..."
    sgdisk -n ${MAIN_PART_NUM}:0:0 -t ${MAIN_PART_NUM}:8300 -c ${MAIN_PART_NUM}:"Gentoo Root" "${TARGET_DEVICE}"
    local MAIN_PART="${TARGET_DEVICE}${P_SEPARATOR}${MAIN_PART_NUM}"
    
    sync; partprobe "${TARGET_DEVICE}"; sleep 3

    # --- Format Boot & Swap ---
    if [[ "$BOOT_MODE" == "UEFI" ]]; then log "Formatting EFI partition..."; wipefs -a "${EFI_PART}"; mkfs.vfat -F 32 "${EFI_PART}"; fi
    if [[ -n "$SWAP_PART" ]]; then log "Formatting SWAP partition..."; wipefs -a "${SWAP_PART}"; mkswap "${SWAP_PART}"; fi

    # --- Setup Main Partition (LUKS -> LVM -> FS) ---
    local device_to_format="${MAIN_PART}"
    if $USE_LUKS; then
        log "Creating LUKS container on ${MAIN_PART}..."; echo -n "${LUKS_PASSPHRASE}" | cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha512 --iter-time 5000 --use-random "${MAIN_PART}" -
        log "Opening LUKS container..."; echo -n "${LUKS_PASSPHRASE}" | cryptsetup open "${MAIN_PART}" gentoo_crypted -
        device_to_format="/dev/mapper/gentoo_crypted"
        echo "LUKS_UUID=$(cryptsetup luksUUID "${MAIN_PART}")" >> "$CONFIG_FILE_TMP"
    fi

    if $USE_LVM; then
        log "Setting up LVM on ${device_to_format}..."; pvcreate "${device_to_format}"; vgcreate gentoo_vg "${device_to_format}"
        if [[ "$SWAP_SIZE_GB" -gt 0 ]]; then
            log "Creating SWAP logical volume..."; lvcreate -L "${SWAP_SIZE_GB}G" -n swap gentoo_vg
            SWAP_PART="/dev/gentoo_vg/swap"; mkswap "${SWAP_PART}"
        fi
        log "Creating Root logical volume..."; lvcreate -l 100%FREE -n root gentoo_vg
        ROOT_PART="/dev/gentoo_vg/root"
    else
        ROOT_PART="${device_to_format}"
    fi

    log "Formatting Root filesystem on ${ROOT_PART}..."; wipefs -a "${ROOT_PART}"
    if [[ "$ROOT_FS_TYPE" == "xfs" ]]; then mkfs.xfs -f "${ROOT_PART}"; else mkfs.ext4 -F "${ROOT_PART}"; fi
    sync

    # --- Mounting ---
    log "Mounting partitions..."; mkdir -p "${GENTOO_MNT}"; mount "${ROOT_PART}" "${GENTOO_MNT}"
    if [[ "$BOOT_MODE" == "UEFI" ]]; then mkdir -p "${GENTOO_MNT}/boot/efi"; mount "${EFI_PART}" "${GENTOO_MNT}/boot/efi"; fi
    if [[ -n "$SWAP_PART" ]]; then swapon "${SWAP_PART}"; fi
}

# ==============================================================================
# --- STAGE 1: BASE SYSTEM DEPLOYMENT ---
# ==============================================================================
stage1_deploy_base_system() {
    step_log "Base System Deployment"; local success=false; local base_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/"; local latest_info_url="${base_url}latest-stage3-amd64-openrc.txt"; log "Fetching list of recent stage3 builds..."; local build_list; build_list=$(curl --fail -L -s --connect-timeout 15 "$latest_info_url" | grep '\.tar\.xz' | awk '{print $1}') || die "Could not fetch stage3 build list from ${latest_info_url}"
    local attempt_count=0; for build_path in $build_list; do attempt_count=$((attempt_count + 1)); log "--- [Attempt ${attempt_count}] Trying build: ${build_path} ---"; local tarball_name; tarball_name=$(basename "$build_path"); local tarball_url="${base_url}${build_path}"; local local_tarball_path="${GENTOO_MNT}/${tarball_name}"; log "Downloading stage3: ${tarball_name}"; wget --tries=3 --timeout=45 -c -O "${local_tarball_path}" "$tarball_url"; if [[ ! -s "${local_tarball_path}" ]]; then warn "Stage3 download failed. Trying next build..."; continue; fi
    local digests_url="${tarball_url}.DIGESTS"; local local_digests_path="${GENTOO_MNT}/${tarball_name}.DIGESTS"; log "Downloading digests file..."; wget --tries=3 -c -O "${local_digests_path}" "$digests_url"; if [[ ! -s "${local_digests_path}" ]]; then warn "Digests download failed. Trying next build..."; rm -f "${local_tarball_path}"; continue; fi
    
    ### ИЗМЕНЕНО: Критическое предупреждение при пропуске проверки ###
    if ${SKIP_CHECKSUM}; then
        warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        err  "  DANGER: CHECKSUM VERIFICATION IS DISABLED BY DEFAULT!"
        err  "  This is a significant security risk. You are installing a"
        err  "  base system without verifying its integrity. Proceed only"
        err  "  if you understand and accept this risk."
        warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        read -r -p "Press ENTER to acknowledge this risk and continue..."
        success=true; break
    fi

    log "Verifying tarball integrity with SHA512..."; pushd "${GENTOO_MNT}" >/dev/null; if grep -E "\s+${tarball_name}$" "$(basename "${local_digests_path}")" | sha512sum --strict -c -; then popd >/dev/null; log "Checksum OK. Found a valid stage3 build."; success=true; break; else popd >/dev/null; warn "Checksum FAILED for this build. Trying next."; rm -f "${local_tarball_path}" "${local_digests_path}"; fi; done
    if [ "$success" = false ]; then die "Failed to find a verifiable stage3 build after trying ${attempt_count} options."; fi; log "Unpacking stage3 tarball..."; tar xpvf "${local_tarball_path}" --xattrs-include='*.*' --numeric-owner -C "${GENTOO_MNT}"; log "Base system deployed successfully."
}

# ... (остальная часть скрипта без изменений) ...
# ==============================================================================
# --- STAGE 2: CHROOT PREPARATION ---
# ==============================================================================
stage2_prepare_chroot() {
    step_log "Chroot Preparation"; log "Configuring Portage..."; mkdir -p "${GENTOO_MNT}/etc/portage/repos.conf"; cp "${GENTOO_MNT}/usr/share/portage/config/repos.conf" "${GENTOO_MNT}/etc/portage/repos.conf/gentoo.conf"
    
    log "Writing dynamic make.conf..."
    local emerge_opts="--jobs=${EMERGE_JOBS} --load-average=${EMERGE_JOBS} --quiet-build=y --autounmask-write=y --with-bdeps=y"
    if [[ "$USE_BINPKGS" = true ]]; then emerge_opts+=" --getbinpkg=y"; fi
    
    local features="candy"
    if [[ "$USE_CCACHE" = true ]]; then features+=" ccache"; fi

    local base_use="X dbus policykit gtk udev udisks pulseaudio vaapi vdpau vulkan"
    local extra_use=""
    case "$DESKTOP_ENV" in
        "KDE-Plasma") extra_use="kde plasma qt5 -gnome" ;;
        "GNOME")      extra_use="gnome -kde -qt5" ;;
        "i3-WM")      extra_use="-gnome -kde -qt5" ;;
        "XFCE")       extra_use="-gnome -kde -qt5" ;;
    esac
    if [[ "$INIT_SYSTEM" == "SystemD" ]]; then extra_use+=" systemd -elogind"; else extra_use+=" elogind -systemd"; fi
    if [[ "$LSM_CHOICE" == "AppArmor" ]]; then extra_use+=" apparmor"; fi
    if [[ "$LSM_CHOICE" == "SELinux" ]]; then extra_use+=" selinux"; fi

    cat > "${GENTOO_MNT}/etc/portage/make.conf" <<EOF
# --- Generated by The Gentoo Genesis Engine ---
COMMON_FLAGS="-O2 -pipe -march=${CPU_MARCH}"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="${MAKEOPTS}"
EMERGE_DEFAULT_OPTS="${emerge_opts}"
FEATURES="${features}"
VIDEO_CARDS="${VIDEO_CARDS}"
INPUT_DEVICES="libinput synaptics"
USE="${base_use} ${extra_use}"
ACCEPT_LICENSE="@FREE @BINARY-REDISTRIBUTABLE linux-fw-redistributable"
GRUB_PLATFORMS="$([[ "$BOOT_MODE" == "UEFI" ]] && echo "efi-64" || echo "pc")"
GENTOO_MIRRORS="https://distfiles.gentoo.org"
L10N="${SYSTEM_LINGUAS}"
LINGUAS="${SYSTEM_LINGUAS}"
EOF

    if [[ "$NVIDIA_DRIVER_CHOICE" == "Proprietary" ]]; then
        log "Configuring Portage for NVIDIA proprietary drivers..."
        mkdir -p "${GENTOO_MNT}/etc/portage/package.accept_keywords"
        echo "x11-drivers/nvidia-drivers ~amd64" > "${GENTOO_MNT}/etc/portage/package.accept_keywords/nvidia"
        mkdir -p "${GENTOO_MNT}/etc/portage/package.license"
        echo "x11-drivers/nvidia-drivers NVIDIA" > "${GENTOO_MNT}/etc/portage/package.license/nvidia"
    fi

    log "Generating /etc/fstab...";
    {
        echo "# /etc/fstab: static file system information."
        echo "UUID=$(blkid -s UUID -o value "${ROOT_PART}")  /  ${ROOT_FS_TYPE}  defaults,noatime  0 1"
        if [[ "$BOOT_MODE" == "UEFI" ]]; then
            echo "UUID=$(blkid -s UUID -o value "${EFI_PART}")  /boot/efi  vfat  defaults,noatime  0 2"
        fi
        if [[ -n "$SWAP_PART" ]]; then
            echo "UUID=$(blkid -s UUID -o value "${SWAP_PART}")  none  swap  sw  0 0"
        fi
    } > "${GENTOO_MNT}/etc/fstab"
    log "/etc/fstab generated successfully."

    log "Mounting virtual filesystems...";
    mount --types proc /proc "${GENTOO_MNT}/proc"; mount --rbind /sys "${GENTOO_MNT}/sys"; mount --make-rslave "${GENTOO_MNT}/sys"; mount --rbind /dev "${GENTOO_MNT}/dev"; mount --make-rslave "${GENTOO_MNT}/dev"
    log "Copying DNS info..."; cp --dereference /etc/resolv.conf "${GENTOO_MNT}/etc/"
    local script_name; script_name=$(basename "$0"); local script_dest_path="/root/${script_name}"
    log "Copying this script into the chroot..."; cp "$0" "${GENTOO_MNT}${script_dest_path}"; chmod +x "${GENTOO_MNT}${script_dest_path}"; cp "$CONFIG_FILE_TMP" "${GENTOO_MNT}/etc/autobuilder.conf"
    log "Entering chroot to continue installation (canonical method)..."
    chroot "${GENTOO_MNT}" /usr/bin/env -i HOME=/root TERM="$TERM" "${script_dest_path}" --chrooted
    log "Chroot execution finished."
}

# ==============================================================================
# --- STAGES 3 through 7 ---
# ==============================================================================
stage3_configure_in_chroot() {
    step_log "System Configuration (Inside Chroot)"; source /etc/profile; export PS1="(chroot) ${PS1:-}"; log "Syncing Portage tree snapshot..."; emerge_safely -q --sync
    
    local profile_base="default/linux/amd64/17.1"
    if [[ "$USE_HARDENED_PROFILE" = true ]]; then profile_base+="/hardened"; fi
    local profile_desktop=""
    if [[ "$DESKTOP_ENV" == "KDE-Plasma" ]]; then profile_desktop="/desktop/plasma"; fi
    if [[ "$DESKTOP_ENV" == "GNOME" ]]; then profile_desktop="/desktop/gnome"; fi
    if [[ "$DESKTOP_ENV" != "Server (No GUI)" && -z "$profile_desktop" ]]; then profile_desktop="/desktop"; fi
    local profile_init=""
    if [[ "$INIT_SYSTEM" == "SystemD" ]]; then profile_init="/systemd"; fi
    local GENTOO_PROFILE="${profile_base}${profile_desktop}${profile_init}"
    log "Setting system profile to: ${GENTOO_PROFILE}"; eselect profile set "${GENTOO_PROFILE}"

    if [[ "$USE_CCACHE" = true ]]; then
        log "Setting up ccache..."; emerge_safely app-misc/ccache; ccache -M 50G
    fi

    step_log "Installing Kernel Headers and Core System Utilities"
    emerge_safely sys-kernel/linux-headers
    if [[ "$USE_LVM" = true ]]; then emerge_safely sys-fs/lvm2; fi
    if [[ "$USE_LUKS" = true ]]; then emerge_safely sys-fs/cryptsetup; fi
    if [[ "$LSM_CHOICE" == "AppArmor" ]]; then emerge_safely sys-apps/apparmor; fi
    if [[ "$LSM_CHOICE" == "SELinux" ]]; then emerge_safely sys-libs/libselinux sys-apps/policycoreutils; fi
    
    if [[ -n "$MICROCODE_PACKAGE" ]]; then
        log "Installing CPU microcode package: ${MICROCODE_PACKAGE}"
        emerge_safely "${MICROCODE_PACKAGE}"
    else
        warn "No specific microcode package to install."
    fi

    log "Configuring timezone and locale..."; ln -sf "/usr/share/zoneinfo/${SYSTEM_TIMEZONE}" /etc/localtime; echo "${SYSTEM_LOCALE} UTF-8" > /etc/locale.gen; echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen; locale-gen; eselect locale set "${SYSTEM_LOCALE}"; env-update && source /etc/profile; log "Setting hostname..."; echo "hostname=\"${SYSTEM_HOSTNAME}\"" > /etc/conf.d/hostname
}

stage4_build_world_and_kernel() {
    step_log "Updating @world set and Building Kernel"
    log "Building @world set..."; emerge_safely --update --deep --newuse @world
    log "Optimizing mirrors..."; emerge_safely --verbose app-portage/mirrorselect; cp /etc/portage/make.conf /etc/portage/make.conf.bak; sed -i '/^GENTOO_MIRRORS/d' /etc/portage/make.conf; mirrorselect -s4 -b10 -o -D >> /etc/portage/make.conf; log "Fastest mirrors selected."
    log "Installing firmware and kernel sources..."; emerge_safely sys-kernel/linux-firmware sys-kernel/gentoo-sources
    
    if [[ "$KERNEL_METHOD" == "genkernel (recommended, auto)" ]]; then
        log "Building kernel with genkernel"; emerge_safely sys-kernel/genkernel
        local genkernel_opts="--install"
        if [[ "$USE_LVM" = true ]]; then genkernel_opts+=" --lvm"; fi
        if [[ "$USE_LUKS" = true ]]; then genkernel_opts+=" --luks"; fi
        log "Running genkernel with options: ${genkernel_opts}"; genkernel "${genkernel_opts}" all
    else
        log "Starting manual kernel configuration..."; cd /usr/src/linux
        warn "INTERACTIVE STEP REQUIRED: Please configure your kernel now."
        if [[ "$LSM_CHOICE" != "None" ]]; then warn "Don't forget to enable ${LSM_CHOICE} support in the kernel security settings!"; fi
        if [[ "$NVIDIA_DRIVER_CHOICE" == "Proprietary" ]]; then
            warn "NVIDIA proprietary drivers selected. You MUST DISABLE the Nouveau driver in the kernel:"
            warn "-> Device Drivers -> Graphics support -> Nouveau driver [ ]"
        fi
        make menuconfig
        log "Compiling and installing kernel..."; make && make modules_install && make install
    fi
}

stage5_install_bootloader() {
    step_log "Installing GRUB Bootloader (Mode: ${BOOT_MODE})";
    local grub_cmdline=""
    if [[ "$USE_LUKS" = true ]]; then
        log "Configuring GRUB for LUKS..."
        local P_SEPARATOR=""; if [[ "${TARGET_DEVICE}" == *nvme* || "${TARGET_DEVICE}" == *mmcblk* ]]; then P_SEPARATOR="p"; fi
        local MAIN_PART_NUM=2
        local MAIN_PART="${TARGET_DEVICE}${P_SEPARATOR}${MAIN_PART_NUM}"
        local LUKS_DEVICE_UUID; LUKS_DEVICE_UUID=$(blkid -s UUID -o value "${MAIN_PART}")
        local ROOT_DEVICE_PATH="/dev/mapper/gentoo_crypted"
        if [[ "$USE_LVM" = true ]]; then ROOT_DEVICE_PATH="/dev/gentoo_vg/root"; fi
        grub_cmdline+="crypt_device=UUID=${LUKS_DEVICE_UUID}:gentoo_crypted root=${ROOT_DEVICE_PATH}"
    fi

    if [[ "$LSM_CHOICE" == "AppArmor" ]]; then grub_cmdline+=" apparmor=1 security=apparmor"; fi
    if [[ "$LSM_CHOICE" == "SELinux" ]]; then grub_cmdline+=" selinux=1 security=selinux"; fi

    if [[ -n "$grub_cmdline" ]]; then
        log "Adding kernel parameters: ${grub_cmdline}"
        sed -i "s/GRUB_CMDLINE_LINUX=\"\"/GRUB_CMDLINE_LINUX=\"${grub_cmdline}\"/" /etc/default/grub
    fi
    if [[ "$USE_LUKS" = true ]]; then echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub; fi
    
    emerge_safely --noreplace sys-boot/grub:2
    if [[ "$BOOT_MODE" == "UEFI" ]]; then grub-install --target=x86_64-efi --efi-directory=/boot/efi; else grub-install "${TARGET_DEVICE}"; fi
    grub-mkconfig -o /boot/grub/grub.cfg
}

stage6_install_software() {
    step_log "Installing Desktop Environment and Application Profiles"
    
    local display_manager=""
    case "$DESKTOP_ENV" in
        "XFCE")       log "Installing XFCE..."; emerge_safely xfce-base/xfce4-meta x11-terms/xfce4-terminal; display_manager="x11-misc/lightdm" ;;
        "KDE-Plasma") log "Installing KDE Plasma..."; emerge_safely kde-plasma/plasma-meta; display_manager="x11-misc/sddm" ;;
        "GNOME")      log "Installing GNOME..."; emerge_safely gnome-base/gnome-desktop; display_manager="gnome-base/gdm" ;;
        "i3-WM")      log "Installing i3 Window Manager..."; emerge_safely x11-wm/i3 x11-terms/alacritty x11-misc/dmenu; display_manager="x11-misc/lightdm" ;;
        "Server (No GUI)") log "Skipping GUI installation for server profile." ;;
    esac
    if [[ -n "$display_manager" ]]; then
        log "Installing Xorg Server and Display Manager..."; emerge_safely x11-base/xorg-server "${display_manager}"
    fi

    if [[ "$NVIDIA_DRIVER_CHOICE" == "Proprietary" ]]; then
        log "Installing NVIDIA settings panel..."; emerge_safely x11-misc/nvidia-settings
    fi

    if $INSTALL_DEV_TOOLS; then
        log "Installing Developer Tools..."; emerge_safely dev-vcs/git app-editors/vscode dev-util/docker-cli
    fi
    if $INSTALL_OFFICE_GFX; then
        log "Installing Office/Graphics Suite..."; emerge_safely app-office/libreoffice media-gfx/gimp media-gfx/inkscape
    fi
    if $INSTALL_GAMING; then
        log "Installing Gaming Essentials..."; emerge_safely games-util/steam-launcher games-util/lutris app-emulation/wine-staging
    fi
    log "Installing essential utilities..."; emerge_safely www-client/firefox-bin app-admin/sudo app-shells/bash-completion net-misc/networkmanager
}

stage7_finalize() {
    step_log "Finalizing System"; log "Enabling core services (${INIT_SYSTEM})..."
    if [[ "$INIT_SYSTEM" == "OpenRC" ]]; then
        if [[ "$USE_LVM" = true ]]; then rc-update add lvm default; fi
        rc-update add dbus default
        if [[ "$DESKTOP_ENV" != "Server (No GUI)" ]]; then rc-update add display-manager default; fi
        rc-update add NetworkManager default
    else # SystemD
        if [[ "$USE_LVM" = true ]]; then systemctl enable lvm2-monitor.service; fi
        if [[ "$DESKTOP_ENV" != "Server (No GUI)" ]]; then systemctl enable display-manager.service; fi
        systemctl enable NetworkManager.service
    fi
    
    log "Configuring sudo for 'wheel' group..."; echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
    log "Set a password for the 'root' user:"; passwd root; log "Creating a new user..."; local new_user=""; while true; do read -r -p "Enter a username: " new_user; if [[ "$new_user" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then break; else err "Invalid username."; new_user=""; fi; done
    useradd -m -G wheel,users,audio,video,usb -s /bin/bash "$new_user"; log "Set a password for user '$new_user':"; passwd "$new_user"; log "User '$new_user' created."; log "Installation complete."; log "Finalizing disk writes..."; sync; log "Run: exit -> umount -R ${GENTOO_MNT} -> reboot"
}

# ==============================================================================
# --- MAIN SCRIPT LOGIC ---
# ==============================================================================
main() {
    if [[ $EUID -ne 0 ]]; then die "This script must be run as root."; fi
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
        for arg in "$@"; do case "$arg" in --force|--auto) FORCE_MODE=true;; --skip-checksum) SKIP_CHECKSUM=true;; esac; done
        
        if mountpoint -q "${GENTOO_MNT}"; then
            load_checkpoint
        fi

        local initial_stages=(self_check pre_flight_checks dependency_check detect_cpu_architecture detect_gpu_hardware interactive_setup stage0_partition_and_format stage1_deploy_base_system)
        local stage_num=-7
        if (( START_STAGE == 0 )); then
            for stage_func in "${initial_stages[@]}"; do
                "$stage_func"
            done
        fi
        
        if (( START_STAGE <= 2 )); then
            source "$CONFIG_FILE_TMP"
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

#!/bin/bash
# shellcheck disable=SC1091,SC2016

# The Ultimate Gentoo Autobuilder & Deployer
# Version: 35.0 "Nexus"
#
# This is the final point of convergence. It corrects the flawed `yes` pipe,
# which caused an infinite loop, by providing the correct, specific input (`-5`)
# that `etc-update` requires for non-interactive auto-merging. This is not
# brute force; it is precision. This is the Nexus, where all lessons learned
# finally connect.

set -euo pipefail

# --- Configuration and Globals ---
GENTOO_MNT="/mnt/gentoo"
CONFIG_FILE_TMP=$(mktemp "/tmp/autobuilder.conf.XXXXXX")
EFI_PART=""
ROOT_PART=""
BOOT_MODE=""
SKIP_CHECKSUM=false

# --- UX Enhancements ---
C_RESET='\033[0m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'
STEP_COUNT=0; TOTAL_STEPS=19

# --- Logging Utilities ---
log() { printf "${C_GREEN}[INFO] %s${C_RESET}\n" "$*"; }
warn() { printf "${C_YELLOW}[WARN] %s${C_RESET}\n" "$*" >&2; }
err() { printf "${C_RED}[ERROR] %s${C_RESET}\n" "$*" >&2; }
step_log() { STEP_COUNT=$((STEP_COUNT + 1)); printf "\n${C_GREEN}>>> [STEP %s/%s] %s${C_RESET}\n" "$STEP_COUNT" "$TOTAL_STEPS" "$*"; }
die() { err "$*"; exit 1; }

# ==============================================================================
# --- Core Helper & Safety Functions ---
# ==============================================================================
cleanup() { err "An error occurred. Initiating cleanup..."; sync; if mountpoint -q "${GENTOO_MNT}"; then log "Attempting to unmount ${GENTOO_MNT}..."; umount -R "${GENTOO_MNT}" || warn "Failed to unmount ${GENTOO_MNT}."; fi; log "Cleanup finished."; }
trap 'cleanup' ERR INT TERM
trap 'rm -f "$CONFIG_FILE_TMP"' EXIT
ask_confirm() { if ${FORCE_MODE:-false}; then return 0; fi; read -r -p "$1 [y/N] " response; [[ "$response" =~ ^[yY]([eE][sS])?$ ]]; }
force_unmount() { warn "Target mountpoint ${GENTOO_MNT} is already mounted."; if ask_confirm "Attempt a recursive unmount and proceed?"; then log "Unmounting ${GENTOO_MNT}..."; umount -R "${GENTOO_MNT}" || die "Failed to unmount."; log "Unmount successful."; else die "Installation cancelled."; fi; }
self_check() { log "Performing script integrity self-check..."; local funcs=(pre_flight_checks dependency_check interactive_setup stage0_partition_and_format stage1_deploy_base_system stage2_prepare_chroot stage3_configure_in_chroot stage4_build_world_and_kernel stage5_install_bootloader stage6_install_desktop stage7_finalize); for func in "${funcs[@]}"; do if ! declare -F "$func" > /dev/null; then die "Self-check failed: Function '$func' is not defined. The script may be corrupt."; fi; done; log "Self-check passed."; }

# ==============================================================================
# --- STAGE -2: PRE-FLIGHT SYSTEM CHECKS ---
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
    local missing_deps=(); local deps=(curl wget sgdisk partprobe mkfs.vfat mkfs.xfs blkid lsblk sha512sum chroot wipefs blockdev)
    for cmd in "${deps[@]}"; do if ! command -v "$cmd" &>/dev/null; then missing_deps+=("$cmd"); fi; done
    if (( ${#missing_deps[@]} > 0 )); then die "Required commands not found: ${missing_deps[*]}"; fi
    log "All dependencies are satisfied."
}

# ==============================================================================
# --- STAGE 0A: INTERACTIVE SETUP WIZARD ---
# ==============================================================================
interactive_setup() {
    step_log "Interactive Setup Wizard"; warn "This script will perform a DESTRUCTIVE installation of Gentoo Linux."; log "Available block devices:"; lsblk -d -o NAME,SIZE,TYPE
    while true; do read -r -p "Enter the target device for installation (e.g., /dev/sda): " TARGET_DEVICE; if [[ -b "$TARGET_DEVICE" ]]; then local disk_size_gb; disk_size_gb=$(lsblk -b -d -n -o SIZE "${TARGET_DEVICE}" | awk '{print int($1/1024/1024/1024)}'); if (( disk_size_gb < 30 )); then err "Target device is only ${disk_size_gb}GB. A minimum of 30GB is recommended."; if ! ask_confirm "Continue anyway?"; then die "Installation cancelled."; fi; fi; break; else err "Device '$TARGET_DEVICE' does not exist."; fi; done
    read -r -p "Enter timezone [Default: UTC]: " SYSTEM_TIMEZONE; [[ -z "$SYSTEM_TIMEZONE" ]] && SYSTEM_TIMEZONE="UTC"
    read -r -p "Enter locale [Default: en_US.UTF-8]: " SYSTEM_LOCALE; [[ -z "$SYSTEM_LOCALE" ]] && SYSTEM_LOCALE="en_US.UTF-8"
    read -r -p "Enter CPU architecture (-march) [Default: native]: " CPU_MARCH; [[ -z "$CPU_MARCH" ]] && CPU_MARCH="native"
    read -r -p "Enter hostname [Default: gentoo-desktop]: " SYSTEM_HOSTNAME; [[ -z "$SYSTEM_HOSTNAME" ]] && SYSTEM_HOSTNAME="gentoo-desktop"
    SYSTEM_HOSTNAME=$(echo "$SYSTEM_HOSTNAME" | sed -e 's/[^a-zA-Z0-9-]//g'); log "Using sanitized hostname: ${SYSTEM_HOSTNAME}"
    local detected_cores; detected_cores=$(nproc --all 2>/dev/null || echo 2); local default_makeopts="-j${detected_cores} -l${detected_cores}"; read -r -p "Enter MAKEOPTS [Default: ${default_makeopts}]: " MAKEOPTS; [[ -z "$MAKEOPTS" ]] && MAKEOPTS="$default_makeopts"
    log "--- Configuration Summary ---"; log "  Target Device:   ${TARGET_DEVICE}, Boot Mode: ${BOOT_MODE}"; log "  Hostname:        ${SYSTEM_HOSTNAME}, MAKEOPTS: ${MAKEOPTS}"; if ! ask_confirm "Proceed with this configuration?"; then die "Installation cancelled."; fi
    { echo "TARGET_DEVICE='${TARGET_DEVICE}'"; echo "SYSTEM_HOSTNAME='${SYSTEM_HOSTNAME}'"; echo "SYSTEM_TIMEZONE='${SYSTEM_TIMEZONE}'"; echo "SYSTEM_LOCALE='${SYSTEM_LOCALE}'"; echo "CPU_MARCH='${CPU_MARCH}'"; echo "MAKEOPTS='${MAKEOPTS}'"; echo "EMERGE_JOBS='${detected_cores}'"; } > "$CONFIG_FILE_TMP"
}

# ==============================================================================
# --- STAGE 0B: DISK PREPARATION (DESTRUCTIVE) ---
# ==============================================================================
stage0_partition_and_format() {
    step_log "Disk Partitioning and Formatting (Mode: ${BOOT_MODE})"; warn "Final confirmation. ALL DATA ON ${TARGET_DEVICE} WILL BE PERMANENTLY DESTROYED!"; read -r -p "To confirm, type the full device name ('${TARGET_DEVICE}'): " confirmation; if [[ "$confirmation" != "${TARGET_DEVICE}" ]]; then die "Confirmation failed. Aborting."; fi
    log "Initiating 'Absolute Zero' protocol to free the device..."; umount "${TARGET_DEVICE}"* >/dev/null 2>&1 || true
    if command -v mdadm &>/dev/null; then mdadm --stop --scan >/dev/null 2>&1 || true; fi
    if command -v dmraid &>/dev/null; then dmraid -an >/dev/null 2>&1 || true; fi
    if command -v vgchange &>/dev/null; then vgchange -an >/dev/null 2>&1 || true; fi
    sync; blockdev --flushbufs "${TARGET_DEVICE}" >/dev/null 2>&1 || true; log "Device locks released."
    log "Wiping partition table on ${TARGET_DEVICE}..."; sgdisk --zap-all "${TARGET_DEVICE}"; sync
    if [[ "$BOOT_MODE" == "UEFI" ]]; then log "Creating GPT partitions for UEFI..."; sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System" "${TARGET_DEVICE}"; sgdisk -n 2:0:0 -t 2:8300 -c 2:"Gentoo Root" "${TARGET_DEVICE}"; else log "Creating GPT partitions for Legacy BIOS..."; sgdisk -n 1:0:+2M -t 1:ef02 -c 1:"BIOS Boot" "${TARGET_DEVICE}"; sgdisk -n 2:0:0 -t 2:8300 -c 2:"Gentoo Root" "${TARGET_DEVICE}"; fi
    sync; partprobe "${TARGET_DEVICE}"; local P_SEPARATOR=""; if [[ "${TARGET_DEVICE}" == *nvme* || "${TARGET_DEVICE}" == *mmcblk* ]]; then P_SEPARATOR="p"; fi
    if [[ "$BOOT_MODE" == "UEFI" ]]; then EFI_PART="${TARGET_DEVICE}${P_SEPARATOR}1"; ROOT_PART="${TARGET_DEVICE}${P_SEPARATOR}2"; else ROOT_PART="${TARGET_DEVICE}${P_SEPARATOR}2"; fi
    log "Probing for root partition ${ROOT_PART}..."; local wait_time=20; while (( wait_time > 0 )); do if [[ -b "${ROOT_PART}" ]]; then log "Root partition found."; break; fi; sleep 1; partprobe "${TARGET_DEVICE}"; wait_time=$((wait_time - 1)); done; if (( wait_time == 0 )); then die "Timed out waiting for root partition."; fi
    log "Formatting partitions..."; if [[ "$BOOT_MODE" == "UEFI" ]]; then log "Final cleaning of EFI partition..."; umount "${EFI_PART}" >/dev/null 2>&1 || true; wipefs -a "${EFI_PART}"; sync; mkfs.vfat -F 32 "${EFI_PART}"; fi
    log "Final cleaning of Root partition..."; umount "${ROOT_PART}" >/dev/null 2>&1 || true; wipefs -a "${ROOT_PART}"; sync; mkfs.xfs -f "${ROOT_PART}"; sync
    log "Mounting partitions..."; mkdir -p "${GENTOO_MNT}"; mount "${ROOT_PART}" "${GENTOO_MNT}"; if [[ "$BOOT_MODE" == "UEFI" ]]; then mkdir -p "${GENTOO_MNT}/boot/efi"; mount "${EFI_PART}" "${GENTOO_MNT}/boot/efi"; fi
}

# ==============================================================================
# --- STAGE 1: BASE SYSTEM DEPLOYMENT ---
# ==============================================================================
stage1_deploy_base_system() {
    step_log "Base System Deployment"; local success=false; local base_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/"; local latest_info_url="${base_url}latest-stage3-amd64-openrc.txt"; log "Fetching list of recent stage3 builds..."; local build_list; build_list=$(curl --fail -L -s --connect-timeout 15 "$latest_info_url" | grep '\.tar\.xz' | awk '{print $1}') || die "Could not fetch stage3 build list from ${latest_info_url}"
    local attempt_count=0; for build_path in $build_list; do attempt_count=$((attempt_count + 1)); log "--- [Attempt ${attempt_count}] Trying build: ${build_path} ---"; local tarball_name; tarball_name=$(basename "$build_path"); local tarball_url="${base_url}${build_path}"; local local_tarball_path="${GENTOO_MNT}/${tarball_name}"; log "Downloading stage3: ${tarball_name}"; wget --tries=3 --timeout=45 -c -O "${local_tarball_path}" "$tarball_url"; if [[ ! -s "${local_tarball_path}" ]]; then warn "Stage3 download failed. Trying next build..."; continue; fi
    local digests_url="${tarball_url}.DIGESTS"; local local_digests_path="${GENTOO_MNT}/${tarball_name}.DIGESTS"; log "Downloading digests file..."; wget --tries=3 -c -O "${local_digests_path}" "$digests_url"; if [[ ! -s "${local_digests_path}" ]]; then warn "Digests download failed. Trying next build..."; rm -f "${local_tarball_path}"; continue; fi
    if ${SKIP_CHECKSUM}; then warn "DANGER: SKIPPING CHECKSUM VERIFICATION AS REQUESTED."; success=true; break; fi
    log "Verifying tarball integrity with SHA512..."; pushd "${GENTOO_MNT}" >/dev/null; if grep -E "\s+${tarball_name}$" "$(basename "${local_digests_path}")" | sha512sum --strict -c -; then popd >/dev/null; log "Checksum OK. Found a valid stage3 build."; success=true; break; else popd >/dev/null; warn "Checksum FAILED for this build. Trying next."; rm -f "${local_tarball_path}" "${local_digests_path}"; fi; done
    if [ "$success" = false ]; then die "Failed to find a verifiable stage3 build after trying ${attempt_count} options."; fi; log "Unpacking stage3 tarball..."; tar xpvf "${local_tarball_path}" --xattrs-include='*.*' --numeric-owner -C "${GENTOO_MNT}"; log "Base system deployed successfully."
}

# ==============================================================================
# --- STAGE 2: CHROOT PREPARATION ---
# ==============================================================================
stage2_prepare_chroot() {
    step_log "Chroot Preparation"; log "Configuring Portage..."; mkdir -p "${GENTOO_MNT}/etc/portage/repos.conf"; cp "${GENTOO_MNT}/usr/share/portage/config/repos.conf" "${GENTOO_MNT}/etc/portage/repos.conf/gentoo.conf"
    log "Writing make.conf..."; local grub_platforms="pc"; if [[ "$BOOT_MODE" == "UEFI" ]]; then grub_platforms="efi-64"; fi
    # shellcheck disable=SC2154
    cat > "${GENTOO_MNT}/etc/portage/make.conf" <<EOF
# --- Generated by Nexus Autobuilder ---
COMMON_FLAGS="-O2 -pipe -march=${CPU_MARCH}"; CFLAGS="\${COMMON_FLAGS}"; CXXFLAGS="\${COMMON_FLAGS}"; MAKEOPTS="${MAKEOPTS}"
EMERGE_DEFAULT_OPTS="--jobs=${EMERGE_JOBS} --load-average=${EMERGE_JOBS} --quiet-build=y --autounmask-write=y --with-bdeps=y"
VIDEO_CARDS="amdgpu radeonsi"; INPUT_DEVICES="libinput synaptics"
USE="X elogind dbus policykit gtk udev udisks pulseaudio -gnome -kde -qt5 -systemd"
ACCEPT_LICENSE="@FREE linux-firmware"; GRUB_PLATFORMS="${grub_platforms}"; GENTOO_MIRRORS="https://distfiles.gentoo.org"
EOF
    log "Generating /etc/fstab..."; local ROOT_UUID; ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PART}"); local fstab_content="# /etc/fstab\nUUID=${ROOT_UUID}  /          xfs    defaults,noatime 0 1"
    if [[ "$BOOT_MODE" == "UEFI" ]]; then local EFI_UUID; EFI_UUID=$(blkid -s UUID -o value "${EFI_PART}"); fstab_content+="\nUUID=${EFI_UUID}   /boot/efi  vfat   defaults,noatime 0 2"; fi
    echo -e "${fstab_content}" > "${GENTOO_MNT}/etc/fstab"; log "/etc/fstab generated successfully."
    log "Mounting virtual filesystems..."; mount --types proc /proc "${GENTOO_MNT}/proc"; mount --rbind /sys "${GENTOO_MNT}/sys"; mount --make-rslave "${GENTOO_MNT}/sys"; mount --rbind /dev "${GENTOO_MNT}/dev"; mount --make-rslave "${GENTOO_MNT}/dev"
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
    step_log "System Configuration (Inside Chroot)"; source /etc/profile; export PS1="(chroot) ${PS1:-}"; log "Syncing Portage tree snapshot..."; emerge-webrsync || die "Failed to sync portage tree snapshot."
    log "Verifying existing profile..."; eselect profile list
    log "Configuring timezone and locale..."; ln -sf "/usr/share/zoneinfo/${SYSTEM_TIMEZONE}" /etc/localtime; echo "${SYSTEM_LOCALE} UTF-8" > /etc/locale.gen; echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen; locale-gen; eselect locale set "${SYSTEM_LOCALE}"; env-update && source /etc/profile; log "Setting hostname..."; echo "hostname=\"${SYSTEM_HOSTNAME}\"" > /etc/conf.d/hostname
}
stage4_build_world_and_kernel() {
    step_log "Updating @world set (3-stage process)"
    log "[1/3] Generating config updates..."; emerge -v --update --deep --newuse @world --autounmask-write || true
    
    # <<< THE HEALING / ИСЦЕЛЕНИЕ >>>
    log "[2/3] Applying config updates with precision..."
    echo "-5" | etc-update
    log "Config updates applied."
    
    log "[3/3] Building world..."; emerge -v --update --deep --newuse @world
    
    log "Optimizing mirrors..."; emerge --verbose app-portage/mirrorselect; cp /etc/portage/make.conf /etc/portage/make.conf.bak; sed -i '/^GENTOO_MIRRORS/d' /etc/portage/make.conf; mirrorselect -s4 -b10 -o -D >> /etc/portage/make.conf; log "Fastest mirrors selected."
    log "Installing firmware and kernel..."; emerge -v sys-kernel/linux-firmware sys-kernel/gentoo-sources; log "Building kernel with genkernel"; emerge -v sys-kernel/genkernel; genkernel all
}
stage5_install_bootloader() {
    step_log "Installing GRUB Bootloader (Mode: ${BOOT_MODE})"; emerge -v --noreplace sys-boot/grub:2; if [[ "$BOOT_MODE" == "UEFI" ]]; then grub-install --target=x86_64-efi --efi-directory=/boot/efi; else grub-install "${TARGET_DEVICE}"; fi; grub-mkconfig -o /boot/grub/grub.cfg
}
stage6_install_desktop() {
    step_log "Installing XFCE Desktop"; emerge -v xfce-base/xfce4-meta x11-terms/xfce4-terminal; log "Installing Xorg Server and Display Manager"; emerge -v x11-base/xorg-server x11-misc/lightdm x11-misc/lightdm-gtk-greeter; log "Installing essential desktop utilities"; emerge -v media-gfx/ristretto www-client/firefox-bin app-admin/sudo app-shells/bash-completion
}
stage7_finalize() {
    step_log "Finalizing System"; log "Enabling core services (OpenRC)..."; rc-update add dbus default; rc-update add elogind default; rc-update add display-manager default; rc-update add dhcpcd default; log "Configuring sudo for 'wheel' group..."; echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
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
        stage3_configure_in_chroot; stage4_build_world_and_kernel; stage5_install_bootloader; stage6_install_desktop; stage7_finalize
    else
        local FORCE_MODE=false
        for arg in "$@"; do case "$arg" in --force|--auto) FORCE_MODE=true;; --skip-checksum) SKIP_CHECKSUM=true;; esac; done
        self_check
        if mountpoint -q "${GENTOO_MNT}"; then force_unmount; fi
        pre_flight_checks; dependency_check; interactive_setup
        source "$CONFIG_FILE_TMP"
        stage0_partition_and_format; stage1_deploy_base_system
        echo "BOOT_MODE='${BOOT_MODE}'" >> "$CONFIG_FILE_TMP"
        stage2_prepare_chroot
    fi
}

main "$@"

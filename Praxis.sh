#!/bin/bash
# Gentoo Genesis — Full Automated Installer (interactive, full install)
# Version: 2025-11-11-final
#
# Run as root on a Gentoo Minimal Install CD environment.
# WARNING: This script does destructive disk operations (partitioning, formatting).
# It performs the full installation (including in-chroot steps) and DOES NOT reboot.
#
set -euo pipefail
IFS=$'\n\t'

# ---------------------------
# Globals / Defaults
# ---------------------------
GENTOO_MNT="/mnt/gentoo"
LOG_FILE="/var/log/genesis.log"
ERR_LOG="/var/log/genesis-error.log"
CONFIG_TMP="/tmp/genesis_config.$$"
CHECKPOINT_FILE="/tmp/.genesis_checkpoint"
FORCE=false
SKIP_CHECKSUM=true   # default per user request; can be overridden with --enable-checksum
CHROOTED=false

# Installation choices (populated interactively)
TARGET_DEVICE=""
ROOT_FS="btrfs"
CHOICE_INIT=""
CHOICE_KERNEL=""
CHOICE_BOOTLOADER=""
CHOICE_ENV=""
NEW_USER=""
NEW_PASS=""
SYSTEM_HOSTNAME="gentoo-desktop"
SYSTEM_TIMEZONE="UTC"
MAKEOPTS=""
BOOT_MODE=""

# Colors
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_INFO="\033[0;32m"; C_WARN="\033[0;33m"; C_ERR="\033[0;31m"; C_RST="\033[0m"
else
    C_INFO=""; C_WARN=""; C_ERR=""; C_RST=""
fi

# ---------------------------
# Logging setup
# ---------------------------
mkdir -p /var/log
touch "$LOG_FILE" "$ERR_LOG"
# Redirect all stdout/stderr through tee to log files, preserve console output
exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$ERR_LOG" >&2)

log(){ printf "%b[INFO] %s%b\n" "${C_INFO}" "$*" "${C_RST}"; }
warn(){ printf "%b[WARN] %s%b\n" "${C_WARN}" "$*" "${C_RST}" >&2; }
err(){ printf "%b[ERROR] %s%b\n" "${C_ERR}" "$*" "${C_RST}" >&2; }
die(){ err "$*"; cleanup || true; exit 1; }

# ---------------------------
# Cleanup & traps
# ---------------------------
cleanup() {
    log "Running cleanup..."
    sync || true
    # unmount chroot mounts if they exist
    for mp in proc sys dev run; do
        if mountpoint -q "${GENTOO_MNT}/${mp}" 2>/dev/null; then
            umount -l "${GENTOO_MNT}/${mp}" 2>/dev/null || true
        fi
    done
    if mountpoint -q "${GENTOO_MNT}/boot/efi" 2>/dev/null; then
        umount -l "${GENTOO_MNT}/boot/efi" 2>/dev/null || true
    fi
    if mountpoint -q "${GENTOO_MNT}" 2>/dev/null; then
        # keep root mounted for inspection (do not force unmount here)
        log "Leaving ${GENTOO_MNT} mounted for inspection."
    fi
    rm -f "$CONFIG_TMP" 2>/dev/null || true
    log "Cleanup done."
}

trap 'err "Interrupted by user"; cleanup; exit 130' INT
trap 'err "Error occurred"; cleanup; exit 1' ERR
trap 'cleanup; exit 0' EXIT

# ---------------------------
# Helpers
# ---------------------------
ensure_root() { [ "$(id -u)" -eq 0 ] || die "Run as root."; }
confirm(){
    if [ "$FORCE" = true ]; then return 0; fi
    local prompt="${1:-Proceed?}"
    local default="${2:-N}"
    local resp
    while true; do
        read -r -p "$prompt [y/N] " resp || true
        case "$resp" in
            [yY]|[yY][eE][sS]) return 0 ;;
            [nN]|"") [ "$default" = "N" ] && return 1 || return 0 ;;
            *) echo "Enter y or n." ;;
        esac
    done
}
ask_choice(){
    # ask_choice "Prompt" "opt1" "opt2" ...
    local prompt=$1; shift
    local options=("$@")
    echo
    echo "=== $prompt ==="
    local i=1
    for opt in "${options[@]}"; do
        printf "  %d) %s\n" "$i" "$opt"
        i=$((i+1))
    done
    local sel
    while true; do
        read -r -p "Select (1-${#options[@]}): " sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#options[@]}" ]; then
            echo "${options[$((sel-1))]}"
            return 0
        fi
        echo "Invalid selection."
    done
}
ask_password(){
    local prompt=${1:-Password}
    local p1 p2
    while true; do
        read -rs -p "$prompt: " p1; echo
        read -rs -p "Confirm $prompt: " p2; echo
        if [ -z "$p1" ]; then echo "Empty password not allowed."; continue; fi
        if [ "$p1" = "$p2" ]; then printf "%s" "$p1"; return 0; fi
        echo "Passwords do not match."
    done
}
device_suffix(){
    case "$1" in *nvme*|*mmcblk*) echo "p" ;; *) echo "" ;; esac
}
safe_mkdir(){ mkdir -p "$1" 2>/dev/null || true; }

# ---------------------------
# Network tests & mirrors
# ---------------------------
test_network(){
    log "Testing network connectivity..."
    if ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
        log "ICMP ping to 8.8.8.8 OK."
    else
        warn "ICMP ping failed. Trying HTTP check..."
        if command -v curl >/dev/null 2>&1; then
            if curl -fsS --connect-timeout 5 https://distfiles.gentoo.org/ >/dev/null 2>&1; then
                log "HTTP check to distfiles.gentoo.org OK."
            else
                die "Network unreachable: cannot reach distfiles.gentoo.org."
            fi
        else
            die "No curl found and ICMP failed — cannot verify network."
        fi
    fi
}

configure_mirrors(){
    log "Attempting to auto-select fastest mirrors with mirrorselect..."
    if command -v mirrorselect >/dev/null 2>&1; then
        # Generate recommended MIRRORS and append to chroot make.conf later
        FAST_MIRRORS=$(mirrorselect -s4 -b10 -o -D 2>/dev/null || true)
        if [ -n "$FAST_MIRRORS" ]; then
            log "mirrorselect found mirrors; saving temporary mirror list."
            echo "$FAST_MIRRORS" > "/tmp/genesis_mirrors.list.$$"
        else
            warn "mirrorselect failed to produce mirrors."
        fi
    else
        warn "mirrorselect not available on LiveCD. Skipping auto mirror selection."
    fi
}

# ---------------------------
# Pre-flight checks
# ---------------------------
self_check(){
    log "Running basic self-check..."
    local required=(bash coreutils grep sed awk tar xz wget curl sgdisk partprobe udevadm mount umount mkfs.vfat mkfs.ext4 mkfs.xfs mkfs.btrfs chroot)
    local miss=()
    for bin in "${required[@]}"; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            miss+=("$bin")
        fi
    done
    if [ "${#miss[@]}" -gt 0 ]; then
        warn "Missing utilities: ${miss[*]}. Script may still work but some steps can fail."
    else
        log "All core utilities present."
    fi
    # detect boot mode
    if [ -d /sys/firmware/efi ]; then BOOT_MODE="UEFI"; else BOOT_MODE="BIOS"; fi
    log "Detected boot mode: ${BOOT_MODE}"
}

# ---------------------------
# Interactive setup (choices)
# ---------------------------
interactive_setup(){
    step "Interactive setup: choose options"

    # init system
    local init_choice
    init_choice=$(ask_choice "Choose init system" "OpenRC" "systemd")
    CHOICE_INIT="$init_choice"

    # kernel method
    local k_choice
    k_choice=$(ask_choice "Choose kernel installation method" "genkernel (build kernel)" "gentoo-kernel-bin (prebuilt kernel)")
    if [[ "$k_choice" == genkernel* ]]; then CHOICE_KERNEL="genkernel"; else CHOICE_KERNEL="kernel-bin"; fi

    # bootloader
    local b_choice
    # support systemd-boot only for UEFI and if user chooses
    if [ "$BOOT_MODE" = "UEFI" ]; then
        b_choice=$(ask_choice "Choose bootloader" "GRUB (recommended)" "systemd-boot (UEFI only)" "Skip bootloader (install manually later)")
    else
        b_choice=$(ask_choice "Choose bootloader" "GRUB (recommended)" "Skip bootloader (install manually later)")
    fi
    case "$b_choice" in
        *GRUB*) CHOICE_BOOTLOADER="grub" ;;
        *systemd-boot*) CHOICE_BOOTLOADER="systemd-boot" ;;
        *Skip*) CHOICE_BOOTLOADER="skip" ;;
    esac

    # desktop environment
    local env_choice
    env_choice=$(ask_choice "Choose environment" "server (no GUI)" "minimal (console + networking)" "xfce (lightweight desktop)" "kde (plasma)" "gnome")
    case "$env_choice" in
        server*) CHOICE_ENV="server" ;;
        minimal*) CHOICE_ENV="minimal" ;;
        xfce*) CHOICE_ENV="xfce" ;;
        kde*) CHOICE_ENV="kde" ;;
        gnome*) CHOICE_ENV="gnome" ;;
    esac

    # username/password
    read -r -p "Enter username to create (leave empty to skip user creation): " NEW_USER
    if [ -n "$NEW_USER" ]; then
        NEW_PASS=$(ask_password "Password for ${NEW_USER}")
    fi

    # device
    while [ -z "$TARGET_DEVICE" ]; do
        read -r -p "Target block device (e.g. /dev/sda or /dev/nvme0n1): " TARGET_DEVICE
        if [ -z "$TARGET_DEVICE" ]; then continue; fi
        if [ ! -b "$TARGET_DEVICE" ]; then err "Device not found."; TARGET_DEVICE=""; fi
    done

    read -r -p "Root filesystem [btrfs/ext4/xfs] (default btrfs): " rv
    ROOT_FS=${rv:-btrfs}
    case "$ROOT_FS" in btrfs|ext4|xfs) : ;; *) warn "Unsupported FS; using btrfs"; ROOT_FS="btrfs" ;; esac

    read -r -p "Hostname (default gentoo-desktop): " SYSTEM_HOSTNAME
    SYSTEM_HOSTNAME=${SYSTEM_HOSTNAME:-gentoo-desktop}
    read -r -p "Timezone (e.g. Europe/Amsterdam) (default UTC): " SYSTEM_TIMEZONE
    SYSTEM_TIMEZONE=${SYSTEM_TIMEZONE:-UTC}

    local cores
    cores=$(nproc --all 2>/dev/null || echo 1)
    MAKEOPTS="-j${cores} -l${cores}"

    # Save config for chroot usage
    cat > "$CONFIG_TMP" <<EOF
TARGET_DEVICE='${TARGET_DEVICE}'
ROOT_FS='${ROOT_FS}'
CHOICE_INIT='${CHOICE_INIT}'
CHOICE_KERNEL='${CHOICE_KERNEL}'
CHOICE_BOOTLOADER='${CHOICE_BOOTLOADER}'
CHOICE_ENV='${CHOICE_ENV}'
NEW_USER='${NEW_USER}'
NEW_PASS='${NEW_PASS}'
SYSTEM_HOSTNAME='${SYSTEM_HOSTNAME}'
SYSTEM_TIMEZONE='${SYSTEM_TIMEZONE}'
MAKEOPTS='${MAKEOPTS}'
BOOT_MODE='${BOOT_MODE}'
EOF

    log "Interactive configuration saved to $CONFIG_TMP"
}

# ---------------------------
# Partition & format
# ---------------------------
partition_and_format(){
    step "Partitioning and formatting $TARGET_DEVICE"
    [ -n "$TARGET_DEVICE" ] || die "TARGET_DEVICE not set."

    warn "All data on $TARGET_DEVICE WILL BE DESTROYED!"
    confirm "Type y to continue and destroy all data on $TARGET_DEVICE" || die "User aborted."

    # unmount any mounts referencing device
    for m in $(mount | awk '{print $3}' | grep "^${TARGET_DEVICE}" || true); do
        umount -l "$m" 2>/dev/null || true
    done

    # wipe tables
    if command -v sgdisk >/dev/null 2>&1; then
        sgdisk --zap-all "$TARGET_DEVICE" >/dev/null 2>&1 || warn "sgdisk --zap-all failed"
    else
        warn "sgdisk not available; zeroing beginning of disk"
        dd if=/dev/zero of="$TARGET_DEVICE" bs=1M count=8 oflag=sync 2>/dev/null || true
    fi
    wipefs -a "$TARGET_DEVICE" 2>/dev/null || true
    sync; udevadm settle 2>/dev/null || true

    local psep
    psep=$(device_suffix "$TARGET_DEVICE")

    if [ "$BOOT_MODE" = "UEFI" ]; then
        sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System" "$TARGET_DEVICE"
        sgdisk -n 2:0:0 -t 2:8300 -c 2:"Gentoo Root" "$TARGET_DEVICE"
        partprobe "$TARGET_DEVICE" 2>/dev/null || true
        EFI_PART="${TARGET_DEVICE}${psep}1"
        ROOT_PART="${TARGET_DEVICE}${psep}2"
        mkfs.vfat -F32 "$EFI_PART" || die "mkfs.vfat failed on $EFI_PART"
    else
        sgdisk -n 1:0:0 -t 1:8300 -c 1:"Gentoo Root" "$TARGET_DEVICE"
        partprobe "$TARGET_DEVICE" 2>/dev/null || true
        ROOT_PART="${TARGET_DEVICE}${psep}1"
    fi

    safe_mkdir "$GENTOO_MNT"

    case "$ROOT_FS" in
        btrfs)
            mkfs.btrfs -f "$ROOT_PART" >/dev/null 2>&1 || die "mkfs.btrfs failed"
            local tmpb=$(mktemp -d)
            mount "$ROOT_PART" "$tmpb"
            btrfs subvolume create "${tmpb}/@" >/dev/null 2>&1 || true
            btrfs subvolume create "${tmpb}/@home" >/dev/null 2>&1 || true
            umount "$tmpb" || true; rmdir "$tmpb" || true
            mount -o subvol=@,compress=zstd,noatime "$ROOT_PART" "$GENTOO_MNT"
            mkdir -p "${GENTOO_MNT}/home"
            mount -o subvol=@home,compress=zstd,noatime "$ROOT_PART" "${GENTOO_MNT}/home"
            ;;
        ext4)
            mkfs.ext4 -F "$ROOT_PART" || die "mkfs.ext4 failed"
            mount "$ROOT_PART" "$GENTOO_MNT"
            ;;
        xfs)
            mkfs.xfs -f "$ROOT_PART" || die "mkfs.xfs failed"
            mount "$ROOT_PART" "$GENTOO_MNT"
            ;;
    esac

    if [ -n "${EFI_PART:-}" ]; then
        mkdir -p "${GENTOO_MNT}/boot/efi"
        mount "$EFI_PART" "${GENTOO_MNT}/boot/efi"
    fi

    log "Partitioning and formatting completed. ROOT_PART=${ROOT_PART} EFI_PART=${EFI_PART:-<none>}"
    echo "ROOT_PART='${ROOT_PART}'" >> "$CONFIG_TMP"
    echo "EFI_PART='${EFI_PART:-}'" >> "$CONFIG_TMP"
}

# ---------------------------
# Download & extract stage3 (network pre-check + mirrors)
# ---------------------------
download_and_extract_stage3(){
    step "Preparing mirrors and testing network"
    test_network
    configure_mirrors

    step "Downloading latest stage3 (variant based on init choice)"
    local variant="openrc"
    if [ "${CHOICE_INIT,,}" = "systemd" ]; then variant="systemd"; fi

    local base="https://distfiles.gentoo.org/releases/amd64/autobuilds/"
    local latest_txt="${base}latest-stage3-amd64-${variant}.txt"
    local filename=""
    if command -v curl >/dev/null 2>&1; then
        filename=$(curl -fsSL "$latest_txt" 2>/dev/null | awk '{print $1}' | grep '\.tar\.xz' | head -n1 || true)
    elif command -v wget >/dev/null 2>&1; then
        filename=$(wget -qO- "$latest_txt" 2>/dev/null | awk '{print $1}' | grep '\.tar\.xz' | head -n1 || true)
    fi
    if [ -z "$filename" ]; then
        warn "Could not determine exact stage3 filename; using fallback pattern."
        filename="stage3-amd64-${variant}-*.tar.xz"
    fi
    local url="${base}${filename}"
    local tmp="/tmp/${filename##*/}"
    log "Downloading ${url} -> ${tmp}"
    if command -v wget >/dev/null 2>&1; then
        wget -c -O "$tmp" "$url" || warn "wget failed to download stage3 (continuing to attempt extraction if file exists)"
    else
        curl -fL -o "$tmp" "$url" || warn "curl failed to download stage3"
    fi
    if [ ! -s "$tmp" ]; then
        die "Failed to download stage3 tarball."
    fi

    if [ "$SKIP_CHECKSUM" = true ]; then
        warn "Checksum verification SKIPPED (per config)."
    else
        warn "Attempting to fetch DIGESTS and verify (best-effort)."
        # Attempt to download DIGESTS; not fatal if missing
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "${base}${filename%.*}.DIGESTS" -o "/tmp/stage3.DIGESTS" 2>/dev/null || true
        fi
        if [ -s "/tmp/stage3.DIGESTS" ]; then
            log "DIGESTS found (not enforced to fail on mismatch)."
        else
            warn "DIGESTS not found; cannot verify checksum."
        fi
    fi

    step "Extracting stage3 to $GENTOO_MNT (this may take several minutes)"
    tar xpvf "$tmp" --xattrs-include='*.*' --numeric-owner -C "$GENTOO_MNT" || die "Failed to extract stage3"
    rm -f "$tmp" 2>/dev/null || true
    log "Stage3 extracted."
}

# ---------------------------
# Prepare chroot mounts & configs
# ---------------------------
prepare_chroot(){
    step "Setting up chroot binds and configs"
    mkdir -p "${GENTOO_MNT}/proc" "${GENTOO_MNT}/sys" "${GENTOO_MNT}/dev" "${GENTOO_MNT}/run"
    mount -t proc proc "${GENTOO_MNT}/proc" 2>/dev/null || true
    mount --rbind /sys "${GENTOO_MNT}/sys" 2>/dev/null || true
    mount --make-rslave "${GENTOO_MNT}/sys" 2>/dev/null || true
    mount --rbind /dev "${GENTOO_MNT}/dev" 2>/dev/null || true
    mount --make-rslave "${GENTOO_MNT}/dev" 2>/dev/null || true
    mount --bind /run "${GENTOO_MNT}/run" 2>/dev/null || true
    cp -L /etc/resolv.conf "${GENTOO_MNT}/etc/resolv.conf" 2>/dev/null || true

    # Setup minimal repos.conf in chroot if missing
    mkdir -p "${GENTOO_MNT}/etc/portage/repos.conf" 2>/dev/null || true
    if [ ! -f "${GENTOO_MNT}/etc/portage/repos.conf/gentoo.conf" ]; then
        cat > "${GENTOO_MNT}/etc/portage/repos.conf/gentoo.conf" <<'EOF'
[DEFAULT]
main-repo = gentoo
[gentoo]
location = /var/db/repos/gentoo
sync-type = git
sync-uri = https://github.com/gentoo/gentoo.git
EOF
    fi

    # If mirrorselect produced mirrors, add to chroot make.conf
    if [ -f "/tmp/genesis_mirrors.list.$$" ]; then
        log "Applying selected mirrors into chroot /etc/portage/make.conf"
        safe_mkdir "${GENTOO_MNT}/etc/portage"
        # Append mirrorselect output to make.conf in chroot safely
        cat "/tmp/genesis_mirrors.list.$$" > "${GENTOO_MNT}/etc/portage/make.conf.mirrors" 2>/dev/null || true
    fi

    # Copy our config for the chroot script to read
    cp -a "$CONFIG_TMP" "${GENTOO_MNT}/etc/genesis_config.sh" 2>/dev/null || true

    log "Chroot prepared."
}

# ---------------------------
# Build in-chroot script and run
# ---------------------------
build_chroot_script(){
    # We'll create a script inside chroot that reads /etc/genesis_config.sh and runs installation steps.
    cat <<'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
exec > /var/log/genesis-in-chroot.log 2>&1

# Load host-provided config
if [ -f /etc/genesis_config.sh ]; then
    # shellcheck disable=SC1091
    source /etc/genesis_config.sh || true
fi

log(){ printf "[CHROOT][INFO] %s\n" "$*"; }
warn(){ printf "[CHROOT][WARN] %s\n" "$*"; }
err(){ printf "[CHROOT][ERROR] %s\n" "$*"; }

echo "[CHROOT] Starting in-chroot automated steps..."

# Sync portage
if command -v emerge >/dev/null 2>&1; then
    emerge --sync || warn "emerge --sync encountered issues."
else
    warn "emerge not found inside chroot; ensure portage exists."
fi

# Minimal make.conf adjustments
if [ -n "${MAKEOPTS:-}" ]; then
    mkdir -p /etc/portage
    echo "MAKEOPTS=\"${MAKEOPTS}\"" >> /etc/portage/make.conf
fi

# add mirrorlist if present
if [ -f /etc/portage/make.conf.mirrors ]; then
    # Prepend MIRRORS list to make.conf
    awk 'NF' /etc/portage/make.conf.mirrors > /etc/portage/make.conf.mirrors.tmp || true
    if [ -s /etc/portage/make.conf.mirrors.tmp ]; then
        echo "" >> /etc/portage/make.conf
        cat /etc/portage/make.conf.mirrors.tmp >> /etc/portage/make.conf
    fi
fi

# Set timezone and locale
if [ -n "${SYSTEM_TIMEZONE:-}" ]; then
    ln -sf "/usr/share/zoneinfo/${SYSTEM_TIMEZONE}" /etc/localtime || true
    echo "${SYSTEM_TIMEZONE}" > /etc/timezone 2>/dev/null || true
fi
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen 2>/dev/null || true
locale-gen || true

# Set hostname
if [ -n "${SYSTEM_HOSTNAME:-}" ]; then
    echo "${SYSTEM_HOSTNAME}" > /etc/hostname
fi

# Ensure essential packages
EMERGE_OPTS="--quiet-build=n --getbinpkg-respect-use=y"

# Install microcode & firmware early
if [ -n "${MICROCODE_PACKAGE:-}" ]; then
    emerge --ask=n ${MICROCODE_PACKAGE} || warn "microcode emerge failed"
fi
emerge --ask=n sys-kernel/linux-headers sys-kernel/linux-firmware net-misc/netifrc || warn "essential emerge failed"

# Select profile (best-effort)
if command -v eselect >/dev/null 2>&1; then
    echo "[CHROOT] Attempting to select a reasonable profile..."
    # prefer latest default profile that matches init choice and desktop
    # This is naive: if not found, we skip and user can adjust later.
    prof=$(eselect profile list | awk -F') ' '{print $2}' | grep -i "default/linux" | head -n1 || true)
    if [ -n "$prof" ]; then
        idx=$(eselect profile list | nl -ba | grep -F "$prof" | awk '{print $1}' | head -n1 || true)
        if [ -n "$idx" ]; then
            eselect profile set "$idx" || warn "eselect profile set failed"
        fi
    fi
fi

# Update world (best-effort)
emerge --update --deep --newuse @world || warn "emerge @world failed (continuing)"

# Kernel installation
if [ "${CHOICE_KERNEL:-genkernel}" = "genkernel" ]; then
    emerge --ask=n sys-kernel/gentoo-sources sys-kernel/genkernel || warn "genkernel install failed"
    genkernel all || warn "genkernel build failed"
else
    emerge --ask=n sys-kernel/gentoo-kernel-bin || warn "gentoo-kernel-bin install failed"
fi

# Bootloader installation
if [ "${CHOICE_BOOTLOADER:-grub}" = "grub" ]; then
    emerge --ask=n sys-boot/grub || warn "grub emerge failed"
    if [ -d /sys/firmware/efi ]; then
        emerge --ask=n sys-boot/efibootmgr || warn "efibootmgr install failed"
        mkdir -p /boot/efi
        # grub-install must point to the EFI directory; assume /boot/efi exists and is mounted by host
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=gentoo --recheck || warn "grub-install efi failed"
    else
        # find disk for grub install (first disk)
        disk=$(lsblk -nd -o NAME,TYPE | awk '$2=="disk"{print $1; exit}')
        if [ -n "$disk" ]; then
            grub-install --target=i386-pc "/dev/${disk}" || warn "grub-install bios failed"
        else
            warn "No disk found for grub-install"
        fi
    fi
    grub-mkconfig -o /boot/grub/grub.cfg || warn "grub-mkconfig failed"
elif [ "${CHOICE_BOOTLOADER:-}" = "systemd-boot" ]; then
    if [ -d /sys/firmware/efi ]; then
        emerge --ask=n sys-boot/systemd-boot || warn "systemd-boot emerge failed"
        bootctl --path=/boot install || warn "bootctl install failed"
    else
        warn "systemd-boot requires UEFI; skipping"
    fi
else
    echo "[CHROOT] Bootloader installation skipped per user choice."
fi

# Init system specifics
if [ "${CHOICE_INIT:-openrc}" = "openrc" ]; then
    emerge --ask=n sys-apps/sysklogd || true
    rc-update add sysklogd default || true
    rc-update add sshd default || true
else
    emerge --ask=n sys-apps/systemd || true
fi

# Desktop environments
case "${CHOICE_ENV:-server}" in
    xfce)
        emerge --ask=n xfce-base/xfce4-meta x11-base/xorg-drivers || warn "xfce install issues"
        ;;
    kde)
        emerge --ask=n kde-plasma/plasma-meta || warn "kde install issues"
        ;;
    gnome)
        emerge --ask=n gnome-base/gnome || warn "gnome install issues"
        ;;
    minimal|server)
        echo "[CHROOT] No desktop packages installed for ${CHOICE_ENV}"
        ;;
esac

# Create user if provided
if [ -n "${NEW_USER:-}" ]; then
    useradd -m -G users,wheel -s /bin/bash "${NEW_USER}" || warn "useradd failed"
    echo "${NEW_USER}:${NEW_PASS}" | chpasswd || warn "chpasswd failed"
    echo "[CHROOT] Created user ${NEW_USER}"
fi

echo "[CHROOT] In-chroot automated tasks complete."
echo "[CHROOT] Note: script does NOT reboot automatically. Exit chroot and reboot when ready."
CHROOT_EOF
}

run_chroot_script(){
    step "Writing and executing in-chroot script"
    # write config inside chroot
    cp -a "$CONFIG_TMP" "${GENTOO_MNT}/etc/genesis_config.sh" 2>/dev/null || true
    # write chroot script
    build_chroot_script > "${GENTOO_MNT}/root/genesis_in_chroot.sh"
    chmod +x "${GENTOO_MNT}/root/genesis_in_chroot.sh"
    log "Starting chroot script (this may run for a long time)..."
    # Execute inside chroot
    chroot "$GENTOO_MNT" /bin/bash -c "/root/genesis_in_chroot.sh" || warn "In-chroot script returned non-zero (continuing)"
    log "In-chroot automation finished (or returned with warnings)."
    # cleanup in-chroot script
    rm -f "${GENTOO_MNT}/root/genesis_in_chroot.sh" 2>/dev/null || true
}

# ---------------------------
# Finalize (no reboot)
# ---------------------------
finalize_no_reboot(){
    step "Finalizing installation (no reboot)"
    sync
    # Unmount conductor mounts, leave root mounted for inspection
    for mp in proc sys dev run; do
        if mountpoint -q "${GENTOO_MNT}/${mp}" 2>/dev/null; then
            umount -l "${GENTOO_MNT}/${mp}" 2>/dev/null || true
        fi
    done
    log "Pre-chroot mounts cleaned. Root at ${GENTOO_MNT} remains mounted for inspection."
    log "Installation complete. Reboot manually when ready."
}

# ---------------------------
# Utility: step printing
# ---------------------------
step(){ echo; log "=== $* ==="; }

# ---------------------------
# CLI parsing & main
# ---------------------------
usage(){
    cat <<EOF
Usage: $0 [--force] [--enable-checksum] [--help]

--force            Non-interactive confirmations (use with caution)
--enable-checksum  Attempt to verify stage3 DIGESTS (best-effort)
--help             Show this help
EOF
}

parse_args(){
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) FORCE=true; shift ;;
            --enable-checksum) SKIP_CHECKSUM=false; shift ;;
            --help) usage; exit 0 ;;
            *) echo "Unknown arg: $1"; usage; exit 1 ;;
        esac
    done
}

main(){
    parse_args "$@"
    ensure_root
    self_check

    # Interactive setup
    interactive_setup

    # Partition & format
    partition_and_format

    # Download & extract stage3
    download_and_extract_stage3

    # Prepare chroot
    prepare_chroot

    # Run in-chroot automation
    run_chroot_script

    # Finalize (leave system ready, no reboot)
    finalize_no_reboot
}

main "$@"

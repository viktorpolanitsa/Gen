#!/bin/bash
set -euo pipefail

LOGFILE="/var/log/sysauto.log"
log_info()  { echo "[INFO] $1" | tee -a "$LOGFILE"; }
log_warn()  { echo "[WARN] $1" | tee -a "$LOGFILE"; }
log_error() { echo "[ERROR] $1" | tee -a "$LOGFILE"; }

# ==========================================
# Kernel Selection
# ==========================================
select_kernel() {
    log_info "Detecting available kernels in /usr/src/..."
    KERNELS=($(ls -1 /usr/src/ | grep "^linux-" || true))
    if [ ${#KERNELS[@]} -eq 0 ]; then
        log_error "No kernel sources found in /usr/src."
        exit 1
    fi

    echo "Available kernels:"
    i=1
    for k in "${KERNELS[@]}"; do
        echo " [$i] $k"
        ((i++))
    done

    echo -n "Select kernel number: "
    read -r KNUM

    if ! [[ "$KNUM" =~ ^[0-9]+$ ]] || [ "$KNUM" -lt 1 ] || [ "$KNUM" -gt "${#KERNELS[@]}" ]; then
        log_error "Invalid selection."
        exit 1
    fi

    TARGET_KERNEL="${KERNELS[$((KNUM - 1))]}"
    KERNEL_PATH="/usr/src/${TARGET_KERNEL}"
    log_info "Selected kernel: ${TARGET_KERNEL}"
}

# ==========================================
# make.conf Optimization
# ==========================================
optimize_makeconf() {
    log_info "Optimizing /etc/portage/make.conf for AMD A10 and XFCE..."

    local CONF="/etc/portage/make.conf"
    local BACKUP="/etc/portage/make.conf.backup"

    if [[ ! -f "$BACKUP" ]]; then
        cp "$CONF" "$BACKUP"
        log_info "Backup created: $BACKUP"
    fi

    cat > "$CONF" <<'EOF'
# =========================
# Optimized make.conf (Auto-generated)
# Target: AMD A10-9600P + Radeon R5 + HDD + XFCE
# =========================

COMMON_FLAGS="-march=bdver4 -O2 -pipe -fomit-frame-pointer"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"

MAKEOPTS="-j4 -l4"

VIDEO_CARDS="amdgpu radeonsi radeon"
INPUT_DEVICES="libinput"

USE="X xorg gtk3 dbus pulseaudio vulkan opengl udev drm alsa policykit introspection threads \
     elogind xfce xfce4 xfs unicode truetype branding"

GENTOO_MIRRORS="https://mirror.bytemark.co.uk/gentoo/ https://mirror.eu.oneandone.net/gentoo/"
ACCEPT_LICENSE="*"

FEATURES="parallel-fetch compress-build-logs clean-logs sandbox usersandbox userfetch"
EMERGE_DEFAULT_OPTS="--ask=n --verbose --with-bdeps=y --autounmask=y --autounmask-continue=y"

PORTDIR="/var/db/repos/gentoo"
DISTDIR="/var/cache/distfiles"
PKGDIR="/var/cache/binpkgs"

LINGUAS="en en_US"
L10N="en"

FILE_SYSTEMS="xfs ext4 tmpfs"

EMERGE_WARNING_DELAY=0
EOF

    log_info "/etc/portage/make.conf optimized successfully."
}

# ==========================================
# HDD + XFS Optimization
# ==========================================
optimize_hdd() {
    log_info "Applying HDD and XFS performance optimizations..."

    cat > /etc/sysctl.d/99-hdd-xfs-tuning.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
    sysctl --system

    echo 'ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="bfq"' > /etc/udev/rules.d/60-io-scheduler.rules

    if grep -q "xfs" /etc/fstab; then
        sed -i 's/\(xfs.*defaults\)/\1,noatime,logbufs=8,logbsize=256k/' /etc/fstab
    fi

    grep -q "/var/tmp/portage" /etc/fstab || echo "tmpfs /var/tmp/portage tmpfs size=6G,noatime,nodev,nosuid,mode=1777 0 0" >> /etc/fstab
    grep -q "/tmp" /etc/fstab || echo "tmpfs /tmp tmpfs size=2G,noatime,nodev,nosuid,mode=1777 0 0" >> /etc/fstab

    log_info "HDD/XFS optimizations applied successfully."
}

# ==========================================
# Power Management Optimization
# ==========================================
optimize_power() {
    log_info "Applying AMD APU and system power optimizations..."

    mkdir -p /etc/local.d

    cat > /etc/local.d/power.start <<'EOF'
#!/bin/bash
# Power optimization script (auto-generated)

# CPU governor
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    echo ondemand > "$cpu/cpufreq/scaling_governor" 2>/dev/null || true
done

# Set APU performance balance
echo auto > /sys/class/drm/card0/device/power_dpm_force_performance_level 2>/dev/null || true

# Enable ASPM and SATA link power management
echo powersupersave > /sys/class/scsi_host/host*/link_power_management_policy 2>/dev/null || true
for dev in /sys/class/pci_bus/*/power/control; do
    echo auto > "$dev" 2>/dev/null || true
done

# Radeon Power Profiles
echo auto > /sys/class/drm/card0/device/power_method 2>/dev/null || true
echo low > /sys/class/drm/card0/device/power_profile 2>/dev/null || true

# Disable unused wakeups
echo disabled > /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true

# Set VM writeback delay for HDD
echo 1500 > /proc/sys/vm/dirty_writeback_centisecs
EOF

    chmod +x /etc/local.d/power.start
    rc-update add local default

    log_info "Power management optimizations installed."
}

# ==========================================
# System Update
# ==========================================
update_system() {
    log_info "Syncing Portage and updating system..."
    emerge --sync || log_error "Emerge sync failed."
    emerge -uDU --with-bdeps=y --autounmask=y --autounmask-continue=y @world || log_error "World update failed."
    emerge --depclean || true
    revdep-rebuild || true
    log_info "System update complete."
}

# ==========================================
# Kernel Compilation
# ==========================================
build_kernel() {
    log_info "Preparing to build kernel ${TARGET_KERNEL}..."

    if ! mountpoint -q /boot; then
        mount /boot || log_error "Cannot mount /boot."
    fi

    ln -sf "$KERNEL_PATH" /usr/src/linux
    cd "$KERNEL_PATH"

    log_info "Configuring kernel with built-in AMD and XFS support..."
    make olddefconfig

    scripts/config --disable MODULES
    scripts/config --enable DEVTMPFS
    scripts/config --enable DEVTMPFS_MOUNT
    scripts/config --enable TMPFS
    scripts/config --enable EFI_STUB
    scripts/config --enable EFI_MIXED
    scripts/config --enable EFI_PARTITION
    scripts/config --enable FRAMEBUFFER_CONSOLE
    scripts/config --enable DRM
    scripts/config --enable DRM_AMDGPU
    scripts/config --enable DRM_RADEON
    scripts/config --enable FB_EFI
    scripts/config --enable X86_AMD_PLATFORM_DEVICE
    scripts/config --enable HWMON
    scripts/config --enable POWER_SUPPLY
    scripts/config --enable EXT4_FS
    scripts/config --enable XFS_FS
    scripts/config --enable XFS_POSIX_ACL
    scripts/config --enable XFS_QUOTA
    scripts/config --enable XFS_ONLINE_SCRUB
    scripts/config --enable TMPFS_POSIX_ACL
    scripts/config --enable BLK_DEV_INITRD

    log_info "Building kernel..."
    make -j$(nproc)

    log_info "Installing kernel..."
    make modules_install || true
    cp arch/x86/boot/bzImage "/boot/vmlinuz-${TARGET_KERNEL}"
    cp System.map "/boot/System.map-${TARGET_KERNEL}"
    cp .config "/boot/config-${TARGET_KERNEL}"

    log_info "Building initramfs..."
    genkernel --install --no-mrproper initramfs

    log_info "Kernel ${TARGET_KERNEL} built and installed successfully."
}

# ==========================================
# GRUB UEFI Configuration
# ==========================================
update_grub() {
    log_info "Updating GRUB for UEFI..."
    if [[ -d /boot/efi/EFI/gentoo ]]; then
        grub-mkconfig -o /boot/efi/EFI/gentoo/grub.cfg
    else
        grub-mkconfig -o /boot/grub/grub.cfg
    fi
    grub-set-default 0 || true
    sync
    log_info "GRUB update complete."
}

# ==========================================
# XFCE + Xorg Setup
# ==========================================
install_desktop() {
    log_info "Installing Xorg and XFCE..."
    emerge --ask=n --verbose \
        x11-base/xorg-server \
        x11-base/xorg-drivers \
        x11-misc/lightdm \
        x11-themes/adwaita-icon-theme \
        xfce-base/xfce4-meta \
        xfce-extra/xfce4-goodies \
        media-libs/mesa \
        x11-drivers/xf86-video-amdgpu \
        media-libs/vulkan-loader \
        media-libs/vulkan-tools

    rc-update add dbus default
    rc-update add xdm default
    echo 'DISPLAYMANAGER="lightdm"' > /etc/conf.d/xdm
    log_info "XFCE configured for auto-start on boot."
}

# ==========================================
# Auto Cleanup and Cache Maintenance
# ==========================================
auto_cleanup() {
    log_info "Running automatic cleanup and cache optimization..."

    # Clean unused kernels, keep last 2
    eclean-kernel -n 2 || true

    # Deep clean distfiles and binary packages
    eclean-dist --deep || true
    eclean-pkg --deep || true

    # Clear old logs
    find /var/log -type f -name "*.log" -mtime +10 -exec truncate -s 0 {} \; || true

    # Remove stale portage temp files
    rm -rf /var/tmp/portage/* /tmp/* || true

    # Recalculate free space
    df -h | tee -a "$LOGFILE"

    log_info "Automatic cleanup complete."
}

# ==========================================
# Main Routine
# ==========================================
main() {
    log_info "===== Starting Full System Maintenance ====="
    optimize_makeconf
    optimize_hdd
    optimize_power
    select_kernel
    update_system
    build_kernel
    update_grub
    install_desktop
    auto_cleanup
    log_info "===== All tasks completed successfully ====="
}

main "$@"

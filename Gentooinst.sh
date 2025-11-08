#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# -----------------------------
# Output functions
# -----------------------------
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# -----------------------------
# Check for root
# -----------------------------
if [[ $EUID -ne 0 ]]; then
    log_error "Run this script as root!"
    exit 1
fi

# -----------------------------
# Check required utilities
# -----------------------------
REQUIRED_UTILS=("equery" "grep" "awk" "sed" "ls" "cp" "mkdir" "rm" "ln" "make" "grub-mkconfig" "find" "genkernel" "emerge" "eselect" "xfs_info" "xfs_repair" "xfs_admin" "lspci" "xauth")
MISSING_UTILS=()

for util in "${REQUIRED_UTILS[@]}"; do
    if ! command -v "$util" &>/dev/null; then
        MISSING_UTILS+=("$util")
    fi
done

if [[ ${#MISSING_UTILS[@]} -gt 0 ]]; then
    log_error "Required utilities missing: ${MISSING_UTILS[*]}"
    log_info "Install them: emerge --ask sys-fs/xfsprogs for XFS tools"
    exit 1
fi

CPU_CORES=$(nproc --all)
CPU_CORES=${CPU_CORES:-$(getconf _NPROCESSORS_ONLN)}
CPU_CORES=${CPU_CORES:-4}  # Fallback value

# Logs
KERNEL_LOG="/var/log/kernel_build_$(date +%Y%m%d_%H%M%S).log"
XFCE_LOG="/var/log/xfce_install_$(date +%Y%m%d_%H%M%S).log"
SCRIPT_LOG="/var/log/xfce_kernel_setup_$(date +%Y%m%d_%H%M%S).log"

exec 3>&1 4>&2
exec 1> >(tee -a "$SCRIPT_LOG")
exec 2> >(tee -a "$SCRIPT_LOG" >&2)

# -----------------------------
# Status check functions
# -----------------------------
check_status() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "$1 (exit code: $exit_code)"
        exit $exit_code
    fi
}

normalize_answer() {
    local answer="$1"
    echo "$answer" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1
}

# -----------------------------
# Function to check and install packages
# -----------------------------
check_and_install_package() {
    local package="$1"
    local description="$2"
    local use_flags="$3"
    
    log_info "Checking package: $package ($description)"
    
    if equery list "$package" &>/dev/null; then
        log_info "Package $package is already installed."
        return 0
    fi
    
    log_info "Package $package not found. Searching..."
    
    if emerge --search "$package" 2>/dev/null | grep -q "^${package}[[:space:]]"; then
        log_info "Installing $package..."
        if [[ -n "$use_flags" ]]; then
            emerge --verbose --ask=n --autounmask-write=y "$package" || true
            etc-update --automode -5 || true
            emerge --verbose --ask=n $use_flags "$package"
        else
            emerge --verbose --ask=n "$package"
        fi
        check_status "Installation of $package"
        return 0
    fi
    
    log_warn "Package $package not found in repositories!"
    read -rp "Continue without this package? [y/N] " choice
    choice=$(normalize_answer "$choice")
    if [[ "$choice" != "y" && "$choice" != "n" ]]; then
        choice="n"
    fi
    if [[ "$choice" != "y" ]]; then
        log_error "Required package $package not available!"
        exit 1
    fi
}

# -----------------------------
# Check XFS filesystem
# -----------------------------
check_xfs_filesystem() {
    log_info "Checking XFS filesystem..."
    
    # Check mounted XFS filesystems
    if mount | grep -q xfs; then
        log_info "Found XFS filesystems:"
        mount | grep xfs | while read -r line; do
            echo "  $line"
        done
    else
        log_warn "XFS filesystems not found in /proc/mounts"
    fi
    
    # Check XFS tools
    if command -v xfs_info &>/dev/null; then
        log_info "XFS tools installed"
    else
        log_error "XFS tools not installed!"
        check_and_install_package "sys-fs/xfsprogs" "XFS tools"
    fi
}

# -----------------------------
# Function to configure GRUB with new kernel as default
# -----------------------------
setup_grub_default() {
    local new_kernel_name="$1"
    log_info "Configuring GRUB to select new kernel $new_kernel_name as default..."
    
    # Update GRUB configuration
    grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee -a "$KERNEL_LOG"
    check_status "GRUB update"
    
    # Find menu number for new kernel
    if grep -q "menuentry.*$new_kernel_name" /boot/grub/grub.cfg; then
        log_info "Setting new kernel as default boot option..."
        # Get menu number for new kernel
        MENU_ENTRY=$(grep -n "menuentry.*$new_kernel_name" /boot/grub/grub.cfg | head -1 | cut -d: -f1)
        if [[ -n "$MENU_ENTRY" ]]; then
            sed -i "s/GRUB_DEFAULT=.*/GRUB_DEFAULT=$((MENU_ENTRY-1))/" /etc/default/grub
            log_info "Updated default boot option in /etc/default/grub"
            
            # Update GRUB again with new settings
            grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee -a "$KERNEL_LOG"
            check_status "GRUB update"
            log_success "New kernel $new_kernel_name set as default boot"
        else
            log_warn "Could not determine menu number for $new_kernel_name"
        fi
    else
        log_warn "Kernel $new_kernel_name not found in GRUB configuration"
        log_info "Available kernels in GRUB:"
        grep -E "menuentry.*linux" /boot/grub/grub.cfg | sed 's/^.*menuentry //;s/ {.*$//' | head -10
    fi
}

# -----------------------------
# Function to configure X-server
# -----------------------------
setup_x_server() {
    log_info "Configuring X-server..."
    
    # Fix .Xauthority permissions
    if [[ -f ~/.Xauthority ]]; then
        chmod 600 ~/.Xauthority
    else
        touch ~/.Xauthority
        chmod 600 ~/.Xauthority
    fi
    
    # Check graphics card and install appropriate driver
    if command -v lspci &>/dev/null; then
        VIDEO_CHIP=$(lspci | grep -E "VGA|3D" | head -n 1)
        log_info "Detected graphics device: $VIDEO_CHIP"
        
        if echo "$VIDEO_CHIP" | grep -qi "intel"; then
            DRIVER="xf86-video-intel"
        elif echo "$VIDEO_CHIP" | grep -qi "amd\|radeon\|ati"; then
            DRIVER="xf86-video-amdgpu"
        elif echo "$VIDEO_CHIP" | grep -qi "nvidia\|nouveau"; then
            DRIVER="xf86-video-nouveau"
        else
            DRIVER="xf86-video-vesa"
        fi
        
        log_info "Installing driver: $DRIVER"
        check_and_install_package "x11-drivers/$DRIVER" "X-server driver"
        
        # Ensure OpenGL is set correctly
        if eselect opengl list &>/dev/null; then
            eselect opengl set xorg-x11
            log_info "OpenGL set to xorg-x11"
        fi
    else
        log_warn "lspci not found, cannot determine graphics device"
        # Install vesa driver as fallback
        check_and_install_package "x11-drivers/xf86-video-vesa" "X-server VESA driver"
    fi
    
    # Remove old X-server configuration
    if [[ -f /etc/X11/xorg.conf ]]; then
        mv /etc/X11/xorg.conf /etc/X11/xorg.conf.backup_$(date +%Y%m%d_%H%M%S)
        log_info "Old X-server configuration moved to backup"
    fi
    
    log_success "X-server configured"
}

# -----------------------------
# Step 1: Select kernel
# -----------------------------
log_info "Scanning /usr/src for available kernels..."
if [[ ! -d /usr/src ]]; then
    log_error "/usr/src directory does not exist!"
    exit 1
fi

mapfile -t KERNELS < <(find /usr/src -maxdepth 1 -type d -name "linux-*" -exec basename {} \; 2>/dev/null | sort -V)
if [[ ${#KERNELS[@]} -eq 0 ]]; then
    log_error "Kernel sources not found in /usr/src!"
    log_info "Install kernel sources first:"
    log_info "emerge --ask sys-kernel/gentoo-sources"
    exit 1
fi

log_info "Available kernels:"
for idx in "${!KERNELS[@]}"; do
    echo "$idx) ${KERNELS[$idx]}"
done

while true; do
    read -rp "Enter the number of the kernel to use: " KERNEL_IDX
    if [[ "$KERNEL_IDX" =~ ^[0-9]+$ ]] && [[ "$KERNEL_IDX" -ge 0 ]] && [[ "$KERNEL_IDX" -lt ${#KERNELS[@]} ]]; then
        break
    else
        log_error "Invalid kernel number!"
    fi
done

KERNEL_SRC="/usr/src/${KERNELS[$KERNEL_IDX]}"
if [[ ! -d "$KERNEL_SRC" ]]; then
    log_error "Kernel sources $KERNEL_SRC not found!"
    exit 1
fi

# -----------------------------
# Step 2: Select installation options
# -----------------------------
echo "---------------------------------------------"
echo "Configure installation options (y/n):"
read -rp "Backup current kernel? [Y/n] " BACKUP_CHOICE
BACKUP_CHOICE=$(normalize_answer "$BACKUP_CHOICE")
[[ -z "$BACKUP_CHOICE" ]] && BACKUP_CHOICE="y"

read -rp "Build and install kernel? [Y/n] " BUILD_KERNEL
BUILD_KERNEL=$(normalize_answer "$BUILD_KERNEL")
[[ -z "$BUILD_KERNEL" ]] && BUILD_KERNEL="y"

read -rp "Install XFCE/Xorg? [Y/n] " INSTALL_XFCE
INSTALL_XFCE=$(normalize_answer "$INSTALL_XFCE")
[[ -z "$INSTALL_XFCE" ]] && INSTALL_XFCE="y"

read -rp "Enable CPU optimizations? [Y/n] " CPU_OPT
CPU_OPT=$(normalize_answer "$CPU_OPT")
[[ -z "$CPU_OPT" ]] && CPU_OPT="y"

read -rp "Enable GPU optimizations? [Y/n] " GPU_OPT
GPU_OPT=$(normalize_answer "$GPU_OPT")
[[ -z "$GPU_OPT" ]] && GPU_OPT="y"

read -rp "Enable HDD/laptop optimizations? [Y/n] " HDD_OPT
HDD_OPT=$(normalize_answer "$HDD_OPT")
[[ -z "$HDD_OPT" ]] && HDD_OPT="y"

# -----------------------------
# Step 3: Check XFS and install dependencies
# -----------------------------
check_xfs_filesystem

log_info "Checking and installing dependencies..."

# Check and install base dependencies
check_and_install_package "sys-kernel/linux-firmware" "Hardware firmware"
check_and_install_package "sys-devel/gcc" "Compiler"
check_and_install_package "app-misc/pciutils" "PCI utilities"
check_and_install_package "app-misc/usbutils" "USB utilities"
check_and_install_package "sys-fs/xfsprogs" "XFS tools" "sys-fs/xfsprogs[X]"

if [[ "$BUILD_KERNEL" == "y" ]]; then
    check_and_install_package "sys-kernel/genkernel" "Initramfs generation"
    check_and_install_package "sys-kernel/installkernel" "Kernel installation"
fi

if [[ "$INSTALL_XFCE" == "y" ]]; then
    check_and_install_package "x11-base/xorg-server" "X server"
    check_and_install_package "x11-base/xorg-drivers" "Graphics drivers"
    check_and_install_package "media-libs/mesa" "OpenGL support"
    check_and_install_package "app-admin/eselect-opengl" "OpenGL switching"
    check_and_install_package "xfce-base/xfce4-meta" "XFCE desktop environment"
    check_and_install_package "xfce-extra/xfce4-goodies" "XFCE additional apps"
    check_and_install_package "x11-misc/lightdm" "Display manager"
    check_and_install_package "x11-misc/lightdm-gtk-greeter" "GTK greeter for LightDM"
fi

if [[ "$HDD_OPT" == "y" ]]; then
    check_and_install_package "app-laptop/laptop-mode-tools" "Power management"
fi

# -----------------------------
# Step 4: Kernel backup
# -----------------------------
if [[ "$BACKUP_CHOICE" == "y" ]]; then
    if [[ ! -d /boot ]]; then
        log_error "/boot directory does not exist!"
        exit 1
    fi
    
    BACKUP_DIR="/boot/backup_kernel_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    log_info "Creating backup in $BACKUP_DIR..."
    
    # Backup kernel files
    for kernel_file in /boot/vmlinuz-*; do
        if [[ -f "$kernel_file" ]]; then
            cp "$kernel_file" "$BACKUP_DIR/" 2>/dev/null
            log_info "Copied kernel file: $(basename "$kernel_file")"
        fi
    done
    
    # Backup initramfs
    for initramfs_file in /boot/initramfs-*; do
        if [[ -f "$initramfs_file" ]]; then
            cp "$initramfs_file" "$BACKUP_DIR/" 2>/dev/null
            log_info "Copied initramfs: $(basename "$initramfs_file")"
        fi
    done
    
    # Backup kernel config
    for config_file in /boot/config-*; do
        if [[ -f "$config_file" ]]; then
            cp "$config_file" "$BACKUP_DIR/" 2>/dev/null
            log_info "Copied config: $(basename "$config_file")"
        fi
    done
    
    # Backup System.map
    for system_map in /boot/System.map-*; do
        if [[ -f "$system_map" ]]; then
            cp "$system_map" "$BACKUP_DIR/" 2>/dev/null
            log_info "Copied System.map: $(basename "$system_map")"
        fi
    done
fi

# -----------------------------
# Step 5: Create linux symlink
# -----------------------------
cd /usr/src || exit 1
if [[ -L linux ]]; then
    log_info "Removing existing /usr/src/linux symlink"
    rm -f linux
elif [[ -d linux ]]; then
    log_warn "Directory /usr/src/linux exists but is not a symlink"
    mv linux linux.backup_$(date +%Y%m%d_%H%M%S)
    log_info "Backed up old directory"
fi

ln -sf "$(basename "$KERNEL_SRC")" linux
log_info "Created symlink: linux -> $(basename "$KERNEL_SRC")"

cd linux || exit 1

# -----------------------------
# Step 6: Kernel configuration with XFS support
# -----------------------------
if [[ "$BUILD_KERNEL" == "y" ]]; then
    log_info "Configuring kernel..."
    
    # Check for existing config
    if [[ -f "/etc/kernels/kernel-config-$(uname -r)" ]]; then
        log_info "Using existing kernel configuration"
        cp "/etc/kernels/kernel-config-$(uname -r)" .config
    elif [[ -f "/proc/config.gz" ]]; then
        log_info "Using current kernel configuration"
        zcat /proc/config.gz > .config
    else
        log_info "Creating basic configuration"
        make defconfig
        check_status "defconfig"
    fi
    
    # Check for scripts/config
    if [[ -f scripts/config ]]; then
        log_info "Using scripts/config for kernel configuration"
        
        # Basic drivers
        ./scripts/config --enable BLK_DEV_SD || true
        ./scripts/config --enable ATA || true
        ./scripts/config --enable SCSI_MOD || true
        ./scripts/config --enable AHCI || true
        
        # XFS filesystem - must enable
        ./scripts/config --enable XFS_FS || true
        ./scripts/config --enable XFS_QUOTA || true
        ./scripts/config --enable XFS_POSIX_ACL || true
        ./scripts/config --enable XFS_RT || true
        ./scripts/config --enable XFS_ONLINE_SCRUB || true
        ./scripts/config --enable XFS_ONLINE_REPAIR || true
        
        # EXT4 for compatibility
        ./scripts/config --enable EXT4_FS || true
        ./scripts/config --enable EXT2_FS || true
        
        ./scripts/config --enable USB || true
        ./scripts/config --enable USB_EHCI_HCD || true
        ./scripts/config --enable USB_UHCI_HCD || true
        ./scripts/config --enable USB_OHCI_HCD || true
        ./scripts/config --enable USB_XHCI_HCD || true
        ./scripts/config --enable USB_STORAGE || true
        ./scripts/config --disable MODULE_SIG || true
        ./scripts/config --disable MODULE_SIG_ALL || true
        ./scripts/config --disable MODULE_SIG_HASH || true
        
        # CPU optimizations
        if [[ "$CPU_OPT" == "y" ]]; then
            log_info "Enabling CPU optimizations..."
            ./scripts/config --enable CPU_FREQ || true
            ./scripts/config --enable CPU_FREQ_GOV_ONDEMAND || true
            ./scripts/config --enable CPU_FREQ_GOV_CONSERVATIVE || true
            ./scripts/config --enable CPU_FREQ_STAT || true
            ./scripts/config --enable CPU_IDLE || true
            ./scripts/config --enable SCHED_MC || true
            ./scripts/config --enable SCHED_SMT || true
        fi
        
        # GPU optimizations
        if [[ "$GPU_OPT" == "y" ]]; then
            log_info "Enabling GPU optimizations..."
            ./scripts/config --enable DRM || true
            ./scripts/config --enable DRM_KMS_HELPER || true
            ./scripts/config --enable DRM_TTM || true
            
            # Radeon
            ./scripts/config --enable DRM_RADEON || true
            ./scripts/config --enable RADEON_DPM || true
            
            # Intel
            ./scripts/config --enable DRM_I915 || true
            ./scripts/config --enable DRM_I915_KMS || true
            
            # NVIDIA (if available)
            ./scripts/config --enable DRM_NOUVEAU || true
            
            # Set module parameters
            mkdir -p /etc/modprobe.d
            if lsmod | grep -q radeon; then
                echo "options radeon dpm=1" > /etc/modprobe.d/radeon.conf
                log_info "Created /etc/modprobe.d/radeon.conf for Radeon DPM"
            elif lsmod | grep -q i915; then
                echo "options i915 enable_fbc=1 enable_psr=1" > /etc/modprobe.d/i915.conf
                log_info "Created /etc/modprobe.d/i915.conf for Intel GPU"
            fi
        fi
        
        make olddefconfig
        check_status "olddefconfig"
    else
        log_warn "scripts/config not found, using make olddefconfig"
        make olddefconfig
        check_status "olddefconfig"
    fi
    
    log_info "Building kernel with ${CPU_CORES} cores..."
    make -j"$CPU_CORES" V=1 | tee "$KERNEL_LOG"
    check_status "Kernel build"
    
    log_info "Installing kernel modules..."
    make modules_install | tee -a "$KERNEL_LOG"
    check_status "Modules install"
    
    log_info "Installing kernel..."
    make install | tee -a "$KERNEL_LOG"
    check_status "Kernel install"
    
    log_info "Generating initramfs for new kernel..."
    genkernel --install initramfs --kernel-config=.config --kerneldir="$KERNEL_SRC" 2>&1 | tee -a "$KERNEL_LOG"
    check_status "Initramfs generation"
    
    log_info "Updating GRUB configuration..."
    if [[ -d /boot/grub ]]; then
        # Extract new kernel name from vmlinuz file
        NEW_KERNEL_VERSION=$(basename $(find /boot -name "vmlinuz-*${KERNELS[$KERNEL_IDX]#linux-}*" -type f 2>/dev/null | head -n 1) | sed 's/vmlinuz-//')
        if [[ -n "$NEW_KERNEL_VERSION" ]]; then
            setup_grub_default "$NEW_KERNEL_VERSION"
        else
            log_warn "Could not determine new kernel name for GRUB"
            grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee -a "$KERNEL_LOG"
            check_status "GRUB update"
        fi
    else
        log_warn "/boot/grub directory not found! Configure bootloader manually."
    fi
fi

# -----------------------------
# Step 7: Configure X-server
# -----------------------------
log_info "Configuring X-server..."
setup_x_server

# -----------------------------
# Step 8: Install XFCE/Xorg
# -----------------------------
if [[ "$INSTALL_XFCE" == "y" ]]; then
    log_info "Installing XFCE desktop environment..."
    
    # Switch OpenGL
    if eselect opengl list &>/dev/null; then
        eselect opengl set xorg-x11
        log_info "Switched OpenGL to xorg-x11"
    fi
    
    # Enable LightDM in autostart
    if [[ -f /etc/init.d/lightdm ]]; then
        if ! rc-update show default | grep -q lightdm; then
            rc-update add lightdm default
            check_status "LightDM service activation"
            log_success "LightDM service added to autostart"
        fi
        
        # Configure LightDM
        mkdir -p /etc/lightdm/lightdm.conf.d
        cat > /etc/lightdm/lightdm.conf.d/01-custom.conf << 'EOF'
[LightDM]
minimum-display-server-timeout=10
minimum-vt-timeout=10

[Seat:*]
user-session=xfce
allow-user-switching=true
allow-guest=false
EOF
        
        log_info "Configured LightDM for automatic XFCE start"
    else
        log_warn "LightDM not found! Configure display manager manually."
    fi
    
    # Set graphical runlevel
    if [[ -f /etc/inittab ]]; then
        if ! grep -q "^id:5:initdefault:" /etc/inittab; then
            sed -i 's/^id:[0-9]:initdefault:/id:5:initdefault:/' /etc/inittab
            log_info "Set runlevel 5 (graphical mode) as default"
        fi
    fi
    
    # Configure Xfce autostart
    XFCE_SESSION_FILE="/usr/share/xsessions/xfce.desktop"
    if [[ -f "$XFCE_SESSION_FILE" ]]; then
        sed -i 's|^Exec=.*|Exec=startxfce4|' "$XFCE_SESSION_FILE"
        log_info "Updated XFCE session file"
    fi
    
    # Create .xinitrc for root (if needed)
    echo "exec startxfce4" > /root/.xinitrc
    chmod 755 /root/.xinitrc
    log_info "Created .xinitrc for root"
fi

# -----------------------------
# Step 9: XFS and power management optimizations
# -----------------------------
if [[ "$HDD_OPT" == "y" ]] || [[ "$BUILD_KERNEL" == "y" ]]; then
    log_info "Configuring XFS and power management optimizations..."
    
    # Enable power management services
    for service in laptop-mode cpufreq cpuspeed; do
        if [[ -f "/etc/init.d/$service" ]]; then
            if ! rc-update show default | grep -q "$service"; then
                rc-update add "$service" default
                log_info "Service $service added to autostart"
            fi
        else
            log_warn "Service $service not found"
        fi
    done
    
    # Configure sysctl for XFS
    declare -A sysctl_settings=(
        ["vm.swappiness"]=10
        ["vm.vfs_cache_pressure"]=50
        ["vm.dirty_ratio"]=10
        ["vm.dirty_background_ratio"]=5
        ["vm.dirty_expire_centisecs"]=3000
        ["vm.dirty_writeback_centisecs"]=1000
        ["vm.page-cluster"]=0  # For XFS optimization
    )
    
    for key in "${!sysctl_settings[@]}"; do
        if ! grep -q "^${key}=" /etc/sysctl.conf; then
            echo "${key}=${sysctl_settings[$key]}" >> /etc/sysctl.conf
            log_info "Added ${key}=${sysctl_settings[$key]} to sysctl.conf"
        fi
    done
    
    # Apply settings
    sysctl -p &>/dev/null || true
    log_info "Applied sysctl settings"
    
    # Configure disks for XFS
    if command -v hdparm &>/dev/null; then
        log_info "Configuring disk parameters for XFS..."
        for disk in /dev/sd? /dev/hd? /dev/nvme?n?; do
            if [[ -b "$disk" ]]; then
                # Set APM level for XFS (balance between performance and power)
                hdparm -B 200 "$disk" 2>/dev/null || true
                hdparm -S 0 "$disk" 2>/dev/null || true  # Disable standby for better XFS performance
                log_info "Configured disk: $disk (XFS optimization)"
            fi
        done
    fi
    
    # Configure mount options for XFS (if /etc/fstab contains XFS)
    if grep -q "xfs" /etc/fstab; then
        log_info "Found XFS filesystems in /etc/fstab"
        log_info "Recommended XFS mount options:"
        log_info "  - noatime (for performance)"
        log_info "  - nobarrier (for SSD, be careful!)"
        log_info "  - inode64 (for large filesystems)"
        log_info "Check /etc/fstab and update mount options if needed"
    fi
fi

# -----------------------------
# Completion
# -----------------------------
exec 1>&3 2>&4

echo "=============================================="
log_success "All steps completed successfully!"
echo "Logs:"
echo "- Kernel build: $KERNEL_LOG"
echo "- XFCE installation: $XFCE_LOG"
echo "- Script log: $SCRIPT_LOG"
echo ""
echo "System configuration:"
if [[ "$INSTALL_XFCE" == "y" ]]; then
    echo "- XFCE will start automatically on boot"
    echo "- LightDM display manager is configured and enabled"
    echo "- Graphical mode (runlevel 5) is set as default"
fi
if [[ "$BUILD_KERNEL" == "y" ]]; then
    echo "- New kernel $(basename "$KERNEL_SRC") configured as default boot option"
    echo "- XFS filesystem enabled in kernel"
    echo "- Initramfs generated for new kernel"
fi
echo ""
echo "Next steps:"
echo "1. Reboot your system: reboot"
echo "2. After reboot, you should be greeted with the LightDM login screen"
echo "3. Login and enjoy your XFCE desktop environment"
echo "4. If you encounter any boot issues, select the backup kernel from GRUB menu"
echo "5. Check /etc/fstab for XFS mount options optimization"
echo "=============================================="

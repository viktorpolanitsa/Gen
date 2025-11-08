#!/bin/bash
set -e
# -----------------------------
# Проверка root
# -----------------------------
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run this script as root!"
    exit 1
fi

# -----------------------------
# Проверка необходимых утилит
# -----------------------------
REQUIRED_UTILS=("grep" "awk" "sed" "ls" "cp" "mkdir" "rm" "ln" "make" "grub-mkconfig" "equery")
for util in "${REQUIRED_UTILS[@]}"; do
    if ! command -v "$util" &>/dev/null; then
        echo "[ERROR] Required utility '$util' not found!"
        echo "Please install it first: emerge --ask sys-apps/$(echo $util | sed 's/-/_/g')"
        exit 1
    fi
done

CPU_CORES=$(nproc)
KERNEL_LOG="/var/log/kernel_build_$(date +%F_%H-%M-%S).log"
XFCE_LOG="/var/log/xfce_install_$(date +%F_%H-%M-%S).log"

check_status() {
    if [[ $? -ne 0 ]]; then
        echo "[ERROR] $1 failed! Check logs."
        exit 1
    fi
}

normalize_answer() {
    local answer="$1"
    echo "$answer" | tr '[:upper:]' '[:lower:]' | cut -c1
}

# -----------------------------
# Шаг 1: Выбор ядра
# -----------------------------
echo "Scanning /usr/src for available kernels..."
if [[ ! -d /usr/src ]]; then
    echo "[ERROR] /usr/src directory does not exist!"
    exit 1
fi

# Используем find для более надежного поиска
mapfile -t KERNELS < <(find /usr/src -maxdepth 1 -type d -name "linux-*" -exec basename {} \; 2>/dev/null)
if [[ ${#KERNELS[@]} -eq 0 ]]; then
    echo "[ERROR] No kernel sources found in /usr/src!"
    echo "You may need to install kernel sources first:"
    echo "emerge --ask sys-kernel/gentoo-sources"
    exit 1
fi

echo "Available kernels:"
for idx in "${!KERNELS[@]}"; do
    echo "$idx) ${KERNELS[$idx]}"
done

read -rp "Enter the number of the kernel to use: " KERNEL_IDX
if [[ ! "$KERNEL_IDX" =~ ^[0-9]+$ ]] || [[ "$KERNEL_IDX" -ge ${#KERNELS[@]} ]]; then
    echo "[ERROR] Invalid kernel number selected!"
    exit 1
fi

KERNEL_SRC="/usr/src/${KERNELS[$KERNEL_IDX]}"
if [[ ! -d "$KERNEL_SRC" ]]; then
    echo "[ERROR] Kernel source $KERNEL_SRC not found!"
    exit 1
fi

# -----------------------------
# Шаг 2: Выбор опций установки
# -----------------------------
echo "Configure installation options (y/n):"
read -rp "Backup current kernel? [y/N] " BACKUP_CHOICE
BACKUP_CHOICE=$(normalize_answer "$BACKUP_CHOICE")

read -rp "Build and install kernel? [y/N] " BUILD_KERNEL
BUILD_KERNEL=$(normalize_answer "$BUILD_KERNEL")

read -rp "Install XFCE/Xorg? [y/N] " INSTALL_XFCE
INSTALL_XFCE=$(normalize_answer "$INSTALL_XFCE")

read -rp "Enable CPU optimizations? [y/N] " CPU_OPT
CPU_OPT=$(normalize_answer "$CPU_OPT")

read -rp "Enable GPU optimizations? [y/N] " GPU_OPT
GPU_OPT=$(normalize_answer "$GPU_OPT")

read -rp "Enable HDD/laptop optimizations? [y/N] " HDD_OPT
HDD_OPT=$(normalize_answer "$HDD_OPT")

# -----------------------------
# Шаг 3: Проверка и установка зависимостей
# -----------------------------
check_and_install_package() {
    local package="$1"
    local description="$2"
    
    echo "---------------------------------------------"
    echo "[INFO] Checking package: $package ($description)"
    
    if equery list "$package" &>/dev/null; then
        echo "[INFO] Package $package is already installed."
        return 0
    fi
    
    echo "[INFO] Package $package not found. Searching for it..."
    if emerge --search "$package" | grep -q "^${package}"; then
        echo "[INFO] Installing $package..."
        emerge --verbose --ask=n "$package"
        check_status "Installation of $package"
        return 0
    fi
    
    echo "[WARNING] Package $package not found in repositories!"
    read -rp "Would you like to continue without this package? [y/N] " choice
    choice=$(normalize_answer "$choice")
    if [[ "$choice" != "y" ]]; then
        echo "[ERROR] Required package $package not available!"
        exit 1
    fi
}

echo "Checking and installing dependencies..."

# Основные зависимости
check_and_install_package "sys-kernel/gentoo-sources" "Kernel sources"
check_and_install_package "sys-devel/gcc" "Compiler"
check_and_install_package "app-laptop/laptop-mode-tools" "Power management"
check_and_install_package "x11-base/xorg-drivers" "Graphics drivers"
check_and_install_package "x11-base/xorg-server" "X server"
check_and_install_package "media-libs/mesa" "OpenGL support"
check_and_install_package "app-admin/eselect" "Configuration tool"

# Зависимости XFCE
if [[ "$INSTALL_XFCE" == "y" ]]; then
    check_and_install_package "xfce-base/xfce4-meta" "XFCE desktop environment"
    check_and_install_package "xfce-extra/xfce4-goodies" "XFCE additional apps"
    check_and_install_package "x11-misc/lightdm" "Display manager"
    check_and_install_package "x11-misc/lightdm-gtk-greeter" "LightDM GTK greeter"
fi

# -----------------------------
# Шаг 4: Резервное копирование ядра
# -----------------------------
if [[ "$BACKUP_CHOICE" == "y" ]]; then
    if [[ ! -d /boot ]]; then
        echo "[ERROR] /boot directory does not exist!"
        exit 1
    fi
    
    BACKUP_DIR="/boot/backup_kernel_$(date +%F_%H-%M-%S)"
    mkdir -p "$BACKUP_DIR"
    
    echo "[INFO] Creating backup in $BACKUP_DIR..."
    
    if ls /boot/vmlinuz-* &>/dev/null; then
        cp /boot/vmlinuz-* "$BACKUP_DIR/" 2>/dev/null || echo "[WARNING] Some vmlinuz files could not be backed up"
    else
        echo "[INFO] No vmlinuz files found in /boot"
    fi
    
    if ls /boot/initramfs-* &>/dev/null; then
        cp /boot/initramfs-* "$BACKUP_DIR/" 2>/dev/null || echo "[WARNING] Some initramfs files could not be backed up"
    else
        echo "[INFO] No initramfs files found in /boot"
    fi
    
    echo "[INFO] Backup saved in $BACKUP_DIR"
fi

# -----------------------------
# Шаг 5: Создание симлинка linux
# -----------------------------
cd /usr/src || exit 1
if [[ -L linux || -e linux ]]; then
    echo "[INFO] Removing existing /usr/src/linux symlink"
    rm -f linux
fi
ln -sf "$(basename "$KERNEL_SRC")" linux
echo "[INFO] Created symlink: linux -> $(basename "$KERNEL_SRC")"
cd linux || exit 1

# -----------------------------
# Шаг 6: Конфигурация ядра
# -----------------------------
if [[ "$BUILD_KERNEL" == "y" ]]; then
    echo "Building kernel..."
    
    # Проверка наличия scripts/config
    if [[ -f scripts/config ]]; then
        echo "[INFO] Using scripts/config for kernel configuration"
    else
        echo "[WARNING] scripts/config not found, using make olddefconfig instead"
    fi
    
    make defconfig
    check_status "defconfig"
    
    # Настройка конфигурации только если scripts/config существует
    if [[ -f scripts/config ]]; then
        echo "[INFO] Configuring kernel modules..."
        
        # Основные драйверы
        ./scripts/config --enable BLK_DEV_SD 2>/dev/null || true
        ./scripts/config --enable ATA 2>/dev/null || true
        ./scripts/config --enable SCSI_MOD 2>/dev/null || true
        ./scripts/config --enable AHCI 2>/dev/null || true
        ./scripts/config --enable EXT4_FS 2>/dev/null || true
        ./scripts/config --enable EXT2_FS 2>/dev/null || true
        ./scripts/config --enable XFS_FS 2>/dev/null || true
        ./scripts/config --enable XFS_QUOTA 2>/dev/null || true
        ./scripts/config --enable USB 2>/dev/null || true
        ./scripts/config --enable USB_EHCI_HCD 2>/dev/null || true
        ./scripts/config --enable USB_UHCI_HCD 2>/dev/null || true
        ./scripts/config --enable USB_OHCI_HCD 2>/dev/null || true
        ./scripts/config --enable USB_XHCI_HCD 2>/dev/null || true
        ./scripts/config --enable USB_STORAGE 2>/dev/null || true
        ./scripts/config --disable MODULE_SIG 2>/dev/null || true
        ./scripts/config --disable MODULE_SIG_ALL 2>/dev/null || true
        ./scripts/config --disable MODULE_SIG_HASH 2>/dev/null || true
        
        # Оптимизации CPU
        if [[ "$CPU_OPT" == "y" ]]; then
            echo "[INFO] Enabling CPU optimizations..."
            ./scripts/config --enable CPU_FREQ 2>/dev/null || true
            ./scripts/config --enable CPU_FREQ_GOV_ONDEMAND 2>/dev/null || true
            ./scripts/config --enable CPU_FREQ_STAT 2>/dev/null || true
            ./scripts/config --enable CPU_IDLE 2>/dev/null || true
        fi
        
        # Оптимизации GPU
        if [[ "$GPU_OPT" == "y" ]]; then
            echo "[INFO] Enabling GPU optimizations..."
            ./scripts/config --enable DRM 2>/dev/null || true
            ./scripts/config --enable DRM_RADEON 2>/dev/null || true
            ./scripts/config --enable DRM_KMS_HELPER 2>/dev/null || true
            ./scripts/config --enable RADEON_DPM 2>/dev/null || true
            
            echo "options radeon dpm=1" > /etc/modprobe.d/radeon.conf
            echo "[INFO] Created /etc/modprobe.d/radeon.conf for Radeon DPM"
        fi
        
        make olddefconfig
        check_status "olddefconfig"
    fi
    
    echo "[INFO] Building kernel with ${CPU_CORES} cores..."
    make -j"$CPU_CORES" V=1 | tee "$KERNEL_LOG"
    check_status "Kernel build"
    
    echo "[INFO] Installing kernel modules..."
    make modules_install | tee -a "$KERNEL_LOG"
    check_status "Modules install"
    
    echo "[INFO] Installing kernel..."
    make install | tee -a "$KERNEL_LOG"
    check_status "Kernel install"
    
    echo "Updating GRUB..."
    if [[ -d /boot/grub ]]; then
        grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee -a "$KERNEL_LOG"
        check_status "GRUB update"
    else
        echo "[WARNING] /boot/grub directory not found! Please configure bootloader manually."
    fi
fi

# -----------------------------
# Шаг 7: Установка XFCE/Xorg
# -----------------------------
if [[ "$INSTALL_XFCE" == "y" ]]; then
    echo "Installing XFCE desktop environment..."
    
    XFCE_PACKAGES=(
        "xfce-base/xfce4-meta"
        "xfce-extra/xfce4-goodies"
        "x11-misc/lightdm"
        "x11-misc/lightdm-gtk-greeter"
        "x11-base/xorg-server"
        "x11-apps/xorg-apps"
        "x11-drivers/xf86-video-fbdev"
        "media-libs/mesa"
    )
    
    for pkg in "${XFCE_PACKAGES[@]}"; do
        if ! equery list "$pkg" &>/dev/null; then
            emerge --verbose --ask=n "$pkg" 2>&1 | tee -a "$XFCE_LOG"
            check_status "Installation of $pkg"
        fi
    done
    
    echo "[INFO] Configuring LightDM..."
    if ! rc-update show default | grep -q lightdm; then
        rc-update add lightdm default
        check_status "LightDM service activation"
    fi
    
    mkdir -p /etc/lightdm/lightdm.conf.d
    echo '[LightDM]' > /etc/lightdm/lightdm.conf.d/timeout.conf
    echo 'minimum-display-server-timeout=10' >> /etc/lightdm/lightdm.conf.d/timeout.conf
    
    echo "[INFO] Setting XFCE as default session..."
    echo "exec startxfce4" > /etc/lightdm/Xsession
    chmod +x /etc/lightdm/Xsession
fi

# -----------------------------
# Шаг 8: Оптимизация энергопотребления
# -----------------------------
if [[ "$HDD_OPT" == "y" ]]; then
    echo "[INFO] Configuring power management optimizations..."
    
    if ! rc-update show default | grep -q laptop-mode; then
        rc-update add laptop-mode default
        echo "[INFO] Added laptop-mode to default runlevel"
    fi
    
    if ! rc-update show default | grep -q cpufreq; then
        rc-update add cpufreq default
        echo "[INFO] Added cpufreq to default runlevel"
    fi
    
    # Проверяем, нет ли уже таких строк в sysctl.conf
    if ! grep -q "vm.swappiness=10" /etc/sysctl.conf; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
        echo "[INFO] Added vm.swappiness=10 to sysctl.conf"
    fi
    
    if ! grep -q "vm.vfs_cache_pressure=50" /etc/sysctl.conf; then
        echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
        echo "[INFO] Added vm.vfs_cache_pressure=50 to sysctl.conf"
    fi
    
    sysctl -p &>/dev/null
    echo "[INFO] Applied sysctl settings"
fi

# -----------------------------
# Завершение
# -----------------------------
echo "=============================================="
echo "All steps completed successfully!"
echo "Logs:"
echo "- Kernel build: $KERNEL_LOG"
echo "- XFCE installation: $XFCE_LOG"
echo ""
echo "Next steps:"
echo "1. Reboot your system: reboot"
echo "2. After reboot, login and start XFCE with: startx (if LightDM doesn't start automatically)"
echo "3. Configure your system further as needed"
echo "=============================================="FO] Configuring LightDM..."
    if ! rc-update show default | grep -q lightdm; then
        rc-update add lightdm default
        check_status "LightDM service activation"
    fi
    
    echo '[LightDM]'
    echo 'minimum-display-server-timeout=10' > /etc/lightdm/lightdm.conf.d/timeout.conf
    
    echo "[INFO] Setting XFCE as default session..."
    echo "exec startxfce4" > /etc/lightdm/Xsession
fi

# -----------------------------
# Шаг 8: Оптимизация энергопотребления
# -----------------------------
if [[ "$HDD_OPT" == "y" ]]; then
    echo "[INFO] Configuring power management optimizations..."
    
    if ! rc-update show default | grep -q laptop-mode; then
        rc-update add laptop-mode default
    fi
    
    if ! rc-update show default | grep -q cpufreq; then
        rc-update add cpufreq default
    fi
    
    # Проверяем, нет ли уже таких строк в sysctl.conf
    if ! grep -q "vm.swappiness=10" /etc/sysctl.conf; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi
    
    if ! grep -q "vm.vfs_cache_pressure=50" /etc/sysctl.conf; then
        echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
    fi
    
    sysctl -p &>/dev/null
fi

# -----------------------------
# Завершение
# -----------------------------
echo "=============================================="
echo "All steps completed successfully!"
echo "Logs:"
echo "- Kernel build: $KERNEL_LOG"
echo "- XFCE installation: $XFCE_LOG"
echo ""
echo "Next steps:"
echo "1. Reboot your system: reboot"
echo "2. After reboot, login and start XFCE with: startx (if LightDM doesn't start automatically)"
echo "3. Configure your system further as needed"
echo "=============================================="

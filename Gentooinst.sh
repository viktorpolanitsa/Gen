#!/bin/bash
set -e

# -----------------------------
# Проверка root
# -----------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root!"
    exit 1
fi

CPU_CORES=$(nproc)
KERNEL_LOG="/var/log/kernel_build_$(date +%F_%H-%M-%S).log"
XFCE_LOG="/var/log/xfce_install_$(date +%F_%H-%M-%S).log"

check_status() {
    if [[ $? -ne 0 ]]; then
        echo "[ERROR] $1 failed! Check logs."
        exit 1
    fi
}

# -----------------------------
# Шаг 1: Выбор ядра
# -----------------------------
echo "Scanning /usr/src for available kernels..."
KERNELS=($(ls -d /usr/src/linux-* | sed 's|/usr/src/||'))
if [[ ${#KERNELS[@]} -eq 0 ]]; then
    echo "[ERROR] No kernel sources found in /usr/src!"
    exit 1
fi

echo "Available kernels:"
for idx in "${!KERNELS[@]}"; do
    echo "$idx) ${KERNELS[$idx]}"
done
read -rp "Enter the number of the kernel to use: " KERNEL_IDX
KERNEL_SRC="/usr/src/${KERNELS[$KERNEL_IDX]}"
if [[ ! -d "$KERNEL_SRC" ]]; then
    echo "[ERROR] Kernel source $KERNEL_SRC not found!"
    exit 1
fi

# -----------------------------
# Шаг 2: Выбор опций установки
# -----------------------------
echo "Configure installation options (y/n):"
read -rp "Backup current kernel? " BACKUP_CHOICE
read -rp "Build and install kernel? " BUILD_KERNEL
read -rp "Install XFCE/Xorg? " INSTALL_XFCE
read -rp "Enable CPU optimizations? " CPU_OPT
read -rp "Enable GPU optimizations? " GPU_OPT
read -rp "Enable HDD/laptop optimizations? " HDD_OPT

# -----------------------------
# Шаг 3: Интерактивная установка зависимостей
# -----------------------------
DEPENDENCIES=(
    "sys-kernel/gentoo-sources"
    "sys-devel/make"
    "sys-devel/gcc"
    "sys-power/laptop-mode-tools"
    "x11-base/xorg-drivers"
    "x11-base/xorg-server"
    "x11-misc/mesa"
    "app-admin/eselect"
    "xfce4"
    "xfce4-goodies"
    "lightdm"
    "lightdm-gtk-greeter"
)

echo "Installing dependencies..."
for pkg in "${DEPENDENCIES[@]}"; do
    echo "---------------------------------------------"
    echo "[INFO] Checking package: $pkg"

    FOUND=$(eix -qe "$pkg" 2>/dev/null | head -n1)

    if [[ -z "$FOUND" ]]; then
        echo "[WARNING] Exact package $pkg not found. Searching for alternatives..."
        SEARCH_RESULTS=($(emerge --search "$pkg" | grep "^\s*[a-z0-9]" | awk '{print $1}'))

        if [[ ${#SEARCH_RESULTS[@]} -eq 0 ]]; then
            echo "[ERROR] No suitable package found for $pkg!"
            exit 1
        fi

        echo "Available alternatives:"
        for i in "${!SEARCH_RESULTS[@]}"; do
            echo "$i) ${SEARCH_RESULTS[$i]}"
        done

        read -rp "Enter the number of the package to install (default 0): " CHOICE
        if [[ -z "$CHOICE" ]]; then
            CHOICE=0
        fi
        FOUND="${SEARCH_RESULTS[$CHOICE]}"
        echo "[INFO] Selected package: $FOUND"
    fi

    if ! equery list "$FOUND" &>/dev/null; then
        echo "[INFO] Installing $FOUND..."
        emerge --verbose "$FOUND"
        check_status "Installation of $FOUND"
    else
        echo "[INFO] Package $FOUND is already installed."
    fi
done

# -----------------------------
# Шаг 4: Резервное копирование ядра
# -----------------------------
if [[ "$BACKUP_CHOICE" == "y" ]]; then
    BACKUP_DIR="/boot/backup_kernel_$(date +%F_%H-%M-%S)"
    mkdir -p "$BACKUP_DIR"
    cp /boot/vmlinuz-* "$BACKUP_DIR/" || true
    cp /boot/initramfs-* "$BACKUP_DIR/" || true
    echo "[INFO] Backup saved in $BACKUP_DIR"
fi

# -----------------------------
# Шаг 5: Создание симлинка linux
# -----------------------------
cd /usr/src
if [[ -L linux || -e linux ]]; then
    rm -f linux
fi
ln -s "$KERNEL_SRC" linux
cd linux

# -----------------------------
# Шаг 6: Конфигурация ядра
# -----------------------------
if [[ "$BUILD_KERNEL" == "y" ]]; then
    echo "Building kernel..."
    make defconfig
    check_status "defconfig"

    scripts/config --enable BLK_DEV_SD
    scripts/config --enable ATA
    scripts/config --enable SCSI_MOD
    scripts/config --enable AHCI
    scripts/config --enable EXT4_FS
    scripts/config --enable EXT2_FS
    scripts/config --enable XFS_FS
    scripts/config --enable XFS_QUOTA
    scripts/config --enable USB
    scripts/config --enable USB_EHCI_HCD
    scripts/config --enable USB_UHCI_HCD
    scripts/config --enable USB_OHCI_HCD
    scripts/config --enable USB_XHCI_HCD
    scripts/config --enable USB_STORAGE
    scripts/config --disable MODULE_SIG
    scripts/config --disable MODULE_SIG_ALL
    scripts/config --disable MODULE_SIG_HASH

    if [[ "$CPU_OPT" == "y" ]]; then
        scripts/config --enable CPU_FREQ
        scripts/config --enable CPU_FREQ_GOV_ONDEMAND
        scripts/config --enable CPU_FREQ_STAT
        scripts/config --enable CPU_IDLE
    fi

    if [[ "$GPU_OPT" == "y" ]]; then
        scripts/config --enable DRM
        scripts/config --enable DRM_RADEON
        scripts/config --enable DRM_KMS_HELPER
        scripts/config --enable RADEON_DPM
        echo "options radeon dpm=1" > /etc/modprobe.d/radeon.conf
    fi

    make olddefconfig
    check_status "olddefconfig"

    make -j"$CPU_CORES" V=1 | tee "$KERNEL_LOG"
    check_status "Kernel build"

    make modules_install | tee -a "$KERNEL_LOG"
    check_status "Modules install"

    make install | tee -a "$KERNEL_LOG"
    check_status "Kernel install"

    echo "Updating GRUB..."
    grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee -a "$KERNEL_LOG"
    check_status "GRUB update"
fi

# -----------------------------
# Шаг 7: Установка XFCE/Xorg
# -----------------------------
if [[ "$INSTALL_XFCE" == "y" ]]; then
    XFCE_PACKAGES="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter xorg-server xorg-apps xorg-drivers mesa"
    emerge --verbose $XFCE_PACKAGES 2>&1 | tee "$XFCE_LOG"
    rc-update add lightdm default
fi

# -----------------------------
# Шаг 8: Оптимизация энергопотребления
# -----------------------------
if [[ "$HDD_OPT" == "y" ]]; then
    rc-update add laptop-mode default
    rc-update add cpufreq default
    echo "vm.swappiness=10" >> /etc/sysctl.conf
    echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
fi

echo "All steps completed successfully! Reboot to use the new kernel and environment."
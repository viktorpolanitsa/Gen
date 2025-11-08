#!/bin/bash
set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# -----------------------------
# Функции вывода
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
# Проверка root
# -----------------------------
if [[ $EUID -ne 0 ]]; then
    log_error "Запустите скрипт от имени root!"
    exit 1
fi

# -----------------------------
# Проверка необходимых утилит
# -----------------------------
REQUIRED_UTILS=("equery" "grep" "awk" "sed" "ls" "cp" "mkdir" "rm" "ln" "make" "grub-mkconfig" "find" "genkernel" "emerge" "eselect" "xfs_info" "xfs_repair" "xfs_admin" "lspci" "xauth")
MISSING_UTILS=()

for util in "${REQUIRED_UTILS[@]}"; do
    if ! command -v "$util" &>/dev/null; then
        MISSING_UTILS+=("$util")
    fi
done

if [[ ${#MISSING_UTILS[@]} -gt 0 ]]; then
    log_error "Отсутствуют необходимые утилиты: ${MISSING_UTILS[*]}"
    log_info "Установите их: emerge --ask sys-fs/xfsprogs для XFS инструментов"
    exit 1
fi

CPU_CORES=$(nproc --all)
CPU_CORES=${CPU_CORES:-$(getconf _NPROCESSORS_ONLN)}
CPU_CORES=${CPU_CORES:-4}  # Резервное значение

# Логи
KERNEL_LOG="/var/log/kernel_build_$(date +%Y%m%d_%H%M%S).log"
XFCE_LOG="/var/log/xfce_install_$(date +%Y%m%d_%H%M%S).log"
SCRIPT_LOG="/var/log/xfce_kernel_setup_$(date +%Y%m%d_%H%M%S).log"

exec 3>&1 4>&2
exec 1> >(tee -a "$SCRIPT_LOG")
exec 2> >(tee -a "$SCRIPT_LOG" >&2)

# -----------------------------
# Функции проверки статуса
# -----------------------------
check_status() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "$1 (код ошибки: $exit_code)"
        exit $exit_code
    fi
}

normalize_answer() {
    local answer="$1"
    echo "$answer" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -c1
}

# -----------------------------
# Функция проверки и установки пакетов
# -----------------------------
check_and_install_package() {
    local package="$1"
    local description="$2"
    local use_flags="$3"
    
    log_info "Проверка пакета: $package ($description)"
    
    if equery list "$package" &>/dev/null; then
        log_info "Пакет $package уже установлен."
        return 0
    fi
    
    log_info "Пакет $package не найден. Поиск..."
    
    if emerge --search "$package" | grep -q "^${package}[[:space:]]"; then
        log_info "Установка $package..."
        if [[ -n "$use_flags" ]]; then
            emerge --verbose --ask=n --autounmask-write=y "$package" || true
            etc-update --automode -5
            emerge --verbose --ask=n $use_flags "$package"
        else
            emerge --verbose --ask=n "$package"
        fi
        check_status "Установка $package"
        return 0
    fi
    
    log_warn "Пакет $package не найден в репозиториях!"
    read -rp "Продолжить без этого пакета? [y/N] " choice
    choice=$(normalize_answer "$choice")
    if [[ "$choice" != "y" ]]; then
        log_error "Необходимый пакет $package недоступен!"
        exit 1
    fi
}

# -----------------------------
# Проверка XFS файловой системы
# -----------------------------
check_xfs_filesystem() {
    log_info "Проверка XFS файловой системы..."
    
    # Проверка смонтированных XFS файловых систем
    if mount | grep -q xfs; then
        log_info "Обнаружены XFS файловые системы:"
        mount | grep xfs | while read -r line; do
            echo "  $line"
        done
    else
        log_warn "XFS файловые системы не обнаружены в /proc/mounts"
    fi
    
    # Проверка XFS утилит
    if command -v xfs_info &>/dev/null; then
        log_info "XFS инструменты установлены"
    else
        log_error "XFS инструменты не установлены!"
        check_and_install_package "sys-fs/xfsprogs" "XFS инструменты"
    fi
}

# -----------------------------
# Функция для настройки GRUB с выбором нового ядра по умолчанию
# -----------------------------
setup_grub_default() {
    local new_kernel_name="$1"
    log_info "Настройка GRUB для выбора нового ядра $new_kernel_name по умолчанию..."
    
    # Обновление конфигурации GRUB
    grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee -a "$KERNEL_LOG"
    check_status "Обновление GRUB"
    
    # Поиск номера меню для нового ядра
    if grep -q "menuentry.*$new_kernel_name" /boot/grub/grub.cfg; then
        log_info "Установка нового ядра как опции загрузки по умолчанию..."
        # Получение номера меню для нового ядра
        MENU_ENTRY=$(grep -n "menuentry.*$new_kernel_name" /boot/grub/grub.cfg | head -1 | cut -d: -f1)
        if [[ -n "$MENU_ENTRY" ]]; then
            sed -i "s/GRUB_DEFAULT=.*/GRUB_DEFAULT=$((MENU_ENTRY-1))/" /etc/default/grub
            log_info "Обновлена опция загрузки по умолчанию в /etc/default/grub"
            
            # Повторное обновление GRUB с новыми настройками
            grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee -a "$KERNEL_LOG"
            check_status "Повторное обновление GRUB"
            log_success "Новое ядро $new_kernel_name установлено как загрузка по умолчанию"
        else
            log_warn "Не удалось определить номер меню для $new_kernel_name"
        fi
    else
        log_warn "Ядро $new_kernel_name не найдено в конфигурации GRUB"
        log_info "Доступные ядра в GRUB:"
        grep -E "menuentry.*linux" /boot/grub/grub.cfg | sed 's/^.*menuentry //;s/ {.*$//'
    fi
}

# -----------------------------
# Функция для настройки X-сервера
# -----------------------------
setup_x_server() {
    log_info "Настройка X-сервера..."
    
    # Исправление прав доступа к .Xauthority
    if [[ -f ~/.Xauthority ]]; then
        chmod 600 ~/.Xauthority
    else
        touch ~/.Xauthority
        chmod 600 ~/.Xauthority
    fi
    
    # Проверка видеокарты и установка соответствующего драйвера
    if command -v lspci &>/dev/null; then
        VIDEO_CHIP=$(lspci | grep -E "VGA|3D" | head -n 1)
        log_info "Обнаружено видеоустройство: $VIDEO_CHIP"
        
        if echo "$VIDEO_CHIP" | grep -qi "intel"; then
            DRIVER="xf86-video-intel"
        elif echo "$VIDEO_CHIP" | grep -qi "amd\|radeon\|ati"; then
            DRIVER="xf86-video-amdgpu"
        elif echo "$VIDEO_CHIP" | grep -qi "nvidia\|nouveau"; then
            DRIVER="xf86-video-nouveau"
        else
            DRIVER="xf86-video-vesa"
        fi
        
        log_info "Установка драйвера: $DRIVER"
        check_and_install_package "x11-drivers/$DRIVER" "X-сервер драйвер"
        
        # Убедимся, что OpenGL установлен правильно
        if eselect opengl list &>/dev/null; then
            eselect opengl set xorg-x11
            log_info "OpenGL установлен как xorg-x11"
        fi
    else
        log_warn "lspci не найден, невозможно определить видеоустройство"
        # Установим vesa драйвер как резервный вариант
        check_and_install_package "x11-drivers/xf86-video-vesa" "X-сервер VESA драйвер"
    fi
    
    # Удаление старой конфигурации X-сервера
    if [[ -f /etc/X11/xorg.conf ]]; then
        mv /etc/X11/xorg.conf /etc/X11/xorg.conf.backup_$(date +%Y%m%d_%H%M%S)
        log_info "Старая конфигурация X-сервера перемещена в резервную копию"
    fi
    
    log_success "X-сервер настроен"
}

# -----------------------------
# Шаг 1: Выбор ядра
# -----------------------------
log_info "Сканирование /usr/src на наличие доступных ядер..."
if [[ ! -d /usr/src ]]; then
    log_error "/usr/src директория не существует!"
    exit 1
fi

mapfile -t KERNELS < <(find /usr/src -maxdepth 1 -type d -name "linux-*" -exec basename {} \; 2>/dev/null | sort -V)
if [[ ${#KERNELS[@]} -eq 0 ]]; then
    log_error "Исходные коды ядра не найдены в /usr/src!"
    log_info "Установите сначала исходные коды ядра:"
    log_info "emerge --ask sys-kernel/gentoo-sources"
    exit 1
fi

log_info "Доступные ядра:"
for idx in "${!KERNELS[@]}"; do
    echo "$idx) ${KERNELS[$idx]}"
done

while true; do
    read -rp "Введите номер ядра для использования: " KERNEL_IDX
    if [[ "$KERNEL_IDX" =~ ^[0-9]+$ ]] && [[ "$KERNEL_IDX" -ge 0 ]] && [[ "$KERNEL_IDX" -lt ${#KERNELS[@]} ]]; then
        break
    else
        log_error "Неверный номер ядра!"
    fi
done

KERNEL_SRC="/usr/src/${KERNELS[$KERNEL_IDX]}"
if [[ ! -d "$KERNEL_SRC" ]]; then
    log_error "Исходные коды ядра $KERNEL_SRC не найдены!"
    exit 1
fi

# -----------------------------
# Шаг 2: Выбор опций установки
# -----------------------------
echo "---------------------------------------------"
echo "Настройка параметров установки (y/n):"
read -rp "Резервное копирование текущего ядра? [Y/n] " BACKUP_CHOICE
BACKUP_CHOICE=$(normalize_answer "$BACKUP_CHOICE")
[[ -z "$BACKUP_CHOICE" ]] && BACKUP_CHOICE="y"

read -rp "Сборка и установка ядра? [Y/n] " BUILD_KERNEL
BUILD_KERNEL=$(normalize_answer "$BUILD_KERNEL")
[[ -z "$BUILD_KERNEL" ]] && BUILD_KERNEL="y"

read -rp "Установка XFCE/Xorg? [Y/n] " INSTALL_XFCE
INSTALL_XFCE=$(normalize_answer "$INSTALL_XFCE")
[[ -z "$INSTALL_XFCE" ]] && INSTALL_XFCE="y"

read -rp "Включить оптимизации CPU? [Y/n] " CPU_OPT
CPU_OPT=$(normalize_answer "$CPU_OPT")
[[ -z "$CPU_OPT" ]] && CPU_OPT="y"

read -rp "Включить оптимизации GPU? [Y/n] " GPU_OPT
GPU_OPT=$(normalize_answer "$GPU_OPT")
[[ -z "$GPU_OPT" ]] && GPU_OPT="y"

read -rp "Включить оптимизации HDD/ноутбука? [Y/n] " HDD_OPT
HDD_OPT=$(normalize_answer "$HDD_OPT")
[[ -z "$HDD_OPT" ]] && HDD_OPT="y"

# -----------------------------
# Шаг 3: Проверка XFS и установка зависимостей
# -----------------------------
check_xfs_filesystem

log_info "Проверка и установка зависимостей..."

# Проверка и установка базовых зависимостей
check_and_install_package "sys-kernel/linux-firmware" "Firmware для оборудования"
check_and_install_package "sys-devel/gcc" "Компилятор"
check_and_install_package "app-misc/pciutils" "Утилиты PCI"
check_and_install_package "app-misc/usbutils" "Утилиты USB"
check_and_install_package "sys-fs/xfsprogs" "XFS инструменты" "sys-fs/xfsprogs[X]"

if [[ "$BUILD_KERNEL" == "y" ]]; then
    check_and_install_package "sys-kernel/genkernel" "Генерация initramfs"
    check_and_install_package "sys-kernel/installkernel" "Установка ядра"
fi

if [[ "$INSTALL_XFCE" == "y" ]]; then
    check_and_install_package "x11-base/xorg-server" "X сервер"
    check_and_install_package "x11-base/xorg-drivers" "Графические драйверы"
    check_and_install_package "media-libs/mesa" "Поддержка OpenGL"
    check_and_install_package "app-admin/eselect-opengl" "Переключение OpenGL"
    check_and_install_package "xfce-base/xfce4-meta" "XFCE среда рабочего стола"
    check_and_install_package "xfce-extra/xfce4-goodies" "XFCE дополнительные приложения"
    check_and_install_package "x11-misc/lightdm" "Менеджер входа"
    check_and_install_package "x11-misc/lightdm-gtk-greeter" "GTK приветствие LightDM"
fi

if [[ "$HDD_OPT" == "y" ]]; then
    check_and_install_package "app-laptop/laptop-mode-tools" "Управление питанием"
fi

# -----------------------------
# Шаг 4: Резервное копирование ядра
# -----------------------------
if [[ "$BACKUP_CHOICE" == "y" ]]; then
    if [[ ! -d /boot ]]; then
        log_error "/boot директория не существует!"
        exit 1
    fi
    
    BACKUP_DIR="/boot/backup_kernel_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    log_info "Создание резервной копии в $BACKUP_DIR..."
    
    # Резервное копирование файлов ядра
    for kernel_file in /boot/vmlinuz-*; do
        if [[ -f "$kernel_file" ]]; then
            cp "$kernel_file" "$BACKUP_DIR/" 2>/dev/null
            log_info "Скопирован файл ядра: $(basename "$kernel_file")"
        fi
    done
    
    # Резервное копирование initramfs
    for initramfs_file in /boot/initramfs-*; do
        if [[ -f "$initramfs_file" ]]; then
            cp "$initramfs_file" "$BACKUP_DIR/" 2>/dev/null
            log_info "Скопирован initramfs: $(basename "$initramfs_file")"
        fi
    done
    
    # Резервное копирование конфигурации ядра
    for config_file in /boot/config-*; do
        if [[ -f "$config_file" ]]; then
            cp "$config_file" "$BACKUP_DIR/" 2>/dev/null
            log_info "Скопирована конфигурация: $(basename "$config_file")"
        fi
    done
    
    # Резервное копирование System.map
    for system_map in /boot/System.map-*; do
        if [[ -f "$system_map" ]]; then
            cp "$system_map" "$BACKUP_DIR/" 2>/dev/null
            log_info "Скопирован System.map: $(basename "$system_map")"
        fi
    done
fi

# -----------------------------
# Шаг 5: Создание символической ссылки linux
# -----------------------------
cd /usr/src || exit 1
if [[ -L linux ]]; then
    log_info "Удаление существующей символической ссылки /usr/src/linux"
    rm -f linux
elif [[ -d linux ]]; then
    log_warn "Каталог /usr/src/linux существует, но не является символической ссылкой"
    mv linux linux.backup_$(date +%Y%m%d_%H%M%S)
    log_info "Резервное копирование старого каталога"
fi

ln -sf "$(basename "$KERNEL_SRC")" linux
log_info "Создана символическая ссылка: linux -> $(basename "$KERNEL_SRC")"

cd linux || exit 1

# -----------------------------
# Шаг 6: Конфигурация ядра с XFS поддержкой
# -----------------------------
if [[ "$BUILD_KERNEL" == "y" ]]; then
    log_info "Конфигурация ядра..."
    
    # Проверка наличия конфигурации
    if [[ -f "/etc/kernels/kernel-config-$(uname -r)" ]]; then
        log_info "Использование существующей конфигурации ядра"
        cp "/etc/kernels/kernel-config-$(uname -r)" .config
    elif [[ -f "/proc/config.gz" ]]; then
        log_info "Использование конфигурации текущего ядра"
        zcat /proc/config.gz > .config
    else
        log_info "Создание базовой конфигурации"
        make defconfig
        check_status "defconfig"
    fi
    
    # Проверка наличия scripts/config
    if [[ -f scripts/config ]]; then
        log_info "Использование scripts/config для настройки ядра"
        
        # Основные драйверы
        ./scripts/config --enable BLK_DEV_SD || true
        ./scripts/config --enable ATA || true
        ./scripts/config --enable SCSI_MOD || true
        ./scripts/config --enable AHCI || true
        
        # XFS файловая система - обязательно включить
        ./scripts/config --enable XFS_FS || true
        ./scripts/config --enable XFS_QUOTA || true
        ./scripts/config --enable XFS_POSIX_ACL || true
        ./scripts/config --enable XFS_RT || true
        ./scripts/config --enable XFS_ONLINE_SCRUB || true
        ./scripts/config --enable XFS_ONLINE_REPAIR || true
        
        # EXT4 для совместимости
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
        
        # Оптимизации CPU
        if [[ "$CPU_OPT" == "y" ]]; then
            log_info "Включение оптимизаций CPU..."
            ./scripts/config --enable CPU_FREQ || true
            ./scripts/config --enable CPU_FREQ_GOV_ONDEMAND || true
            ./scripts/config --enable CPU_FREQ_GOV_CONSERVATIVE || true
            ./scripts/config --enable CPU_FREQ_STAT || true
            ./scripts/config --enable CPU_IDLE || true
            ./scripts/config --enable SCHED_MC || true
            ./scripts/config --enable SCHED_SMT || true
        fi
        
        # Оптимизации GPU
        if [[ "$GPU_OPT" == "y" ]]; then
            log_info "Включение оптимизаций GPU..."
            ./scripts/config --enable DRM || true
            ./scripts/config --enable DRM_KMS_HELPER || true
            ./scripts/config --enable DRM_TTM || true
            
            # Radeon
            ./scripts/config --enable DRM_RADEON || true
            ./scripts/config --enable RADEON_DPM || true
            
            # Intel
            ./scripts/config --enable DRM_I915 || true
            ./scripts/config --enable DRM_I915_KMS || true
            
            # NVIDIA (если доступно)
            ./scripts/config --enable DRM_NOUVEAU || true
            
            # Установка параметров модуля
            mkdir -p /etc/modprobe.d
            if lsmod | grep -q radeon; then
                echo "options radeon dpm=1" > /etc/modprobe.d/radeon.conf
                log_info "Создан /etc/modprobe.d/radeon.conf для Radeon DPM"
            elif lsmod | grep -q i915; then
                echo "options i915 enable_fbc=1 enable_psr=1" > /etc/modprobe.d/i915.conf
                log_info "Создан /etc/modprobe.d/i915.conf для Intel GPU"
            fi
        fi
        
        make olddefconfig
        check_status "olddefconfig"
    else
        log_warn "scripts/config не найден, использование make olddefconfig"
        make olddefconfig
        check_status "olddefconfig"
    fi
    
    log_info "Сборка ядра с ${CPU_CORES} ядрами..."
    make -j"$CPU_CORES" V=1 | tee "$KERNEL_LOG"
    check_status "Сборка ядра"
    
    log_info "Установка модулей ядра..."
    make modules_install | tee -a "$KERNEL_LOG"
    check_status "Установка модулей"
    
    log_info "Установка ядра..."
    make install | tee -a "$KERNEL_LOG"
    check_status "Установка ядра"
    
    log_info "Генерация initramfs для нового ядра..."
    genkernel --install initramfs --kernel-config=.config --kerneldir="$KERNEL_SRC" 2>&1 | tee -a "$KERNEL_LOG"
    check_status "Генерация initramfs"
    
    log_info "Обновление конфигурации GRUB..."
    if [[ -d /boot/grub ]]; then
        # Извлечение имени нового ядра из vmlinuz файла
        NEW_KERNEL_VERSION=$(basename $(find /boot -name "vmlinuz-*${KERNELS[$KERNEL_IDX]#linux-}*" -type f 2>/dev/null | head -n 1) | sed 's/vmlinuz-//')
        if [[ -n "$NEW_KERNEL_VERSION" ]]; then
            setup_grub_default "$NEW_KERNEL_VERSION"
        else
            log_warn "Не удалось определить имя нового ядра для GRUB"
            grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | tee -a "$KERNEL_LOG"
            check_status "Обновление GRUB"
        fi
    else
        log_warn "/boot/grub директория не найдена! Настройте загрузчик вручную."
    fi
fi

# -----------------------------
# Шаг 7: Настройка X-сервера
# -----------------------------
log_info "Настройка X-сервера..."
setup_x_server

# -----------------------------
# Шаг 8: Установка XFCE/Xorg
# -----------------------------
if [[ "$INSTALL_XFCE" == "y" ]]; then
    log_info "Установка среды рабочего стола XFCE..."
    
    # Переключение OpenGL
    if eselect opengl list &>/dev/null; then
        eselect opengl set xorg-x11
        log_info "Переключен OpenGL на xorg-x11"
    fi
    
    # Включение LightDM в автозагрузку
    if [[ -f /etc/init.d/lightdm ]]; then
        if ! rc-update show default | grep -q lightdm; then
            rc-update add lightdm default
            check_status "Активация службы LightDM"
            log_success "Служба LightDM добавлена в автозагрузку"
        fi
        
        # Настройка LightDM
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
        
        log_info "Настроен LightDM для автоматического запуска XFCE"
    else
        log_warn "LightDM не найден! Настройте менеджер дисплея вручную."
    fi
    
    # Установка графического уровня запуска
    if [[ -f /etc/inittab ]]; then
        if ! grep -q "^id:5:initdefault:" /etc/inittab; then
            sed -i 's/^id:[0-9]:initdefault:/id:5:initdefault:/' /etc/inittab
            log_info "Установлен уровень запуска 5 (графический режим)"
        fi
    fi
    
    # Настройка Xfce для автозапуска
    XFCE_SESSION_FILE="/usr/share/xsessions/xfce.desktop"
    if [[ -f "$XFCE_SESSION_FILE" ]]; then
        sed -i 's|^Exec=.*|Exec=startxfce4|' "$XFCE_SESSION_FILE"
        log_info "Обновлен файл сессии XFCE"
    fi
    
    # Создание .xinitrc для root (если нужно)
    echo "exec startxfce4" > /root/.xinitrc
    chmod 755 /root/.xinitrc
    log_info "Создан .xinitrc для root"
fi

# -----------------------------
# Шаг 9: Оптимизация для XFS и энергопотребления
# -----------------------------
if [[ "$HDD_OPT" == "y" ]] || [[ "$BUILD_KERNEL" == "y" ]]; then
    log_info "Настройка оптимизаций для XFS и управления питанием..."
    
    # Включение служб управления питанием
    for service in laptop-mode cpufreq cpuspeed; do
        if [[ -f "/etc/init.d/$service" ]]; then
            if ! rc-update show default | grep -q "$service"; then
                rc-update add "$service" default
                log_info "Служба $service добавлена в автозагрузку"
            fi
        else
            log_warn "Служба $service не найдена"
        fi
    done
    
    # Настройка sysctl для XFS
    declare -A sysctl_settings=(
        ["vm.swappiness"]=10
        ["vm.vfs_cache_pressure"]=50
        ["vm.dirty_ratio"]=10
        ["vm.dirty_background_ratio"]=5
        ["vm.dirty_expire_centisecs"]=3000
        ["vm.dirty_writeback_centisecs"]=1000
        ["vm.page-cluster"]=0  # Для XFS оптимизации
    )
    
    for key in "${!sysctl_settings[@]}"; do
        if ! grep -q "^${key}=" /etc/sysctl.conf; then
            echo "${key}=${sysctl_settings[$key]}" >> /etc/sysctl.conf
            log_info "Добавлено ${key}=${sysctl_settings[$key]} в sysctl.conf"
        fi
    done
    
    # Применение настроек
    sysctl -p &>/dev/null || true
    log_info "Применены настройки sysctl"
    
    # Настройка дисков для XFS
    if command -v hdparm &>/dev/null; then
        log_info "Настройка параметров диска для XFS..."
        for disk in /dev/sd? /dev/hd? /dev/nvme?n?; do
            if [[ -b "$disk" ]]; then
                # Установка APM уровня для XFS (баланс между производительностью и энергопотреблением)
                hdparm -B 200 "$disk" 2>/dev/null || true
                hdparm -S 0 "$disk" 2>/dev/null || true  # Отключить автостандбай для лучшей производительности XFS
                log_info "Настроен параметр диска: $disk (оптимизация для XFS)"
            fi
        done
    fi
    
    # Настройка mount options для XFS (если /etc/fstab содержит XFS)
    if grep -q "xfs" /etc/fstab; then
        log_info "Обнаружены XFS файловые системы в /etc/fstab"
        log_info "Рекомендуемые опции монтирования XFS:"
        log_info "  - noatime (для производительности)"
        log_info "  - nobarrier (для SSD, осторожно!)"
        log_info "  - inode64 (для больших файловых систем)"
        log_info "Проверьте /etc/fstab и при необходимости обновите опции монтирования"
    fi
fi

# -----------------------------
# Завершение
# -----------------------------
exec 1>&3 2>&4

echo "=============================================="
log_success "Все шаги успешно завершены!"
echo "Логи:"
echo "- Сборка ядра: $KERNEL_LOG"
echo "- Установка XFCE: $XFCE_LOG"
echo "- Лог скрипта: $SCRIPT_LOG"
echo ""
echo "Конфигурация системы:"
if [[ "$INSTALL_XFCE" == "y" ]]; then
    echo "- XFCE будет запускаться автоматически при загрузке"
    echo "- Менеджер дисплея LightDM настроен и включен"
    echo "- Графический режим (уровень 5) установлен как режим по умолчанию"
fi
if [[ "$BUILD_KERNEL" == "y" ]]; then
    echo "- Новое ядро $(basename "$KERNEL_SRC") настроено как опция загрузки по умолчанию"
    echo "- XFS файловая система включена в ядро"
    echo "- Initramfs сгенерирован для нового ядра"
fi
echo ""
echo "Следующие шаги:"
echo "1. Перезагрузите систему: reboot"
echo "2. После перезагрузки вас должен встретить экран входа LightDM"
echo "3. Войдите в систему и наслаждайтесь средой рабочего стола XFCE"
echo "4. В случае проблем с загрузкой выберите резервное ядро из меню GRUB"
echo "5. Проверьте /etc/fstab для оптимизации XFS опций монтирования"
echo "=============================================="

#!/bin/bash
set -e -o pipefail

LOG_FILE="/var/log/autotoo_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[$(date)] Starting Gentoo XFCE installation"

# Проверка прав суперпользователя
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root!" >&2
    exit 1
fi

# Функции для обработки ошибок
check_error() {
    if [ $? -ne 0 ]; then
        echo "[$(date)] ERROR: $1 failed!" >&2
        exit 1
    fi
}

# Автоопределение оборудования
detect_hardware() {
    # Определение типа диска
    DISK_TYPE="hdd"  # По умолчанию для вашего случая
    if grep -q "SSD" /sys/block/$(basename $disk)/device/model 2>/dev/null; then
        DISK_TYPE="ssd"
    fi
    
    # Определение видеокарты для AMD A10-9600P Radeon R5
    VIDEO_CARDS="amdgpu radeon"
    INPUT_DEVICES="libinput evdev"
    
    echo "Hardware detected:"
    echo "- Disk type: $DISK_TYPE"
    echo "- Video cards: $VIDEO_CARDS"
    echo "- Input devices: $INPUT_DEVICES"
}

# Основной процесс установки
main() {
    # Запрос имени диска с проверкой
    while true; do
        echo ""
        echo "Available disks:"
        lsblk -d -o NAME,SIZE,MODEL
        echo ""
        read -p "Enter disk name (e.g., /dev/sda): " disk
        
        if [[ ! "$disk" =~ ^/dev/[a-z]+[0-9]*$ ]]; then
            echo "Invalid disk name format!" >&2
            continue
        fi
        
        if [ ! -b "$disk" ]; then
            echo "Disk $disk does not exist!" >&2
            continue
        fi
        
        echo "WARNING: All data on $disk will be erased!"
        read -p "Continue? (y/n): " confirm
        if [[ "$confirm" == "y" ]]; then
            break
        fi
    done
    
    detect_hardware
    
    # Разметка диска
    echo "[$(date)] Partitioning disk $disk"
    sfdisk "$disk" << DISKEOF
label: gpt
unit: sectors
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
DISKEOF
    check_error "disk partitioning"
    
    # Форматирование
    echo "[$(date)] Formatting partitions"
    mkfs.vfat -F 32 "${disk}1"
    mkfs.xfs "${disk}2"
    check_error "filesystem creation"
    
    # Монтирование
    echo "[$(date)] Mounting filesystems"
    mkdir -p /mnt/gentoo
    mount "${disk}2" /mnt/gentoo
    mkdir -p /mnt/gentoo/efi
    mount "${disk}1" /mnt/gentoo/efi
    check_error "mounting filesystems"
    
    # Загрузка stage3
    echo "[$(date)] Downloading stage3 archive"
    cd /mnt/gentoo
    STAGE3_URL=$(curl -s https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | grep -v '^#' | head -1 | awk '{print $1}')
    wget "https://distfiles.gentoo.org/releases/amd64/autobuilds/$STAGE3_URL"
    check_error "stage3 download"
    
    STAGE3_FILE=$(basename "$STAGE3_URL")
    tar xpvf "$STAGE3_FILE" --xattrs-include='*.*' --numeric-owner
    check_error "stage3 extraction"
    
    # Настройка make.conf
    echo "[$(date)] Configuring make.conf"
    cat > /mnt/gentoo/etc/portage/make.conf << MAKECONF
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C target-cpu=native"
MAKEOPTS="-j$(nproc)"
USE="dist-kernel X gtk pulseaudio alsa opengl dri udev"
VIDEO_CARDS="$VIDEO_CARDS"
INPUT_DEVICES="$INPUT_DEVICES"
CPU_FLAGS_X86="aes avx avx2 fma3 mmx mmxext pclmul popcnt sse sse2 sse3 sse4_1 sse4_2 ssse3"
MAKECONF
    
    # Копирование resolv.conf
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
    
    # Монтирование системных директорий
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    mount --bind /run /mnt/gentoo/run
    mount --make-slave /mnt/gentoo/run
    
    # Создание chroot скрипта
    cat > /mnt/gentoo/tmp/chroot.sh << CHROOTEOF
#!/bin/bash
set -e -o pipefail

# Монтирование EFI
mount "$disk"1 /efi

# Синхронизация портежей
emerge-webrsync

# Выбор профиля
eselect profile set default/linux/amd64/17.1/desktop
source /etc/profile

# Генерация CPU flags
emerge -1q app-portage/cpuid2cpuflags
cpuid2cpuflags > /tmp/cpuflags
echo "*/* \$(cat /tmp/cpuflags)" > /etc/portage/package.use/00cpu-flags

# Настройка локалей
echo -e "en_US.UTF-8 UTF-8\nC.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
cat > /etc/env.d/02locale << LOCALEEOF
LANG="en_US.UTF-8"
LC_COLLATE="C.UTF-8"
LOCALEEOF
source /etc/profile
env-update

# Установка ядра
emerge -q sys-kernel/gentoo-kernel-bin

# Генерация fstab
emerge -q sys-fs/genfstab
genfstab -U / > /etc/fstab

# Настройка сети
echo "gentoo" > /etc/hostname
emerge -q net-misc/dhcpcd
rc-update add dhcpcd default

# Установка базовых сервисов
emerge -q app-admin/sysklogd
rc-update add sysklogd default
emerge -q sys-process/cronie
rc-update add cronie default
emerge -q sys-apps/mlocate
emerge -q net-misc/openssh
rc-update add sshd default
emerge -q app-shells/bash-completion
emerge -q net-misc/chrony
rc-update add chronyd default

# Установка Xorg и драйверов
echo "x11-base/xorg-server glamor" > /etc/portage/package.use/xorg
emerge -q x11-base/xorg-server
emerge -q x11-drivers/xf86-video-amdgpu
emerge -q x11-drivers/xf86-input-libinput

# Установка XFCE
emerge -q xfce-base/xfce4-meta
emerge -q xfce-base/xfce4-goodies
emerge -q x11-misc/lightdm
emerge -q x11-misc/lightdm-gtk-greeter

# Дополнительные приложения XFCE
emerge -q app-editors/mousepad
emerge -q media-gfx/ristretto
emerge -q xfce-extra/xfce4-whiskermenu-plugin
emerge -q xfce-extra/xfce4-battery-plugin
emerge -q xfce-extra/xfce4-clipman-plugin

# Настройка автозапуска
rc-update add lightdm default
rc-update add dbus default
rc-update add elogind default

# Настройка LightDM
sed -i 's/^#autologin-user=.*/autologin-user=/' /etc/lightdm/lightdm.conf
sed -i 's/^#autologin-session=.*/autologin-session=xfce/' /etc/lightdm/lightdev.conf 2>/dev/null || true

# Создание пользователя
echo "Creating user account"
read -p "Username: " username
useradd -m -G users,wheel,audio,video,plugdev,input -s /bin/bash \$username
echo "Set password for \$username:"
passwd \$username

# Настройка sudo
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Установка GRUB
echo 'GRUB_PLATFORMS="efi-64"' >> /etc/portage/make.conf
emerge -q sys-boot/grub
grub-install --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

# Обновление системы
emerge -q --update --deep --with-bdeps=y --newuse @world
emerge -q --depclean

echo "Installation completed successfully!"
CHROOTEOF

    chmod +x /mnt/gentoo/tmp/chroot.sh
    
    # Запуск chroot
    echo "[$(date)] Starting chroot installation"
    chroot /mnt/gentoo /bin/bash -c "source /etc/profile && /tmp/chroot.sh"
    check_error "chroot installation"
    
    # Очистка
    rm /mnt/gentoo/tmp/chroot.sh
    
    echo "[$(date)] Installation complete! System will reboot in 10 seconds."
    sleep 10
    reboot
}

# Запуск основной функции
main

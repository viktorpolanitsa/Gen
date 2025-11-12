#!/bin/bash

# Немедленно выходить, если команда завершается с ошибкой.
set -e

echo "---= Autotoo: The Wise Gentoo Installer =---"
echo "Этот скрипт сотрет ВСЕ ДАННЫЕ на выбранном диске."
echo "Убедись, что ты выбрал правильный диск."
echo ""

# --- Сбор информации от пользователя ---

# Выбор диска
lsblk -dno NAME,SIZE,MODEL
echo ""
read -p "Введи имя диска для установки (например, sda или nvme0n1): " disk
disk="/dev/${disk}"

# Выбор графического окружения (DE)
echo "Выбери графическое окружение для установки:"
options=("GNOME" "KDE Plasma" "XFCE" "Выход")
select de_choice in "${options[@]}"; do
    case $de_choice in
        "GNOME") break;;
        "KDE Plasma") break;;
        "XFCE") break;;
        "Выход") exit;;
        *) echo "Неверный выбор. Попробуй еще раз.";;
    esac
done

read -p "Введи имя хоста (имя компьютера): " hostname
read -p "Введи имя для нового пользователя: " username

# Ввод паролей (скрытый)
while true; do
    read -sp "Введи пароль для root: " root_password
    echo
    read -sp "Повтори пароль для root: " root_password2
    echo
    [ "$root_password" = "$root_password2" ] && break
    echo "Пароли не совпадают. Попробуй еще раз."
done

while true; do
    read -sp "Введи пароль для пользователя $username: " user_password
    echo
    read -sp "Повтори паро-ль для пользователя $username: " user_password2
    echo
    [ "$user_password" = "$user_password2" ] && break
    echo "Пароли не совпадают. Попробуй еще раз."
done

echo ""
echo "---= Конфигурация установки =---"
echo "Диск: $disk"
echo "Окружение: $de_choice"
echo "Имя хоста: $hostname"
echo "Пользователь: $username"
echo "---------------------------------"
echo "Нажми Enter для начала установки или Ctrl+C для отмены."
read

# --- Фаза 1: Подготовка системы ---

echo "--> Разметка диска $disk..."
sfdisk "$disk" << DISKEOF
label: gpt
unit: sectors
,1M,U
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
DISKEOF

echo "--> Форматирование разделов..."
mkfs.vfat -F 32 "${disk}1"
mkfs.xfs "${disk}2"

echo "--> Монтирование файловых систем..."
mkdir -p /mnt/gentoo
mount "${disk}2" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${disk}1" /mnt/gentoo/efi

cd /mnt/gentoo

echo "--> Загрузка последнего архива Stage3..."
STAGE3_PATH=$(wget -q -O - https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | grep -v "^#" | cut -d' ' -f1)
wget "https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_PATH}"

echo "--> Распаковка Stage3..."
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner

echo "--> Генерация make.conf..."
# Установка переменных для DE
case $de_choice in
    "GNOME")
        DE_USE_FLAGS="gtk gnome -qt5 -kde"
        DE_PROFILE="default/linux/amd64/17.1/desktop/gnome"
        ;;
    "KDE Plasma")
        DE_USE_FLAGS="qt5 plasma kde -gtk -gnome"
        DE_PROFILE="default/linux/amd64/17.1/desktop/plasma"
        ;;
    "XFCE")
        DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome"
        DE_PROFILE="default/linux/amd64/17.1/desktop" # XFCE хорошо работает с базовым desktop профилем
        ;;
esac

cat > /mnt/gentoo/etc/portage/make.conf << MAKECONF
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C target-cpu=native"
MAKEOPTS="-j$(nproc)"

# Настройки для выбранного DE
USE="${DE_USE_FLAGS} dbus elogind pulseaudio"

# Лицензии
ACCEPT_LICENSE="@FREE"

# Настройки для видео и устройств ввода
VIDEO_CARDS="amdgpu intel nouveau" # Добавь nvidia, если нужно
INPUT_DEVICES="libinput"

# Включаем поддержку GRUB для EFI
GRUB_PLATFORMS="efi-64"
MAKECONF

echo "--> Подготовка окружения chroot..."
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

echo "--> Генерация скрипта для chroot..."
cat > /mnt/gentoo/tmp/chroot.sh << CHROOTEOF
set -e
source /etc/profile

echo "--> Синхронизация Portage..."
emerge-webrsync

echo "--> Выбор профиля: ${DE_PROFILE}"
eselect profile set ${DE_PROFILE}

echo "--> Обновление мира с новыми USE-флагами..."
emerge --verbose --update --deep --newuse @world

echo "--> Настройка флагов процессора..."
emerge -q app-portage/cpuid2cpuflags
echo "*/* \$(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

echo "--> Настройка локалей..."
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8
env-update && source /etc/profile

echo "--> Установка бинарного ядра..."
echo "sys-kernel/installkernel grub dracut" > /etc/portage/package.use/installkernel
emerge -q sys-kernel/gentoo-kernel-bin

echo "--> Генерация fstab..."
emerge -q sys-fs/genfstab
genfstab -U / > /etc/fstab

echo "--> Настройка имени хоста..."
echo "${hostname}" > /etc/hostname

echo "--> Установка пароля root..."
echo "root:${root_password}" | chpasswd

echo "--> Установка базовых системных утилит..."
emerge -q app-admin/sysklogd net-misc/chrony sys-process/cronie app-shells/bash-completion sys-apps/mlocate
rc-update add sysklogd default
rc-update add chronyd default
rc-update add cronie default

echo "--> Установка и настройка сети..."
emerge -q net-misc/networkmanager
rc-update add NetworkManager default

echo "--> Установка и настройка SSH..."
rc-update add sshd default

echo "--> Установка графической подсистемы..."
emerge -q x11-base/xorg-server

# Установка DE
case "${de_choice}" in
    "GNOME")
        echo "--> Установка GNOME..."
        emerge -q gnome-shell/gnome
        rc-update add gdm default
        ;;
    "KDE Plasma")
        echo "--> Установка KDE Plasma..."
        emerge -q kde-plasma/plasma-meta
        rc-update add sddm default
        ;;
    "XFCE")
        echo "--> Установка XFCE..."
        emerge -q xfce-base/xfce4-meta x11-terms/xfce4-terminal sys-boot/sddm
        rc-update add sddm default
        ;;
esac

echo "--> Создание пользователя ${username}..."
useradd -m -G users,wheel,audio,video -s /bin/bash ${username}
echo "${username}:${user_password}" | chpasswd

echo "--> Установка и настройка загрузчика GRUB..."
emerge -q sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

echo "--> Установка завершена внутри chroot."
exit
CHROOTEOF

chmod +x /mnt/gentoo/tmp/chroot.sh

echo "--- Фаза 2: Вход в chroot и установка системы ---"
chroot /mnt/gentoo /tmp/chroot.sh
rm /mnt/gentoo/tmp/chroot.sh

echo "--- Установка завершена! ---"
echo "--> Размонтирование файловых систем..."
umount -l /mnt/gentoo/dev{/shm,/pts,}
umount -R /mnt/gentoo

echo "Система готова к перезагрузке. Введи 'reboot' для входа в твою новую Gentoo."
echo "Нажми Ctrl+C, если хочешь остаться в LiveCD."

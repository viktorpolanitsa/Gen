#!/bin/bash
set -e

########################
# 1️⃣ Настройка ядра
########################
cd /usr/src
rm -f linux
ln -s linux-6.12.54-gentoo linux
cd linux

# Дефолтный конфиг
make defconfig

# Включаем ключевые драйверы
# SATA, AHCI, диски
scripts/config --enable BLK_DEV_SD
scripts/config --enable ATA
scripts/config --enable SCSI_MOD
scripts/config --enable AHCI

# Файловые системы
scripts/config --enable EXT4_FS
scripts/config --enable EXT2_FS
scripts/config --enable XFS_FS
scripts/config --enable XFS_QUOTA

# USB
scripts/config --enable USB
scripts/config --enable USB_EHCI_HCD
scripts/config --enable USB_UHCI_HCD
scripts/config --enable USB_OHCI_HCD
scripts/config --enable USB_XHCI_HCD
scripts/config --enable USB_STORAGE

# Radeon и DRM
scripts/config --enable DRM
scripts/config --enable DRM_RADEON
scripts/config --enable DRM_KMS_HELPER

# Отключаем подпись модулей
scripts/config --disable MODULE_SIG
scripts/config --disable MODULE_SIG_ALL
scripts/config --disable MODULE_SIG_HASH

# Обновляем зависимости
make olddefconfig

# Сборка ядра и модулей
make -j$(nproc) 2>&1 | tee /tmp/kernel-build.log
make modules_install

# Установка ядра и обновление GRUB
make install
grub-mkconfig -o /boot/grub/grub.cfg

echo "✅ Ядро собрано и установлено."

########################
# 2️⃣ Установка XFCE и LightDM
########################
emerge --ask xfce4 xfce4-meta xfce4-goodies lightdm lightdm-gtk-greeter x11-base/xorg-drivers x11-base/xorg-server dbus elogind

# Добавляем службы в OpenRC
rc-update add dbus default
rc-update add elogind default
rc-update add lightdm default

echo "✅ XFCE и LightDM установлены. Пользователь будет вводить логин и пароль при входе."
echo "🎉 Всё готово! Перезагрузите систему, чтобы загрузиться в новое ядро и XFCE."
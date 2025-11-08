#!/bin/bash
set -e

# 1️⃣ Переходим в /usr/src
cd /usr/src

# 2️⃣ Проверяем, есть ли уже симлинк 'linux' и удаляем, если есть
if [ -L linux ] || [ -e linux ]; then
    echo "Симлинк 'linux' уже существует. Удаляем..."
    rm -f linux
fi

# 3️⃣ Создаём новый симлинк на нужное ядро
ln -s linux-6.12.54-gentoo linux
echo "Симлинк 'linux' создан -> linux-6.12.54-gentoo"

# 4️⃣ Переходим в исходники через симлинк
cd linux

# 5️⃣ Дефолтный конфиг
make defconfig

# 6️⃣ Включаем ключевые драйверы (пример)
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

scripts/config --enable DRM
scripts/config --enable DRM_RADEON
scripts/config --enable DRM_KMS_HELPER

scripts/config --disable MODULE_SIG
scripts/config --disable MODULE_SIG_ALL
scripts/config --disable MODULE_SIG_HASH

# 7️⃣ Обновляем зависимости
make olddefconfig

echo "✅ Конфигурация ядра готова. Далее запускайте сборку:"
echo "make -j\$(nproc) && make modules_install && make install"
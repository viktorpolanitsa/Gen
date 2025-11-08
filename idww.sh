#!/bin/bash
set -euo pipefail

# -------------------------------
# Функция логирования
# -------------------------------
log() { echo -e "\n>>> $*"; }

# Проверка на root
if [[ $EUID -ne 0 ]]; then
  echo "Запусти скрипт от root (sudo)." >&2
  exit 1
fi

# -------------------------------
# 1️⃣ Выбираем ядро
# -------------------------------
log "Ищем доступные ядра в /usr/src..."
cd /usr/src
mapfile -t kernels < <(ls -1d linux-*-gentoo* 2>/dev/null || true)
if [[ ${#kernels[@]} -eq 0 ]]; then
  echo "Не найдено linux-*-gentoo. Установи sys-kernel/gentoo-sources." >&2
  exit 1
fi

chosen=""
for k in "${kernels[@]}"; do
  if [[ "$k" != *"-gentoo-dist" ]]; then
    chosen="$k"
    break
  fi
done
if [[ -z "$chosen" ]]; then chosen="${kernels[0]}"; fi
log "Выбрано ядро: $chosen"

rm -f /usr/src/linux
ln -s "$chosen" /usr/src/linux
log "/usr/src/linux -> $chosen"

# Перемонтируем rw, если read-only
mount -o remount,rw /usr/src 2>/dev/null || mount -o remount,rw / 2>/dev/null || true

cd /usr/src/linux

# -------------------------------
# 2️⃣ Создаём .config
# -------------------------------
if [[ ! -f .config ]]; then
  if [[ -f /boot/config-$(uname -r) ]]; then
    cp /boot/config-$(uname -r) .config
    log "Скопирован старый конфиг ядра"
  else
    make defconfig
    log "Создан дефолтный конфиг ядра"
  fi
fi

# -------------------------------
# 3️⃣ Отключаем подпись модулей
# -------------------------------
log "Отключаем подпись модулей..."
scripts/config --disable MODULE_SIG
scripts/config --disable MODULE_SIG_ALL
scripts/config --disable MODULE_SIG_HASH
make olddefconfig

# -------------------------------
# 4️⃣ Включаем USB и Radeon
# -------------------------------
log "Включаем USB и драйвер Radeon..."
scripts/config --enable DRM
scripts/config --enable DRM_RADEON
scripts/config --enable DRM_RADEON_KMS

scripts/config --enable USB
scripts/config --enable USB_EHCI_HCD
scripts/config --enable USB_UHCI_HCD
scripts/config --enable USB_OHCI_HCD
scripts/config --enable USB_XHCI_HCD
scripts/config --enable USB_STORAGE

make olddefconfig

# -------------------------------
# 5️⃣ Сборка ядра
# -------------------------------
log "Сборка ядра (на HDD это может занять 20-40 минут)..."
make -j$(nproc) 2>&1 | tee /tmp/kernel-build.log
make modules_install
make install

# -------------------------------
# 6️⃣ Обновляем GRUB
# -------------------------------
if command -v grub-mkconfig >/dev/null 2>&1; then
  log "Обновляем GRUB..."
  grub-mkconfig -o /boot/grub/grub.cfg
fi

# -------------------------------
# 7️⃣ Установка Xorg, XFCE, LightDM
# -------------------------------
log "Устанавливаем Xorg, XFCE и LightDM..."
emerge --quiet --ask x11-base/xorg-drivers x11-base/xorg-server \
       xfce4 xfce4-meta xfce4-goodies \
       lightdm lightdm-gtk-greeter dbus elogind

# -------------------------------
# 8️⃣ Настройка OpenRC
# -------------------------------
log "Добавляем службы в default runlevel..."
rc-update add dbus default
rc-update add elogind default
rc-update add lightdm default

# -------------------------------
# 9️⃣ Настройка автологина LightDM
# -------------------------------
log "Настраиваем LightDM для автологина (замени 'viktor' на своего пользователя)..."
mkdir -p /etc/lightdm/lightdm.conf.d
tee /etc/lightdm/lightdm.conf.d/50-autologin.conf > /dev/null <<EOF
[Seat:*]
autologin-user=viktor
autologin-user-timeout=0
user-session=xfce
greeter-session=lightdm-gtk-greeter
EOF

# -------------------------------
log "Готово! Перезагрузи систему:"
echo "sudo reboot"
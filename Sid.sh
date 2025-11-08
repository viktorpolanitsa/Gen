#!/bin/bash
set -euo pipefail

log() { echo -e "\n>>> $*"; }

if [[ $EUID -ne 0 ]]; then
  echo "Запусти скрипт от root (sudo)." >&2
  exit 1
fi

# -------------------------------
# 1) Подготовка исходников ядра
# -------------------------------
log "Сканируем /usr/src на доступные ядра..."
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

# Перемонтируем /usr/src rw если нужно
mnt_opts=$(findmnt -n -o OPTIONS --target /usr/src 2>/dev/null || true)
if [[ "$mnt_opts" == *ro* ]]; then
  log "Перемонтируем /usr/src в rw..."
  mount -o remount,rw /usr/src 2>/dev/null || mount -o remount,rw / 2>/dev/null || {
    echo "Не удалось перемонтировать. Сделай вручную." >&2
    exit 1
  }
fi

cd /usr/src/linux
log "Текущая директория: $(pwd)"

# -------------------------------
# 2) Конфиг ядра
# -------------------------------
log "Подготовка .config..."
if [[ ! -f .config ]]; then
  if [[ -f /boot/config-$(uname -r) ]]; then
    cp /boot/config-$(uname -r) .config
  else
    make defconfig
  fi
fi

log "Отключаем подпись модулей..."
sed -i 's/^CONFIG_MODULE_SIG=.*/# CONFIG_MODULE_SIG is not set/' .config || true
sed -i 's/^CONFIG_MODULE_SIG_ALL=.*/# CONFIG_MODULE_SIG_ALL is not set/' .config || true
sed -i 's/^CONFIG_MODULE_SIG_HASH=.*/# CONFIG_MODULE_SIG_HASH is not set/' .config || true
grep -q '^# CONFIG_MODULE_SIG is not set' .config || echo '# CONFIG_MODULE_SIG is not set' >> .config
grep -q '^# CONFIG_MODULE_SIG_ALL is not set' .config || echo '# CONFIG_MODULE_SIG_ALL is not set' >> .config

mkdir -p certs
if [[ ! -f certs/signing_key.pem ]]; then
  openssl req -new -x509 -newkey rsa:2048 -keyout certs/signing_key.pem \
    -out certs/signing_key.pem -days 36500 -nodes -subj "/CN=Gentoo Dummy Kernel Key/" >/dev/null 2>&1
  chmod 600 certs/signing_key.pem
  log "Dummy ключ создан."
fi

make olddefconfig

# -------------------------------
# 3) Сборка и установка ядра
# -------------------------------
log "Сборка ядра (занимает ~20–40 минут на HDD)..."
make -j"$(nproc)" 2>&1 | tee /tmp/kernel-build.log

log "Установка модулей и ядра..."
make modules_install
make install

if command -v grub-mkconfig >/dev/null 2>&1; then
  log "Обновляем GRUB..."
  grub-mkconfig -o /boot/grub/grub.cfg
fi

# -------------------------------
# 4) Драйвер Radeon
# -------------------------------
if command -v emerge >/dev/null 2>&1; then
  log "Пересборка x11-drivers/xf86-video-ati..."
  emerge --quiet --oneshot x11-drivers/xf86-video-ati || log "emerge завершился с ошибкой"
fi

# -------------------------------
# 5) XFCE и LightDM
# -------------------------------
log "Устанавливаем XFCE и LightDM + Xorg + dbus + elogind..."
emerge --ask xfce4 xfce4-meta xfce4-goodies lightdm lightdm-gtk-greeter x11-base/xorg-drivers x11-base/xorg-server dbus elogind

# -------------------------------
# 6) OpenRC автозапуск
# -------------------------------
log "Включаем службы OpenRC..."
rc-update add dbus default
rc-update add elogind default
rc-update add lightdm default

# -------------------------------
# 7) Настройка LightDM для автологина в XFCE
# -------------------------------
sudo mkdir -p /etc/lightdm/lightdm.conf.d
sudo tee /etc/lightdm/lightdm.conf.d/50-autologin.conf > /dev/null <<'EOF'
[Seat:*]
autologin-user=viktor
autologin-user-timeout=0
user-session=xfce
greeter-session=lightdm-gtk-greeter
EOF

log "Настройка автологина завершена!"

# -------------------------------
log "Готово! Перезагрузи систему и Gentoo автоматически загрузится в XFCE."
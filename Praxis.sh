#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# --- Root check ---
[[ $EUID -eq 0 ]] || { echo "Скрипт должен запускаться от root!"; exit 1; }

cd /

echo "---= Autotoo: Advanced Gentoo Installer =---"
echo "Внимание! Скрипт сотрёт все данные на выбранном диске."

# --- Disk selection ---
lsblk -dno NAME,SIZE,MODEL
read -rp "Введите имя диска для установки (например, sda или nvme0n1): " disk_input
disk="/dev/${disk_input}"

# --- Init system selection ---
INIT_OPTIONS=("OpenRC" "Systemd" "Exit")
echo "Выберите init систему:"
select init_choice in "${INIT_OPTIONS[@]}"; do
    case $init_choice in
        "OpenRC"|"Systemd") break;;
        "Exit") exit;;
        *) echo "Неверный выбор. Попробуйте снова.";;
    esac
done

# --- Desktop Environments ---
DE_OPTIONS=("GNOME" "KDE Plasma" "XFCE" "LXQt" "MATE" "Cinnamon" "Minimal" "Exit")
echo "Выберите Desktop Environment:"
select de_choice in "${DE_OPTIONS[@]}"; do
    [[ " ${DE_OPTIONS[*]} " == *" $de_choice "* ]] || { echo "Неверный выбор."; continue; }
    [[ $de_choice == "Exit" ]] && exit
    break
done

# --- Display Manager ---
DM_OPTIONS=("GDM" "SDDM" "LightDM" "LXDM" "None")
echo "Выберите Display Manager:"
select dm_choice in "${DM_OPTIONS[@]}"; do
    [[ " ${DM_OPTIONS[*]} " == *" $dm_choice "* ]] || { echo "Неверный выбор."; continue; }
    break
done

# --- Kernel selection ---
KERNEL_OPTIONS=("Gentoo Binary Kernel" "Custom Source Kernel")
echo "Выберите ядро Linux:"
select kernel_choice in "${KERNEL_OPTIONS[@]}"; do
    [[ " ${KERNEL_OPTIONS[*]} " == *" $kernel_choice "* ]] || { echo "Неверный выбор."; continue; }
    break
done

# --- Audio ---
AUDIO_OPTIONS=("Pulseaudio" "PipeWire" "None")
echo "Выберите аудио систему:"
select audio_choice in "${AUDIO_OPTIONS[@]}"; do
    [[ " ${AUDIO_OPTIONS[*]} " == *" $audio_choice "* ]] || { echo "Неверный выбор."; continue; }
    break
done

# --- Browser ---
BROWSER_OPTIONS=("Firefox" "Chromium" "None")
echo "Выберите браузер:"
select browser_choice in "${BROWSER_OPTIONS[@]}"; do
    [[ " ${BROWSER_OPTIONS[*]} " == *" $browser_choice "* ]] || { echo "Неверный выбор."; continue; }
    break
done

# --- Hostname and user ---
read -rp "Введите hostname: " hostname
read -rp "Введите имя пользователя: " username

# --- Passwords ---
while true; do
    read -rsp "Пароль root: " root_password; echo
    read -rsp "Подтвердите пароль root: " root_password2; echo
    [[ "$root_password" == "$root_password2" ]] && break
    echo "Пароли не совпадают."
done

while true; do
    read -rsp "Пароль пользователя $username: " user_password; echo
    read -rsp "Подтвердите пароль пользователя $username: " user_password2; echo
    [[ "$user_password" == "$user_password2" ]] && break
    echo "Пароли не совпадают."
done

echo "--- Конфигурация ---"
echo "Disk: $disk, DE: $de_choice, DM: $dm_choice, Kernel: $kernel_choice"
echo "Audio: $audio_choice, Browser: $browser_choice, Init: $init_choice"
echo "Hostname: $hostname, User: $username"
read -rp "Нажмите Enter для начала установки."

# --- Disk preparation ---
swapoff -a || true
umount -R /mnt/gentoo || true
umount -R "${disk}"* || true
blockdev --flushbufs "$disk" || true
sleep 2

sfdisk --wipe always --wipe-partitions always "$disk" << DISKDEF
label: gpt
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
DISKDEF

partprobe "$disk"
sleep 1
wipefs -a "${disk}1"
wipefs -a "${disk}2"
mkfs.vfat -F32 "${disk}1"
mkfs.xfs -f "${disk}2"
mkdir -p /mnt/gentoo/efi
mount "${disk}2" /mnt/gentoo
mount "${disk}1" /mnt/gentoo/efi
cd /mnt/gentoo

# --- Stage3 download ---
STAGE3_URL=$(wget -qO- https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | grep -v '^#' | grep stage3 | head -n1 | awk '{print $1}')
wget -O stage3.tar.xz "https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_URL}"
tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner

# --- make.conf ---
DE_USE_FLAGS=""
case $de_choice in
    "GNOME") DE_USE_FLAGS="gtk gnome -qt5 -kde";;
    "KDE Plasma") DE_USE_FLAGS="qt5 plasma kde -gtk -gnome";;
    "XFCE") DE_USE_FLAGS="gtk xfce -qt5 -kde -gnome";;
    "LXQt") DE_USE_FLAGS="lxqt qt5 -gtk -gnome";;
    "MATE") DE_USE_FLAGS="mate -qt5 -kde";;
    "Cinnamon") DE_USE_FLAGS="cinnamon gtk -qt5 -kde";;
    "Minimal") DE_USE_FLAGS="";;
esac

AUDIO_USE=""
case $audio_choice in
    "Pulseaudio") AUDIO_USE="pulseaudio";;
    "PipeWire") AUDIO_USE="pipewire";;
esac

USE_FLAGS="$DE_USE_FLAGS $AUDIO_USE"

cat > /mnt/gentoo/etc/portage/make.conf << MAKECONF
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C target-cpu=native"
MAKEOPTS="-j\$(nproc)"
USE="$USE_FLAGS dbus elogind"
ACCEPT_LICENSE="@FREE"
VIDEO_CARDS="amdgpu intel nouveau"
INPUT_DEVICES="libinput"
GRUB_PLATFORMS="efi-64"
MAKECONF

# --- Chroot preparation ---
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# --- Chroot script ---
cat > /mnt/gentoo/tmp/chroot.sh << 'CHROOTEOF'
#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
LOG_FILE=/tmp/autotoo_chroot.log
exec > >(tee -a "$LOG_FILE") 2>&1

healing_emerge() {
    local args=("$@")
    local retries=5
    local attempt=1
    while [[ $attempt -le $retries ]]; do
        echo "--> Попытка emerge $attempt/$retries: ${args[*]}"
        if emerge --verbose "${args[@]}" &> /tmp/emerge_run.log; then
            cat /tmp/emerge_run.log
            return 0
        fi
        cat /tmp/emerge_run.log
        attempt=$((attempt+1))
    done
    return 1
}

emerge-webrsync

# --- DE profile selection ---
case "${de_choice}" in
    "GNOME") DE_PROFILE=$(eselect profile list | grep 'desktop/gnome' | grep 'merged-usr' | grep -v 'systemd' | awk '{print $2}' | tail -n1);;
    "KDE Plasma") DE_PROFILE=$(eselect profile list | grep 'desktop/plasma' | grep 'merged-usr' | grep -v 'systemd' | awk '{print $2}' | tail -n1);;
    "XFCE") DE_PROFILE=$(eselect profile list | grep 'desktop' | grep 'merged-usr' | grep -v 'gnome' | grep -v 'plasma' | grep -v 'systemd' | awk '{print $2}' | tail -n1);;
    "LXQt") DE_PROFILE=$(eselect profile list | grep 'desktop/lxqt' | grep 'merged-usr' | awk '{print $2}' | tail -n1);;
    "MATE") DE_PROFILE=$(eselect profile list | grep 'desktop/mate' | grep 'merged-usr' | awk '{print $2}' | tail -n1);;
    "Cinnamon") DE_PROFILE=$(eselect profile list | grep 'desktop/cinnamon' | grep 'merged-usr' | awk '{print $2}' | tail -n1);;
    "Minimal") DE_PROFILE=$(eselect profile list | grep 'default/linux/amd64' | grep 'openrc' | awk '{print $2}' | tail -n1);;
esac
eselect profile set "$DE_PROFILE"

healing_emerge --update --deep --newuse @system
case "${de_choice}" in
    "GNOME") healing_emerge gnome-shell/gnome;;
    "KDE Plasma") healing_emerge kde-plasma/plasma-meta;;
    "XFCE") healing_emerge xfce-base/xfce4-meta;;
    "LXQt") healing_emerge lxqt-base/lxqt-meta;;
    "MATE") healing_emerge mate-base/mate-meta;;
    "Cinnamon") healing_emerge cinnamon-meta;;
esac
rm -f /etc/portage/package.use/99_autofix
healing_emerge --update --deep --newuse @world --keep-going=y

# --- Kernel ---
case "${kernel_choice}" in
    "Gentoo Binary Kernel") emerge -q sys-kernel/gentoo-kernel-bin;;
    "Custom Source Kernel") emerge -q sys-kernel/gentoo-sources sys-kernel/genkernel; genkernel all;;
esac

# --- Locale, hostname, root ---
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.UTF-8
env-update && source /etc/profile
echo "${hostname}" > /etc/hostname
echo "root:${root_password}" | chpasswd

# --- User ---
useradd -m -G users,wheel,audio,video -s /bin/bash ${username}
echo "${username}:${user_password}" | chpasswd

# --- Init and services ---
if [[ "${init_choice}" == "OpenRC" ]]; then
    rc-update add sysklogd default
    rc-update add chronyd default
    rc-update add cronie default
elif [[ "${init_choice}" == "Systemd" ]]; then
    emerge -q systemd
fi

# --- Networking ---
emerge -q net-misc/networkmanager
rc-update add NetworkManager default
rc-update add sshd default

# --- X11 and Display Manager ---
emerge -q x11-base/xorg-server
case "${dm_choice}" in
    "GDM") rc-update add gdm default;;
    "SDDM") emerge -q sys-boot/sddm; rc-update add sddm default;;
    "LightDM") emerge -q app-admin/lightdm x11-wm/lightdm-gtk-greeter; rc-update add lightdm default;;
    "LXDM") emerge -q lxdm; rc-update add lxdm default;;
esac

# --- Browser ---
case "${browser_choice}" in
    "Firefox") emerge -q www-client/firefox;;
    "Chromium") emerge -q www-client/chromium;;
esac

# --- Bootloader ---
emerge -q sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

exit
CHROOTEOF

chmod +x /mnt/gentoo/tmp/chroot.sh
chroot /mnt/gentoo /tmp/chroot.sh
rm -f /mnt/gentoo/tmp/chroot.sh

umount -l /mnt/gentoo/dev{/shm,/pts,} || true
umount -R /mnt/gentoo || true
echo "Установка завершена. Введите 'reboot' для запуска новой системы."

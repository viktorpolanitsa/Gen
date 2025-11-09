#!/bin/bash
echo "Welcome to Autotoo!"
echo ""
echo "Enter name of disk to be partitioned"
read disk
echo "The disk to be partitioned is $disk. Is this correct?"
echo "Press return to continue or C-c to exit"
read
sfdisk "$disk" << DISKEOF
label: gpt
unit: sectors
${disk}1 : size=512MiB, type=uefi
${disk}2 : type=linux
DISKEOF
mkfs.vfat -F 32 "$disk"1
mkfs.xfs -f "$disk"2
mkdir -p /mnt/gentoo
mount "$disk"2 /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "$disk"1 /mnt/gentoo/efi
cd /mnt/gentoo
wget https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt
STAGE3_URL=$(grep -v '^#' latest-stage3-amd64-openrc.txt | head -1 | awk '{print $1}')
wget https://distfiles.gentoo.org/releases/amd64/autobuilds/$STAGE3_URL
tar xpvf $(basename $STAGE3_URL) --xattrs-include='*.*' --numeric-owner
cat > /mnt/gentoo/etc/portage/make.conf << MAKECONF
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C target-cpu=native"
MAKEOPTS="-j$(nproc)"
USE="dist-kernel X gtk pulseaudio alsa opengl dri udev"
VIDEO_CARDS="amdgpu radeon"
INPUT_DEVICES="libinput"
MAKECONF
mkdir -p /mnt/gentoo/etc/portage/package.use
echo "sys-kernel/installkernel grub dracut" > /mnt/gentoo/etc/portage/package.use/installkernel
echo "x11-base/xorg-server glamor" > /mnt/gentoo/etc/portage/package.use/xorg
echo "gnome-base/gnome-keyring pam" > /mnt/gentoo/etc/portage/package.use/gnome-keyring
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run
cat > /mnt/gentoo/tmp/chroot.sh << CHROOTEOF
#!/bin/bash
set -e
mount "$disk"1 /efi
emerge-webrsync
eselect profile set default/linux/amd64/17.1/desktop
emerge -1q app-portage/cpuid2cpuflags
echo "*/* \$(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags
echo -e "en_US.UTF-8 UTF-8\nC.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
cat > /etc/env.d/02locale << LOCALEEOF
LANG="en_US.UTF-8"
LC_COLLATE="C.UTF-8"
LOCALEEOF
source /etc/profile
env-update
emerge -q sys-kernel/gentoo-kernel-bin
emerge -q sys-fs/genfstab
genfstab -U / > /etc/fstab
echo "gentoo" > /etc/hostname
emerge -q net-misc/dhcpcd
rc-update add dhcpcd default
echo "Please set root password:"
passwd
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
emerge -q sys-fs/xfsprogs sys-fs/dosfstools
# Install Xorg and drivers
emerge -q x11-base/xorg-server
emerge -q x11-drivers/xf86-video-amdgpu
emerge -q x11-drivers/xf86-input-libinput
# Install XFCE desktop environment
emerge -q xfce-base/xfce4-meta
emerge -q x11-misc/lightdm
emerge -q x11-misc/lightdm-gtk-greeter
# Configure services for automatic startup
rc-update add lightdm default
rc-update add xdm default
# Configure LightDM
sed -i 's/^#autologin-user=.*/autologin-user=/' /etc/lightdm/lightdm.conf
sed -i 's/^#autologin-session=.*/autologin-session=xfce/' /etc/lightdm/lightdm.conf
# Install additional utilities
emerge -q app-editors/mousepad
emerge -q media-gfx/ristretto
emerge -q xfce-extra/xfce4-whiskermenu-plugin
# Create user
echo "Enter username for the new account:"
read username
useradd -m -G users,wheel,audio,video,plugdev -s /bin/bash \$username
echo "Set password for \$username:"
passwd \$username
# Configure sudo
echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers
# Configure GRUB
echo 'GRUB_PLATFORMS="efi-64"' >> /etc/portage/make.conf
emerge -q sys-boot/grub
grub-install --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg
# Update system and resolve dependencies
emerge -q --update --deep --with-bdeps=y --newuse @world
emerge -q --depclean
# Final system setup
rc-update add dbus default
rc-update add elogind default
echo "Installation complete! The system will reboot in 10 seconds."
exit
CHROOTEOF
chmod +x /mnt/gentoo/tmp/chroot.sh
chroot /mnt/gentoo /bin/bash -c "source /etc/profile && /tmp/chroot.sh"
rm /mnt/gentoo/tmp/chroot.sh
echo "Rebooting. Press C-c to abort"
sleep 10
reboot

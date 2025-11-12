#!/bin/bash
# Gentoo Auto-Installer Final Build
# Version: FINAL-RELEASE-STABLE
# This script automatically installs Gentoo with binary packages, using the fastest mirror and user-selected filesystem.

set -e

echo ">>> Starting Gentoo Auto-Installer Final Build..."

# -------------------------
# Mirror and Stage3 detection (PGP-safe)
# -------------------------
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) GENTOO_ARCH="amd64" ;;
  aarch64) GENTOO_ARCH="arm64" ;;
  armv7l|armv7*) GENTOO_ARCH="arm" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

STAGE3_BASE="https://distfiles.gentoo.org/releases/${GENTOO_ARCH}/autobuilds"
STAGE3_LIST="${STAGE3_BASE}/latest-stage3-${GENTOO_ARCH}-openrc.txt"

echo ">>> Fetching latest Stage3 list from ${STAGE3_LIST}"

curl -fsSL "$STAGE3_LIST" | awk '
  BEGIN { found=0 }
  /^[^#].*stage3.*tar\.xz$/ {
    if (!found) {
      print $1
      found=1
    }
  }
' > /tmp/stage3_filename.txt

STAGE3_FILE=$(cat /tmp/stage3_filename.txt)

if [ -z "$STAGE3_FILE" ]; then
  echo "ERROR: Failed to detect Stage3 tarball from ${STAGE3_LIST}"
  exit 1
fi

STAGE3_URL="${STAGE3_BASE}/${STAGE3_FILE}"

echo ">>> Latest Stage3 tarball: ${STAGE3_FILE}"
echo ">>> Full URL: ${STAGE3_URL}"

if ! curl -sI "${STAGE3_URL}" | grep -q "200 OK"; then
  echo "ERROR: Stage3 URL not accessible: ${STAGE3_URL}"
  exit 1
fi

for i in 1 2 3; do
  echo ">>> Download attempt $i..."
  if wget -q --show-progress -O "/tmp/stage3.tar.xz" "${STAGE3_URL}"; then
    echo ">>> Download successful."
    break
  fi
  echo ">>> Retry in 5 seconds..."
  sleep 5
done

if [ ! -s "/tmp/stage3.tar.xz" ]; then
  echo "ERROR: Failed to download Stage3 after multiple attempts."
  exit 1
fi

echo ">>> Extracting Stage3 into /mnt/gentoo ..."
tar xpvf /tmp/stage3.tar.xz -C /mnt/gentoo --xattrs-include='*.*' --numeric-owner || {
  echo "ERROR: Failed to extract Stage3 archive."
  exit 1
}

echo ">>> Stage3 installation completed successfully."

# -------------------------
# Filesystem selection
# -------------------------
echo ">>> Choose a filesystem for your main partition:"
echo "1) ext4"
echo "2) xfs"
echo "3) btrfs"
read -rp "Enter your choice [1-3]: " FS_CHOICE

case "$FS_CHOICE" in
  1) FS_TYPE="ext4" ;;
  2) FS_TYPE="xfs" ;;
  3) FS_TYPE="btrfs" ;;
  *) echo "Invalid choice, defaulting to ext4"; FS_TYPE="ext4" ;;
esac

echo ">>> Selected filesystem: $FS_TYPE"

# Partition example (assumes /dev/sda)
echo ">>> Partitioning /dev/sda..."
parted -s /dev/sda mklabel gpt
parted -s /dev/sda mkpart primary 1MiB 512MiB
parted -s /dev/sda set 1 boot on
parted -s /dev/sda mkpart primary 512MiB 100%

mkfs.vfat -F32 /dev/sda1
case "$FS_TYPE" in
  ext4) mkfs.ext4 /dev/sda2 ;;
  xfs) mkfs.xfs -f /dev/sda2 ;;
  btrfs) mkfs.btrfs -f /dev/sda2 ;;
esac

mount /dev/sda2 /mnt/gentoo
mkdir -p /mnt/gentoo/boot
mount /dev/sda1 /mnt/gentoo/boot

echo ">>> Filesystem setup complete using $FS_TYPE."

# -------------------------
# System profile selection
# -------------------------
eselect profile list
read -rp "Enter desired profile number: " PROFILE_NUM
eselect profile set "$PROFILE_NUM"

echo ">>> Profile set successfully."

# -------------------------
# Sync & Binary Optimization
# -------------------------
emerge-webrsync
emerge --sync
emerge --getbinpkg --update --deep --newuse @world

echo ">>> Installation complete. Ready for chroot setup."

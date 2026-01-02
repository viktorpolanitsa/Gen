#!/bin/bash
set -euo pipefail

mkdir -p /mnt/cdrom

if ! mountpoint -q /mnt/cdrom; then
    for dev in /dev/cdrom /dev/sr0 /dev/sr1 /dev/sr2; do
        if [ -b "$dev" ]; then
            if mount -o ro "$dev" /mnt/cdrom 2>/dev/null; then
                if [ -f /mnt/cdrom/Praxis.sh ]; then
                    break
                fi
                umount /mnt/cdrom || true
            fi
        fi
    done
fi

if [ ! -f /mnt/cdrom/Praxis.sh ]; then
    echo "Seed ISO with Praxis.sh not found; check the second optical drive." >&2
    exit 1
fi

if [ ! -f /mnt/cdrom/genesis.conf ]; then
    echo "genesis.conf not found on seed ISO." >&2
    exit 1
fi

# Copy config so ownership is root in the live environment.
cp /mnt/cdrom/genesis.conf /tmp/genesis.conf
chmod 600 /tmp/genesis.conf

bash /mnt/cdrom/Praxis.sh --force --config /tmp/genesis.conf

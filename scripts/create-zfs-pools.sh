#!/usr/bin/env bash
# Create polaris' ZFS pools + datasets. Idempotency is NOT assumed — run once
# on a fresh set of disks (or after `zpool destroy`). Args are whole-disk or
# partition device paths.
#
# Usage:
#   create-zfs-pools.sh <fast_dev_a> <fast_dev_b> <hdd1> <hdd2> <hdd3>
# Real example (operator):
#   create-zfs-pools.sh \
#     /dev/disk/by-partlabel/disk-os-fastmember \
#     /dev/disk/by-id/nvme-<NVMe2> \
#     /dev/disk/by-id/ata-<HDD1> /dev/disk/by-id/ata-<HDD2> /dev/disk/by-id/ata-<HDD3>
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 <fast_dev_a> <fast_dev_b> <hdd1> <hdd2> <hdd3>" >&2
  exit 2
fi
FAST_A=$1 FAST_B=$2 H1=$3 H2=$4 H3=$5
KEYFILE=/etc/zfs/keys/polaris.key

# 1. Keyfile (32 random bytes). Back this up — losing it loses encrypted data.
if [[ ! -f $KEYFILE ]]; then
  install -d -m 0700 /etc/zfs/keys
  head -c 32 /dev/urandom > "$KEYFILE"
  chmod 0400 "$KEYFILE"
  echo ">> Generated $KEYFILE — BACK IT UP SECURELY (e.g. password manager)."
fi

# 2. fast: NVMe mirror, encrypted at the pool root (datasets inherit).
zpool create -f \
  -o ashift=12 -o autotrim=on \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  -O encryption=aes-256-gcm -O keyformat=raw -O "keylocation=file://$KEYFILE" \
  -O mountpoint=none \
  fast mirror "$FAST_A" "$FAST_B"
zfs create -o mountpoint=/mnt/fast/appdata fast/appdata
zfs create -o mountpoint=/mnt/fast/db      fast/db

# 3. tank: HDD RAIDZ1, pool root UNENCRYPTED.
zpool create -f \
  -o ashift=12 \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  -O mountpoint=none \
  tank raidz1 "$H1" "$H2" "$H3"
# media: unencrypted, lz4, large recordsize for streaming.
zfs create -o mountpoint=/mnt/media -o compression=lz4 -o recordsize=1M tank/media
# data: its own encryptionroot.
zfs create -o mountpoint=/mnt/data \
  -o encryption=aes-256-gcm -o keyformat=raw -o "keylocation=file://$KEYFILE" \
  tank/data

echo ">> Done. Verify: zpool status && zfs list && zfs get keystatus tank/data"

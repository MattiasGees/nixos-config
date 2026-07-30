#!/usr/bin/env bash
# Create polaris' ZFS pools + datasets — the automated form of the manual
# install guide's steps 8–12 (keyfile, fast, tank, scratch, verify).
#
# Run ONCE from the NixOS installer, AFTER partitioning NVMe #1 (guide step 6).
# Idempotency is NOT assumed — re-running needs `zpool destroy` first.
#
# Usage:
#   create-zfs-pools.sh <nvme2> <hdd1> <hdd2> <hdd3>
# where:
#   nvme2   = the 512 GB NVMe (second fast-mirror half), a by-id path
#   hdd1..3 = the three 14 TB disks, by-id paths
#
# Example:
#   sudo ./create-zfs-pools.sh \
#     /dev/disk/by-id/nvme-<NVMe2-512GB> \
#     /dev/disk/by-id/ata-<HDD1-14TB> \
#     /dev/disk/by-id/ata-<HDD2-14TB> \
#     /dev/disk/by-id/ata-<HDD3-14TB>
#
# The two NVMe #1 partitions (fast member + scratch) come from their fixed GPT
# partlabels; override with FAST_MEMBER=/… SCRATCH_DEV=/… (the VM test does this).
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <nvme2> <hdd1> <hdd2> <hdd3>" >&2
  exit 2
fi
NVME2=$1 H1=$2 H2=$3 H3=$4
FAST_MEMBER="${FAST_MEMBER:-/dev/disk/by-partlabel/fastmember}"
SCRATCH_DEV="${SCRATCH_DEV:-/dev/disk/by-partlabel/scratch}"
KEYFILE=/etc/zfs/keys/polaris.key

echo ">> Devices:"
echo "   fast  mirror: $FAST_MEMBER + $NVME2"
echo "   tank  raidz1: $H1 $H2 $H3"
echo "   scratch     : $SCRATCH_DEV"

# --- Step 8: encryption keyfile (only if not already present) ---
if [[ ! -f $KEYFILE ]]; then
  install -d -m 0700 /etc/zfs/keys
  head -c 32 /dev/urandom > "$KEYFILE"
  chmod 0400 "$KEYFILE"
  echo ">> Generated $KEYFILE — BACK IT UP SECURELY (password manager)."
fi

# --- Step 9: fast — NVMe mirror, encrypted at the pool root ---
zpool create -f \
  -o ashift=12 -o autotrim=on \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  -O encryption=aes-256-gcm -O keyformat=raw -O "keylocation=file://$KEYFILE" \
  -O mountpoint=none \
  fast mirror "$FAST_MEMBER" "$NVME2"
zfs create -o mountpoint=/srv/fast/appdata fast/appdata
zfs create -o mountpoint=/srv/fast/db      fast/db

# --- Step 10: tank — HDD RAIDZ1, pool root unencrypted ---
zpool create -f \
  -o ashift=12 \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  -O mountpoint=none \
  tank raidz1 "$H1" "$H2" "$H3"
zfs create -o mountpoint=/srv/media -o compression=lz4 -o recordsize=1M tank/media
zfs create -o mountpoint=/srv/data \
  -o encryption=aes-256-gcm -o keyformat=raw -o "keylocation=file://$KEYFILE" \
  tank/data

# --- Step 11: scratch — single NVMe partition, no redundancy, unencrypted ---
zpool create -f \
  -o ashift=12 -o autotrim=on \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  -O mountpoint=/srv/scratch \
  scratch "$SCRATCH_DEV"

# --- Step 12 (partial): show the result ---
echo ">> Pools created. Verify below, then back up $KEYFILE and export:"
zpool status
zfs list
zfs get -o value keystatus tank/data fast

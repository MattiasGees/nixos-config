# polaris — Manual Install Guide (no disko, no scripts)

A complete, copy-pasteable install of `polaris` where **you** partition the disks
and create the ZFS pools by hand — no disko, no `create-zfs-pools.sh`. Every
command is spelled out.

> **Mountpoints:** this guide mounts the pools under **`/srv`** (`/srv/media`,
> `/srv/data`, `/srv/fast/*`), not `/mnt/...`. Reason: the installer mounts the
> target root at `/mnt`, so using `/mnt/...` for permanent ZFS mounts collides
> with the install. `/srv` is the conventional home for served data. If you
> truly want `/mnt/...` runtime paths you'd need a `zpool create -R` altroot
> dance — not worth it; `/srv` is cleaner.

---

## 0. Config prerequisite (manual mode)

This guide assumes `polaris` is wired for **manual** disk management, i.e. **not**
using disko. If your branch still has disko, make these two changes first and
commit them:

**a. `flake.nix`** — the `polaris` output is a plain server (no disko):
```nix
nixosConfigurations.polaris = mkServer "polaris" rec {
  inherit home-manager user nixpkgs system pkgs;
  lib = pkgs.lib;
};
```
(and remove the `disko` input + the `disko` arg in `outputs`.)

**b. `hardware/polaris.nix`** — add the static filesystem block (disko used to
provide this), keeping `hostId`, kernel modules and `boot.zfs.extraPools`:
```nix
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };
  swapDevices = [
    { device = "/dev/disk/by-partlabel/swap"; randomEncryption.enable = true; }
  ];
```
The ZFS datasets are **not** listed in `fileSystems` — `boot.zfs.extraPools =
[ "tank" "fast" ]` imports the pools at boot and ZFS mounts them at the
mountpoints you set below.

---

## 1. BIOS

Set everything in [`bios-checklist.md`](./bios-checklist.md) (UEFI, no CSM,
Secure Boot off, SVM + IOMMU on, AHCI, restore-on-power-loss).

## 2. Boot the installer & get the repo

Boot the NixOS installer USB, get networking, then:
```bash
sudo -i                       # work as root for the whole install
git clone https://github.com/mattiasgees/nixos-config
cd nixos-config
```

## 3. Identify the disks

**This is the dangerous part — confirm which disk is which before touching anything.**
```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE
ls -l /dev/disk/by-id/
```
Note the stable `by-id` paths for:
- **NVMe #1** — the 1 TB NVMe (OS + fast mirror half). → `NVME1`
- **NVMe #2** — the 512 GB NVMe (fast mirror half). → `NVME2`
- **HDD 1/2/3** — the three 14 TB disks. → `HDD1 HDD2 HDD3`

Export them as shell variables so the rest of the guide is copy-paste (substitute
the real IDs):
```bash
NVME1=/dev/disk/by-id/nvme-<NVMe1-1TB>
NVME2=/dev/disk/by-id/nvme-<NVMe2-512GB>
HDD1=/dev/disk/by-id/ata-<HDD1-14TB>
HDD2=/dev/disk/by-id/ata-<HDD2-14TB>
HDD3=/dev/disk/by-id/ata-<HDD3-14TB>
```

## 4. Partition NVMe #1

Four GPT partitions: ESP, ext4 root, swap, and the `fast` mirror member.
```bash
sgdisk --zap-all "$NVME1"
sgdisk -n1:0:+1G    -t1:EF00 -c1:ESP        "$NVME1"   # EFI System Partition
sgdisk -n2:0:+450G  -t2:8300 -c2:nixos      "$NVME1"   # ext4 root
sgdisk -n3:0:+8G    -t3:8200 -c3:swap       "$NVME1"   # swap (encrypted at boot)
sgdisk -n4:0:0      -t4:BF00 -c4:fastmember "$NVME1"   # rest -> fast ZFS member
partprobe "$NVME1"; udevadm settle
```

## 5. Format & mount root + boot

```bash
mkfs.vfat -F32 -n BOOT  /dev/disk/by-partlabel/ESP
mkfs.ext4      -L nixos /dev/disk/by-partlabel/nixos
udevadm settle

mount /dev/disk/by-label/nixos /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-label/BOOT /mnt/boot
```
> Swap needs no `mkswap` — NixOS `randomEncryption` formats it with a fresh
> random key on every boot.

## 6. Encryption keyfile

One 32-byte random key, used for `fast/*` and `tank/data`:
```bash
install -d -m 0700 /etc/zfs/keys
head -c 32 /dev/urandom > /etc/zfs/keys/polaris.key
chmod 0400 /etc/zfs/keys/polaris.key
```

## 7. Create the `fast` pool (NVMe mirror, encrypted)

The pool root holds the encryption and is unmounted; the datasets inherit it.
```bash
zpool create -f \
  -o ashift=12 -o autotrim=on \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  -O encryption=aes-256-gcm -O keyformat=raw \
  -O keylocation=file:///etc/zfs/keys/polaris.key \
  -O mountpoint=none \
  fast mirror \
    /dev/disk/by-partlabel/fastmember \
    "$NVME2"

zfs create -o mountpoint=/srv/fast/appdata fast/appdata
zfs create -o mountpoint=/srv/fast/db      fast/db
```
Flag meanings: `ashift=12` = 4K sectors; `autotrim=on` = SSD TRIM;
`compression=zstd` = space saving; `atime=off` = no access-time writes;
`xattr=sa`/`acltype=posixacl` = needed by some services later;
`encryption=aes-256-gcm` + `keyformat=raw` + `keylocation=file://…` = the
keyfile auto-unlock; `mountpoint=none` = the pool root itself isn't mounted.

## 8. Create the `tank` pool (HDD RAIDZ1)

Pool root **unencrypted**; `media` unencrypted + `lz4`, `data` encrypted.
```bash
zpool create -f \
  -o ashift=12 \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  -O mountpoint=none \
  tank raidz1 "$HDD1" "$HDD2" "$HDD3"

# media: replaceable, already-compressed files -> lz4 + big records, no encryption
zfs create -o mountpoint=/srv/media -o compression=lz4 -o recordsize=1M tank/media

# data: personal/bulk data -> its own encryptionroot
zfs create -o mountpoint=/srv/data \
  -o encryption=aes-256-gcm -o keyformat=raw \
  -o keylocation=file:///etc/zfs/keys/polaris.key \
  tank/data
```

## 9. Verify the pools, then persist the key & export

```bash
zpool status                      # fast = mirror, tank = raidz1, all ONLINE
zfs list                          # tank/{media,data}, fast/{appdata,db} present
zfs get -o value keystatus tank/data fast   # => available (keys loaded)
zfs get -o value encryption tank/media      # => off  (media unencrypted)
zfs get -o value compression tank/media     # => lz4
```

Copy the keyfile onto the target root so it survives the install (the pools
record `keylocation=/etc/zfs/keys/polaris.key`, which must exist on the booted
system):
```bash
install -d -m 0700 /mnt/etc/zfs/keys
cp -a /etc/zfs/keys/polaris.key /mnt/etc/zfs/keys/polaris.key
```
**Back up `/etc/zfs/keys/polaris.key` somewhere safe now** (password manager).
Losing it = losing every encrypted dataset.

Cleanly export the pools so first boot imports them without a `-f` force:
```bash
zpool export tank
zpool export fast
```

## 10. Fill in config values

Edit these to match the real machine, then commit:
- `hardware/polaris.nix` → `networking.hostId`:
  ```bash
  head -c 8 /dev/urandom | od -A none -t x1 | tr -d ' '   # first 8 hex chars
  ```
- `hardware/polaris.nix` → `boot.initrd.availableKernelModules`: replace with
  ```bash
  nixos-generate-config --no-filesystems --show-hardware-config
  ```
  output (the `--no-filesystems` flag omits `fileSystems`, which you already
  hand-wrote in step 0).
- `machines/polaris.nix` → confirm the NIC name (`ip -o link`) for the static IP.

Optionally sanity-check the build before installing:
```bash
nixos-rebuild build --flake .#polaris --impure
```

## 11. Install & reboot

```bash
nixos-install --flake .#polaris
# set a root password if prompted
reboot
```

## 12. Post-boot verification

SSH in (`ssh mattias@192.168.1.50`) and confirm:
```bash
zpool status                                  # both pools ONLINE
zfs get -o value keystatus tank/data fast     # => available (auto-unlocked)
mount | grep -E '/srv/(media|data|fast)'       # datasets mounted
dmesg | grep -i -e IOMMU -e AMD-Vi            # IOMMU active
systemctl is-system-running                    # running (or degraded — check why)
```
If `keystatus` isn't `available`, the `zfs-load-key` service didn't run before
`zfs-mount` — check `journalctl -u zfs-load-key`.

---

## Notes

- **Day-2 changes never repeat any of this.** After install, changes are just
  `make switch NIXNAME=polaris` — you never re-partition or re-create pools.
- **Reinstall (OS dead, disks fine):** restore the keyfile to
  `/mnt/etc/zfs/keys/`, repeat **only steps 3–5 and 10–11** for NVMe #1 (never
  the HDDs/NVMe #2), then `zpool import tank` and `zpool import fast` instead of
  re-creating them. The `fast` mirror will import degraded (NVMe #1's half was
  wiped); re-add it with:
  ```bash
  zpool replace fast <old-nvme1-part-id> /dev/disk/by-partlabel/fastmember
  ```
- **Never** run `sgdisk`/`zpool create` against the HDDs or NVMe #2 on a
  reinstall — that destroys data. Creation happens exactly once.

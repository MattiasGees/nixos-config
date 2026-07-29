# polaris — Manual NixOS Install Guide (from the minimal ISO)

A complete, from-scratch install of `polaris` on the official **NixOS minimal
ISO**. You partition every disk and create every ZFS pool **by hand** — no disko,
no helper scripts. Each command is followed by *why* you run it.

## What you're building

| Disk | Layout |
|------|--------|
| **NVMe #1 (2 TB)** | ESP (`/boot`) · ext4 root (`/`) · encrypted swap · `fast` mirror member · `scratch` pool |
| **NVMe #2 (512 GB)** | second half of the `fast` mirror |
| **3 × HDD (14 TB)** | `tank` pool (RAIDZ1) |

| Pool | vdev | Redundancy | Mount | Encrypted |
|------|------|-----------|-------|-----------|
| `fast` | mirror(NVMe1 part, NVMe2) | 1-disk | `/srv/fast/*` | ✅ keyfile |
| `tank` | raidz1(3× HDD) | 1-disk | `/srv/media`, `/srv/data` | `data` ✅ / `media` ❌ |
| `scratch` | single NVMe1 partition | **none** | `/srv/scratch` | ❌ |

> **Why `/srv` and not `/mnt`?** The installer mounts the target system at `/mnt`.
> Using `/mnt/...` for permanent ZFS mountpoints would collide with the install.
> `/srv` is the conventional home for served data and sidesteps that entirely.

---

## 1. Before you boot

- Download the **NixOS minimal ISO** (x86_64) from nixos.org and write it to a
  USB stick (`dd if=nixos-minimal-*.iso of=/dev/sdX bs=4M status=progress`, or
  Ventoy/balenaEtcher).
- *Why minimal:* it's a text installer — right for a headless server, and it has
  everything we need once we pull a couple of extra tools.

## 2. Boot the installer

Boot the USB (UEFI mode — the BIOS checklist already set this). You land at a
shell logged in as the `nixos` user.

```bash
sudo -i
```
*Why:* partitioning, formatting, loading kernel modules, and `nixos-install` all
need root.

## 3. Networking

**Wired (typical for a server):** DHCP is automatic. Confirm:
```bash
ping -c2 nixos.org
```
**Wi-Fi (if needed):**
```bash
sudo systemctl start wpa_supplicant
wpa_cli
> add_network
> set_network 0 ssid "YOUR_SSID"
> set_network 0 psk "YOUR_PASSWORD"
> enable_network 0
> quit
```
*Why:* the install downloads the flake inputs and every package from the binary
cache — no network, no install.

## 4. Enable flakes and pull the tools we need

```bash
export NIX_CONFIG="experimental-features = nix-command flakes"
nix-shell -p git gptfdisk zfs
```
*Why:*
- `NIX_CONFIG=…` turns on flake support so `nixos-install --flake` works.
- `git` clones your config repo; `gptfdisk` gives `sgdisk` (partitioning); `zfs`
  gives `zpool`/`zfs`. The minimal ISO doesn't ship all of these, and
  `nix-shell -p` drops you into a shell that has them (temporarily, in RAM).

Load the ZFS kernel module:
```bash
modprobe zfs && echo "ZFS ready"
```
*Why:* creating/importing pools needs the kernel module, not just the userland
tools. **If this errors** (`module not found`), the ISO's kernel lacks ZFS —
grab a ZFS-enabled NixOS ISO (or ask me to add a small installer-ISO flake
output you can build on any x86_64 Linux box) and start over from step 2.

## 5. Identify the disks — carefully

Everything below is destructive. Get the devices right.
```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE
ls -l /dev/disk/by-id/
```
*Why `by-id`:* `/dev/sda`, `/dev/nvme0n1` etc. can reorder between boots — you
could nuke the wrong disk. `by-id` names are tied to the physical device.

Capture the stable paths into variables so the rest is copy-paste (substitute the
real IDs you see):
```bash
NVME1=/dev/disk/by-id/nvme-<NVMe1-2TB>      # 2 TB: OS + fast half + scratch
NVME2=/dev/disk/by-id/nvme-<NVMe2-512GB>    # 512 GB: other fast mirror half
HDD1=/dev/disk/by-id/ata-<HDD1-14TB>
HDD2=/dev/disk/by-id/ata-<HDD2-14TB>
HDD3=/dev/disk/by-id/ata-<HDD3-14TB>
```

## 6. Partition NVMe #1

```bash
sgdisk --zap-all "$NVME1"
sgdisk -n1:0:+1G    -t1:EF00 -c1:ESP        "$NVME1"   # EFI System Partition
sgdisk -n2:0:+500G  -t2:8300 -c2:nixos      "$NVME1"   # ext4 root
sgdisk -n3:0:+8G    -t3:8200 -c3:swap       "$NVME1"   # swap
sgdisk -n4:0:+475G  -t4:BF00 -c4:fastmember "$NVME1"   # fast ZFS mirror member
sgdisk -n5:0:0      -t5:BF00 -c5:scratch    "$NVME1"   # rest -> scratch pool
partprobe "$NVME1"; udevadm settle
```
*Why each partition:*
- **ESP (1 GiB, type EF00):** UEFI firmware can only load a bootloader from a FAT
  EFI System Partition. 1 GiB comfortably holds several kernels + initrds.
- **root (500 GiB, ext4):** the OS and nix store. ext4 is simple and rescuable
  from any live USB; kept modest because all real data lives on ZFS.
- **swap (8 GiB):** overflow if the 64 GB RAM is exhausted. Small on purpose.
- **fastmember (475 GiB):** the NVMe half of the redundant `fast` mirror. Sized to
  match NVMe #2 — a mirror can't exceed its smaller member, so bigger is wasted.
- **scratch (rest, ~840 GiB):** a fast, disposable single-disk pool.
- `partprobe`/`udevadm settle` make the kernel re-read the table so the new
  `by-partlabel` names appear before we use them.

## 7. Format and mount root + boot

```bash
mkfs.vfat -F32 /dev/disk/by-partlabel/ESP
mkfs.ext4      /dev/disk/by-partlabel/nixos
udevadm settle

mount /dev/disk/by-partlabel/nixos /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-partlabel/ESP /mnt/boot
```
*Why:*
- UEFI requires the ESP to be **FAT** (`mkfs.vfat`). We don't set filesystem
  labels — `nixos-generate-config` (step 13) will record root/boot by **UUID**,
  the standard NixOS way (same as your `desktop` host). We mount by
  `by-partlabel` here only because it's a stable name for the install itself.
- We mount the target root at **`/mnt`** and the ESP at **`/mnt/boot`** because
  `nixos-install` writes the new system into `/mnt` and installs the bootloader
  into `/mnt/boot`.
- Swap needs no `mkswap` — NixOS `randomEncryption` formats it with a fresh random
  key on every boot (so paged-out data is never written in the clear; no
  hibernation, which is fine for a server).

## 8. Create the encryption keyfile

```bash
install -d -m 0700 /etc/zfs/keys
head -c 32 /dev/urandom > /etc/zfs/keys/polaris.key
chmod 0400 /etc/zfs/keys/polaris.key
```
*Why:* one 32-byte random key unlocks the encrypted datasets (`fast/*`,
`tank/data`). Storing it as a file (referenced by `keylocation=file://…`) lets
the server reboot unattended — no passphrase prompt on a headless box.

> **Shortcut for steps 8–11.** The three `zpool`/`zfs` blocks below are a lot to
> type. The repo ships a script that does all of them (plus the step-8 keyfile).
> You're already root (step 2), with `git`/`zfs` on `PATH` (step 4), so:
> ```bash
> git clone https://github.com/mattiasgees/nixos-config
> ( cd nixos-config && git checkout polaris-phase1 )   # until merged to your main branch
> bash nixos-config/scripts/create-zfs-pools.sh \
>   /dev/disk/by-id/nvme-<NVMe2-512GB> \
>   /dev/disk/by-id/ata-<HDD1-14TB> \
>   /dev/disk/by-id/ata-<HDD2-14TB> \
>   /dev/disk/by-id/ata-<HDD3-14TB>
> ```
> Only four devices to fill in — the fast-member and scratch partitions come from
> their fixed GPT partlabels. It prints the verification when done; then jump to
> **step 12** to back up the key and export. The manual steps below are the same
> commands, spelled out.

## 9. Create the `fast` pool (NVMe mirror, encrypted)

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
*Why the flags:* `ashift=12` = 4K sectors (correct for modern SSDs; **immutable**
after creation); `autotrim=on` = keep SSD performance up; `compression=zstd` =
reclaim space on compressible app/db data; `atime=off` = don't write a timestamp
on every read; `xattr=sa`/`acltype=posixacl` = needed by some services later;
`encryption/keyformat/keylocation` = the keyfile auto-unlock; `mountpoint=none` =
the pool root isn't mounted, only the datasets are. `mirror` = the two devices
hold identical copies, surviving either one failing.

## 10. Create the `tank` pool (HDD RAIDZ1)

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
*Why:* `raidz1` across the three 14 TB disks = ~28 TB usable, survives one disk
failing. The pool root is unencrypted; `tank/media` stays unencrypted with `lz4`
and a 1 MiB `recordsize` (video/audio won't compress and streams sequentially),
while `tank/data` gets its own encryption for the data you care about.

## 11. Create the `scratch` pool (single NVMe, no redundancy)

```bash
zpool create -f \
  -o ashift=12 -o autotrim=on \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  -O mountpoint=/srv/scratch \
  scratch /dev/disk/by-partlabel/scratch
```
*Why:* fast, **disposable** NVMe space (transcode temp, download staging, Docker
overlay, caches). One disk = no redundancy, so keep nothing precious here.
Unencrypted for speed; it's transient and sits on the OS disk. Add purpose
datasets whenever you like, e.g. `zfs create -o mountpoint=/srv/scratch/transcode
scratch/transcode`.

## 12. Verify, persist the key, and export

```bash
zpool status                                  # fast=mirror, tank=raidz1, scratch=single, all ONLINE
zfs list                                      # datasets present, mounted under /srv
zfs get -o value keystatus tank/data fast     # => available (keys loaded)
zfs get -o value encryption tank/media        # => off
zfs get -o value compression tank/media       # => lz4
```

Persist the keyfile onto the target root so the installed system can unlock at
boot, then **back it up**:
```bash
install -d -m 0700 /mnt/etc/zfs/keys
cp -a /etc/zfs/keys/polaris.key /mnt/etc/zfs/keys/polaris.key
```
> **Back up `/mnt/etc/zfs/keys/polaris.key` somewhere safe right now** (password
> manager). Lose it and every encrypted dataset is gone forever.

Cleanly export the pools:
```bash
zpool export tank
zpool export fast
zpool export scratch
```
*Why export:* it marks the pools as not-in-use and stamps them cleanly, so first
boot imports them via `boot.zfs.extraPools` without a "pool was last used by
another system" force. (The ext4 root stays mounted at `/mnt` for the install.)

## 13. Get the config and fill in the machine-specific values

```bash
cd /mnt/etc          # anywhere writable is fine; /mnt persists onto the system
git clone https://github.com/mattiasgees/nixos-config
cd nixos-config
git checkout polaris-phase1          # until it's merged into your main branch
```
> No `git submodule update` needed: the repo's submodules (AstroNvim, a macOS
> sketchybar plugin) are only used by the desktop/macOS configs. polaris' server
> config uses `nvim-server.nix` (a plain in-repo directory), so a bare clone is
> complete.
Generate the real hardware config, then **overwrite** the repo's `hardware/polaris.nix`
with it wholesale — no hand-merging:
```bash
nixos-generate-config --root /mnt
cp /mnt/etc/nixos/hardware-configuration.nix hardware/polaris.nix
```
*Why this is safe to copy whole:* `nixos-generate-config` writes the OS disk's
**root/boot filesystems (by UUID)** and **`boot.initrd.availableKernelModules`** —
the standard NixOS flow, same as your `desktop` host. It does **not** touch the
ZFS pools (they mount under `/srv`, outside `/mnt`, so it never sees them). All
the polaris-specific storage config — `networking.hostId`, `boot.zfs.extraPools`,
encrypted `swapDevices`, and the NVIDIA driver — lives in a **separate** file,
`hardware/polaris-extra.nix` (wired in via `flake.nix`), so overwriting
`hardware/polaris.nix` loses nothing.

Then set the two remaining machine-specific values and commit:
- `hardware/polaris-extra.nix` → a real `networking.hostId`:
  ```bash
  head -c 8 /dev/urandom | od -A none -t x1 | tr -d ' '   # use the first 8 hex chars
  ```
- `machines/polaris.nix` → confirm the **NIC name** for the static IP
  (`ip -o link`, e.g. `enp4s0`).

*Why keep the generated file in Git:* those UUIDs stay valid as long as you don't
reformat the OS disk, so a reinstall that keeps the disks needs no changes. If you
ever do reformat, just re-run the two commands above to overwrite it again.

## 14. Install and reboot

```bash
nixos-install --flake /mnt/etc/nixos-config#polaris
```
*Why:* `nixos-install` builds the whole system from your flake's `polaris`
output and installs it into `/mnt`. You'll be prompted to set a **root password**
— set one; it's your emergency console login (your `mattias` user logs in over
SSH with keys). Then:
```bash
reboot
```

## 15. First-boot verification

Remove the USB, let it boot, then SSH in (`ssh mattias@192.168.1.50`) and check:
```bash
zpool status                                  # all three pools ONLINE
zfs get -o value keystatus tank/data fast     # => available (auto-unlocked)
mount | grep -E '/srv/(media|data|fast|scratch)'
nvidia-smi                                    # RTX 3080 detected
dmesg | grep -i -e IOMMU -e AMD-Vi            # IOMMU active (for future passthrough)
systemctl is-system-running                    # running (or degraded — investigate why)
```
If `keystatus` isn't `available`, check `journalctl -u zfs-load-key` — that
service must load the key before `zfs-mount`.

---

## Day-2 changes

You never repeat any of the above. To change the system:
```bash
cd ~/nixos-config          # wherever you cloned it
# edit .nix files
make switch NIXNAME=polaris        # build + activate (system AND home-manager)
```
For risky changes, `sudo nixos-rebuild test --flake .#polaris --impure` first (it
activates without touching the bootloader, so a reboot recovers you); roll back
with `sudo nixos-rebuild switch --rollback` or pick an older generation in the
boot menu. Commit and push after changes — Git is your source of truth.

## Recovery

**Golden rule:** on any reinstall, only ever repartition **NVMe #1**. `tank` and
`fast` are *imported*, never recreated.

**OS reinstall (OS dead, disks intact):**
1. Boot the ISO, redo steps 2–7 for **NVMe #1 only** (partition + format + mount).
2. Restore your keyfile backup to `/mnt/etc/zfs/keys/polaris.key`.
3. `git clone` the repo, `nixos-install --flake …#polaris`, reboot.
4. `zpool import tank` (clean) and `zpool import fast` (imports **degraded** —
   NVMe #1's mirror half was wiped). Re-add that half:
   ```bash
   zpool replace fast <old-nvme1-part-id> /dev/disk/by-partlabel/fastmember
   ```
   Watch `zpool status fast` resilver back to ONLINE.
5. Recreate `scratch` (step 11) — it lived on NVMe #1 and was wiped; its contents
   are disposable, so that's expected.

**Single HDD failure (`tank`):**
```bash
zpool status tank                 # identify the failed disk
# physically replace it, then:
zpool replace tank <old-id> <new-id>
zpool status tank                 # wait for resilver
```

**Single NVMe failure:**
- **NVMe #2:** `zpool replace fast <old-id> <new-id>`, wait for resilver.
- **NVMe #1:** the OS + scratch are gone → do the full OS reinstall above.

**Routine health:** `zpool status` / `zfs list` occasionally; a weekly scrub and
periodic TRIM run automatically (`services.zfs.autoScrub`, `services.zfs.trim`).
Keep the keyfile backup current and the flake pushed to Git — those two rebuild
the whole machine.

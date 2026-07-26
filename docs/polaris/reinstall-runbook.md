# polaris — Reinstall & Recovery Runbook

**Golden rule:** never run disko or `create-zfs-pools.sh` against anything but
**NVMe #1** on a reinstall. The `tank` and `fast` pools are *imported*, never
re-created. `disko/polaris.nix` intentionally describes only the OS disk, so a
disko run cannot touch the data pools.

Related files: `disko/polaris.nix`, `disko/polaris-layout.nix`,
`scripts/create-zfs-pools.sh`, key at `/etc/zfs/keys/polaris.key`.

---

## A. Fresh install (first-time provisioning)

1. **BIOS** — set everything in `bios-checklist.md`.
2. **Boot** the NixOS installer USB. Get networking, then:
   ```bash
   git clone https://github.com/mattiasgees/nixos-config
   cd nixos-config
   ```
3. **Fill install-time values** discovered from the real hardware:
   - `ls -l /dev/disk/by-id/ | grep nvme` → put NVMe #1's by-id path into
     `disko/polaris.nix` (replace `REPLACE_ME_NVME1`).
   - `head -c 8 /dev/urandom | od -A none -t x1 | tr -d ' '` → set
     `networking.hostId` in `hardware/polaris.nix` (first 8 hex chars).
   - `ip -o link` → confirm the NIC name in `machines/polaris.nix`
     (default `enp4s0`).
   - Replace `boot.initrd.availableKernelModules` in `hardware/polaris.nix`
     with the real machine's output from:
     ```bash
     nixos-generate-config --no-filesystems --show-hardware-config
     ```
     `--no-filesystems` omits the `fileSystems`/`swapDevices` block (disko owns
     those), so the output merges cleanly with `hardware/polaris.nix` — do NOT
     paste a full hardware-configuration.nix, it would clash with disko's
     `fileSystems."/"`.
   - Commit these edits.
4. **Partition the OS disk** (NVMe #1 only) with disko:
   ```bash
   sudo nix run github:nix-community/disko -- \
     --mode disko ./disko/polaris.nix
   ```
   This creates the ESP, ext4 root, encrypted swap, and the raw `fast` slot,
   and mounts root+boot under `/mnt`.
5. **Create the ZFS pools** with the real device paths:
   ```bash
   sudo ./scripts/create-zfs-pools.sh \
     /dev/disk/by-partlabel/disk-os-fastmember \
     /dev/disk/by-id/nvme-<NVMe2> \
     /dev/disk/by-id/ata-<HDD1> /dev/disk/by-id/ata-<HDD2> /dev/disk/by-id/ata-<HDD3>
   ```
   **Immediately back up `/etc/zfs/keys/polaris.key`** somewhere safe (e.g. a
   password manager). Losing it means losing every encrypted dataset.
6. **Install** and reboot:
   ```bash
   sudo nixos-install --flake .#polaris
   reboot
   ```
7. **Verify** (see the real-hardware checklist in the plan, Task 12).

---

## B. OS reinstall (disks intact, OS corrupt)

Data survives — only NVMe #1's OS slice is rebuilt.

1. Boot the installer USB; `git clone` the repo; `cd nixos-config`.
2. **Restore `/etc/zfs/keys/polaris.key`** from your secure backup to
   `/mnt/etc/zfs/keys/` (so it lands on the new root).
3. Run disko against **NVMe #1 ONLY**:
   ```bash
   sudo nix run github:nix-community/disko -- --mode disko ./disko/polaris.nix
   ```
   (It references only the OS disk — it cannot touch `tank`/`fast`.)
4. Install: `sudo nixos-install --flake .#polaris`.
5. Reboot. Then re-attach the data pools:
   ```bash
   zpool import tank      # untouched — imports cleanly
   zpool import fast      # DEGRADED — NVMe #1's mirror half is blank
   ```
6. Rebuild the `fast` mirror's NVMe #1 half:
   ```bash
   zpool status fast      # note the missing/old device id
   zpool replace fast <old-nvme1-part-id> /dev/disk/by-partlabel/disk-os-fastmember
   # resilvers from NVMe #2; watch until ONLINE:
   zpool status fast
   ```
7. Confirm encryption auto-unlock: `zfs get keystatus tank/data fast`
   → `available`.

**Never** run disko or `create-zfs-pools.sh` against the HDDs or NVMe #2 in this
flow.

---

## C. Single HDD failure (`tank`)

```bash
zpool status tank                       # identify the failed disk
# physically replace it, then:
zpool replace tank <old-id> <new-id>
zpool status tank                       # wait for resilver to finish
```

## D. Single NVMe failure (`fast`)

- **NVMe #2 fails:** replace the disk, then
  `zpool replace fast <old-id> <new-id>` and wait for resilver.
- **NVMe #1 fails:** the OS is gone → follow **B. OS reinstall** with a new
  NVMe #1.

---

## E. Routine health

- `zpool status` and `zfs list` — a weekly glance. A weekly scrub runs
  automatically (`services.zfs.autoScrub`), as does periodic TRIM.
- Keep `/etc/zfs/keys/polaris.key` backed up and the flake pushed to Git — those
  two are all you need to rebuild the machine.

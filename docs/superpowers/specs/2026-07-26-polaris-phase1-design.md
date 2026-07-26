# Home Server — Phase 1 Design (Base OS + ZFS + Shell)

**Status:** Draft for review
**Date:** 2026-07-26
**Host name:** `polaris` (keys `hardware/`, `machines/`, and the flake output; pairs with the laptop `pacesetter`)
**Platform:** AMD, `x86_64-linux`

---

## 1. Purpose & goals

Convert an existing AMD PC into a headless NixOS home server, managed from this
flake alongside the desktop and macOS hosts. Phase 1 establishes a **solid,
recoverable foundation only** — the base OS, the disk/ZFS layout, and the user's
shell environment. Application services and backups come in later phases.

**Phase 1 success criteria**

1. Machine boots headless; reachable over SSH (and mosh) as `mattias`.
2. ZFS pools `fast` (NVMe mirror) and `tank` (HDD RAIDZ1) import and mount on
   boot; encrypted datasets auto-unlock via keyfile.
3. Full shell/dev environment present (same `home-manager-server.nix` profile as
   the other hosts).
4. Can host VMs (libvirt/KVM enabled); IOMMU pre-enabled for future GPU
   passthrough (passthrough itself NOT configured yet).
5. `nixos-rebuild build .#polaris` is green; the disko VM test passes; the
   config smoke-boots in a VM on the M1.
6. Two operator docs exist and are accurate: a **BIOS/UEFI checklist** and an
   **OS reinstall/recovery runbook** proving data survives an OS wipe.

## 2. Scope

**In scope (Phase 1)**

- BIOS/UEFI configuration guidance.
- Declarative OS-disk partitioning via **disko**.
- Manual creation + import of the `fast` and `tank` ZFS pools (kept out of
  disko's destructive path).
- Base NixOS: bootloader, networking, users, SSH, mosh, docker, libvirt, ZFS
  services (scrub/trim), encrypted-swap.
- Shell environment via `home-manager-server.nix`.
- Testing ladder (build gate, disko VM test, aarch64 VM variant, hardware
  checklist).
- Reinstall/recovery runbook.

**Explicitly deferred (later phases, each its own spec)**

- Services: Plex, Sonarr, Radarr, Miniflux, Karakeep, Outline (each as its own
  service user; media apps share a `media` group over `tank/media`).
- Backups (snapshots policy, off-box replication).
- GPU passthrough to a VM.
- Optional migration to root-on-ZFS.
- Optional adoption of a GUI.

## 3. Hardware

| Device | Size | Role |
|--------|------|------|
| NVMe #1 | 1 TB | ESP + ext4 root + encrypted swap + `fast` mirror member |
| NVMe #2 | 512 GB | `fast` mirror member (whole disk) |
| HDD ×3 | 14 TB each | `tank` RAIDZ1 pool |
| CPU | AMD | `kvm-amd`, `amd_iommu=on`, AMD microcode |

## 4. BIOS/UEFI checklist

Set these before installing (exact menu names vary by board):

**Required**
- **Boot mode: UEFI** only; **disable CSM/Legacy**.
- **Secure Boot: Disabled** (NixOS default path; secure boot via `lanzaboote` is
  a possible future item, out of scope now).
- **SVM / AMD-V: Enabled** — CPU virtualization, required for libvirt/KVM.
- **IOMMU / AMD-Vi: Enabled** — enable *now* even though passthrough is future;
  avoids a BIOS trip later. Pairs with `amd_iommu=on` kernel param.
- **SATA/NVMe mode: AHCI** (not RAID — we use ZFS software RAID, never
  motherboard/fake-RAID).
- **Restore on AC Power Loss: Power On** — server should come back after an
  outage.

**Recommended**
- **Above 4G Decoding: Enabled** and **Resizable BAR: Enabled** — harmless now,
  needed for future GPU passthrough.
- **Fast Boot: Disabled** — more reliable POST / device init for a server.
- **Memory profile (EXPO/DOCP): optional** — enable if RAM is rated for it and
  stable. ZFS benefits from RAM bandwidth.
- **ECC: Enabled** if board+RAM support it (ideal for ZFS; not mandatory).
- **Fan curve** tuned for the 3 HDDs' thermals.
- **Boot order:** NVMe #1 first.
- **Wake-on-LAN:** optional, if you want remote power-on.

> Verification after install: `systemd-analyze` shows no firmware complaints;
> `dmesg | grep -i -e IOMMU -e AMD-Vi` shows IOMMU enabled;
> `zpool status` shows disks by stable IDs.

## 5. Storage architecture

### 5.1 Layout

```
NVMe #1 (1 TB, /dev/disk/by-id/nvme-...)      NVMe #2 (512 GB)        HDD ×3 (14 TB)
┌───────────────────────────┐                 ┌───────────────┐       ┌────┬────┬────┐
│ p1  ESP /boot   1 GiB vfat │                 │ whole disk    │       │ D1 │ D2 │ D3 │
│ p2  ext4 /     ~465 GiB    │                 │ fast mirror   │◄─┐    │ RAIDZ1 (tank)  │
│ p3  fast member ~465 GiB   │◄────mirror──────►               │  │    └────┴────┴────┘
│ p4  swap         8 GiB     │                 └───────────────┘  │
└───────────────────────────┘                                    │
        │                                                         │
   disko-managed                                        fast pool = mirror(p3, NVMe#2)
```

### 5.2 Pools & datasets

| Pool | vdev | Usable | Dataset | Mount | Encrypted | Notes |
|------|------|--------|---------|-------|-----------|-------|
| `fast` | mirror(NVMe1p3, NVMe2) | ~465 GB | `fast/appdata` | `/mnt/fast/appdata` | ✅ keyfile | service state (later) |
| | | | `fast/db` | `/mnt/fast/db` | ✅ keyfile | databases (later) |
| `tank` | raidz1(HDD1,2,3) | ~28 TB | `tank/media` | `/mnt/media` | ❌ | Plex library; `recordsize=1M` |
| | | | `tank/data` | `/mnt/data` | ✅ keyfile | personal/bulk data |

Pool/dataset property choices:
- `ashift=12` (4K sectors) on both pools.
- **Compression — per-dataset:** `zstd` (default `zstd-3`) as the general
  default on `fast/*` and `tank/data` (compressible app/db/personal data, and
  CPU is plentiful); **`lz4` on `tank/media`** (media is already compressed —
  won't shrink under either, so use the cheapest option for max streaming/
  transcode throughput). See design note in §5.6.
- `atime=off` for performance.
- `xattr=sa`, `acltype=posixacl` (needed by some services later).
- `tank/media`: `recordsize=1M` for large sequential media files.
- Encryption: `encryption=aes-256-gcm`, `keyformat=raw`, `keylocation=file://…`
  set **at dataset creation** on `fast` (pool-level encryptionroot) and
  `tank/data`. `tank/media` left unencrypted. **These are immutable after
  creation** — must be right the first time.

### 5.3 Encryption key management

- One 32-byte random keyfile at `/etc/zfs/keys/polaris.key`, mode `0400`,
  owned by root, on the **ext4 root** (not on ZFS).
- Systemd loads the key and imports/mounts encrypted datasets at boot →
  unattended reboot, no passphrase prompt.
- **Threat model (state it plainly):** protects against theft/RMA of a *data
  drive*. Does **not** protect if the whole machine (incl. OS drive) is taken,
  since the key lives on the OS drive. Acceptable for a headless home server.
- The keyfile is **not** in Git. It is generated once during install and must be
  backed up securely (e.g. password manager) — losing it means losing access to
  encrypted datasets. This backup step goes in the runbook.

### 5.4 Swap

- Plain partition (`p4`, **8 GiB**) — **not** a ZFS zvol (zvol swap can deadlock
  under memory pressure). Small on purpose: the box has **64 GB RAM**, so swap is
  a safety valve, not a working store.
- Encrypted with a **random key per boot** (`randomEncryption`) so paged-out
  decrypted data isn't written in the clear. No hibernation (fine for a server).

### 5.5 ARC (RAM cache) sizing

ZFS's ARC defaults to using up to ~50% of RAM (~32 GB here). Fine for Phase 1.
Once VMs + services run (later phases), consider **capping ARC** (e.g.
`options zfs zfs_arc_max=<bytes>`) so it doesn't starve them. Left uncapped for
now with a documented tuning note in `modules/server/zfs.nix`.

### 5.6 Compression rationale (lz4 vs zstd)

Both are transparent and use ZFS early-abort on incompressible blocks, so neither
meaningfully hurts throughput. Trade-off: `lz4` = fastest / lowest CPU / modest
ratio; `zstd` (default `zstd-3`) = better ratio / more write CPU (decompress
stays fast). Mapping to datasets:
- `tank/media` → already-compressed video/audio won't shrink → **`lz4`** for max
  streaming/transcode headroom, zero downside.
- `tank/data`, `fast/appdata`, `fast/db` → compressible (docs, app state,
  databases) and CPU is plentiful → **`zstd`** to reclaim real space.

### 5.7 Failure behaviour (design intent)

- **1 NVMe fails:** OS reinstallable; `fast` survives degraded on the other
  mirror half; `tank` unaffected. No data loss.
- **1 HDD fails:** `tank` runs degraded; replace + resilver. No data loss.
- **OS corruption / reinstall:** wipe & rebuild NVMe1 via disko; `tank` and
  `fast` import untouched (`fast` briefly degraded, then resilver NVMe1's half).
  No data loss. (See runbook §11.)

## 6. disko strategy (the safety-critical decision)

**disko manages the OS disk (NVMe #1) only.** The `fast` and `tank` pools are
created once by hand (documented in the runbook) and **never declared as
disko-formatted resources** — the NixOS config merely imports/mounts them.

Rationale: disko's normal mode formats every disk in its config. By keeping the
data pools out of the disko config entirely, a from-scratch reinstall that runs
disko **cannot** destroy `tank` or `fast`. Combined with `fast` being a mirror
(so wiping NVMe1's half is non-fatal), the data pools are structurally protected
from the reinstall path.

- disko config declares NVMe1: `p1` ESP (vfat), `p2` ext4 `/`, `p3` a *raw*
  partition reserved for the fast mirror member (no content → disko creates the
  partition but not the pool), `p4` encrypted swap.
- `fast` and `tank` live in `hardware/polaris.nix` as ZFS `fileSystems`
  entries + `boot.zfs`/import settings, created manually per the runbook.

Trade-offs accepted: disko is an evolving flake input (pinned via `flake.lock`);
ZFS immutable properties must be correct on first creation; the layout is a bit
more abstract to debug than raw `sgdisk`. Mitigated by the disko VM test (§9).

## 7. Base OS configuration

Built with the existing **`mkServer`** builder (headless, no GUI), extended to
accept extra modules so we can inject disko + the ZFS/virtualisation modules
without affecting the existing `server`/`server-arm64` hosts.

### 7.1 System (host-specific — `machines/polaris.nix` + small reusable modules)

- **Bootloader:** systemd-boot + EFI (matches repo convention).
- **Kernel:** default **stable** `pkgs.linuxPackages` (ZFS-compatible). **Do NOT
  use `linuxPackages_latest`** — ZFS is out-of-tree and can lag new kernels.
  (Nixpkgs marks ZFS broken on unsupported kernels, so a bad combo fails at build
  time, not at runtime.)
- **Microcode:** `hardware.cpu.amd.updateMicrocode = true`.
- **Kernel params:** `amd_iommu=on iommu=pt` (IOMMU ready for future
  passthrough; `pt` = passthrough mode, negligible overhead now).
- **ZFS support** (`modules/server/zfs.nix`, reusable):
  - `boot.supportedFilesystems = [ "zfs" ]`.
  - `networking.hostId` = fixed 8-hex value (required by ZFS; recorded in
    `hardware/polaris.nix`).
  - `services.zfs.autoScrub.enable = true` (weekly), `services.zfs.trim.enable`.
  - Encrypted-dataset key loading at boot from the keyfile.
- **Virtualisation** (`modules/server/virtualisation.nix`, reusable):
  - `virtualisation.libvirtd.enable` + QEMU/OVMF/swtpm.
  - `virtualisation.docker.enable` (already in `nixos-server.nix`).
  - `mattias` in `libvirtd` + `docker` groups.
- **Networking:** static IP **`192.168.1.50`** on the primary NIC (gateway/DNS
  `192.168.1.1` assumed — adjust if your router differs). Configured via
  NetworkManager or `networking.interfaces` with a fixed address.
- **Time/locale:** `Europe/London`, `en_GB.UTF-8` (repo default).

### 7.2 User & remote access (reuse/extend `users/default/nixos-server.nix`)

- `mattias` normal user, zsh shell, groups `wheel docker libvirtd`.
- OpenSSH enabled, `PermitRootLogin = no`, **password auth disabled**, key-based
  only. `users.users.mattias.openssh.authorizedKeys.keys` = the 4 public keys
  from `https://github.com/mattiasgees.keys` (2× ecdsa-nistp256, 2× ed25519),
  embedded in the config. (Optionally kept fresh via
  `services.openssh.authorizedKeysFiles` or a fetch, but embedding is simplest
  and pure.)
- mosh enabled + UDP 60000–61000 firewall range (already present).
- `programs.ssh.startAgent = true`.

### 7.3 Shell environment (`home-manager-server.nix`, unchanged)

Reuse the existing headless home-manager profile as-is:
- Modules: `git-server`, `zsh-server`, `ssh`, `direnv-hm`, `nvim-server`.
- Packages: `pkgs/core.nix` + `pkgs/dev.nix` + `pkgs/kube.nix`.
- bash→zsh auto-switch shim.

No changes needed — this is the whole point of the shared server profile.

## 8. Repository integration

New/changed files:

| File | Purpose |
|------|---------|
| `flake.nix` | add `disko` input; add `nixosConfigurations.polaris` (+ `polaris-vm` aarch64 variant); pass `extraModules` to `mkServer` |
| `lib/mkserver.nix` | add optional `extraModules ? []` param, appended to `modules` (backward-compatible; existing hosts pass nothing) |
| `disko/polaris.nix` | disko config for NVMe #1 (ESP/root/fast-slot/swap) |
| `hardware/polaris.nix` | generated hardware config + ZFS pool `fileSystems`, `hostId`, boot modules |
| `machines/polaris.nix` | hostname, kernel, IOMMU params, AMD microcode, imports of the two reusable modules |
| `modules/server/zfs.nix` | reusable ZFS enablement (scrub/trim/keys) |
| `modules/server/virtualisation.nix` | reusable libvirt/KVM |
| `tests/polaris-disko.nix` | disko VM test (wired into `flake.checks`) |
| `docs/polaris/bios-checklist.md` | operator doc (from §4) |
| `docs/polaris/reinstall-runbook.md` | operator doc (from §11) |

Module boundary principle: keep **storage/hardware** (`hardware/`, `disko/`)
separate from **software/system** (`machines/`, `modules/server/`) so the
aarch64 VM variant can reuse the software layer without the real ZFS layout.

## 9. Testing strategy (full ladder)

**Layer 1 — build gate (mandatory)**
```
nix flake check
nixos-rebuild build --flake .#polaris   # via linux builder on the Mac
```

**Layer 2 — disko VM test (`flake.checks.polaris-disko`)**
A `nixosTest` using disko's test harness: creates small virtual disks matching
the topology (1 mirror + 1 raidz1), runs the disko config, creates the pools,
boots, and asserts:
- `zpool status fast` shows a healthy mirror; `tank` shows healthy raidz1.
- `tank/media`, `tank/data`, `fast/*` datasets exist and mount.
- encrypted datasets report `keystatus=available` after keyfile load.
- system reaches `multi-user.target` and `sshd` is up.
Run: `nix build .#checks.x86_64-linux.polaris-disko` (through the builder).

**Layer 3 — full-system smoke test on the M1**
- Add an **aarch64 `polaris-vm`** variant (shares the software layer, uses a
  VM disk stub, omits the real ZFS `fileSystems`).
- `nixos-rebuild build-vm --flake .#polaris-vm` → boot in QEMU/UTM natively.
- Confirm: boots, `mattias` shell works, SSH in, services enabled.

**Layer 4 — real-hardware checklist** (things VMs can't validate)
- IOMMU actually enabled (`dmesg | grep AMD-Vi`).
- A throwaway libvirt VM boots on the server (validates nested KVM on real HW).
- Keyfile boot path unlocks encrypted datasets on a real reboot.
- `zpool status` clean; a deliberate `zpool offline`/`online` resilver drill.

## 10. Roadmap (future phases, for context only)

- **Phase 2 — Media stack:** Plex + Sonarr + Radarr as native service users
  sharing a `media` group over `tank/media`; downloads on `tank`.
- **Phase 3 — Web apps:** Miniflux (native module), Outline + Karakeep
  (containers/systemd units), each its own user; state on `fast`.
- **Phase 4 — Backups:** ZFS snapshot policy (sanoid/zfs-autobackup) + off-box
  replication (`zfs send`).
- **Phase 5 (optional):** static networking hardening, root-on-ZFS migration,
  GPU passthrough, secure boot.

## 11. Reinstall / recovery runbook (summary — full doc in `docs/polaris/`)

**Golden rule:** never run disko against anything but NVMe #1. `tank`/`fast` are
imported, never re-created.

### 11.1 OS reinstall (disk intact, OS corrupt)
```
1. Boot NixOS installer USB.
2. git clone <this repo>; cd nixos-config.
3. Restore /etc/zfs/keys/polaris.key from your secure backup.
4. Run disko in destroy+format+mount mode against disko/polaris.nix
   (NVMe #1 ONLY — it does not reference tank/fast).
5. nixos-install --flake .#polaris.
6. Reboot. On boot: `zpool import tank` (untouched), `zpool import fast`
   (DEGRADED — NVMe1 half is blank).
7. Re-add NVMe1's fast member:
   `zpool replace fast <old-nvme1-partition-id> <new-nvme1-partition-id>`
   → resilvers from NVMe #2. Verify `zpool status fast` returns to ONLINE.
8. Load keys / verify auto-unlock: `zfs get keystatus tank/data fast`.
```
Result: zero data loss; `tank` never touched, `fast` resilvered from its mirror.

### 11.2 Single HDD failure
```
1. Identify failed disk: `zpool status tank`.
2. Physically replace it.
3. `zpool replace tank <old-id> <new-id>`; wait for resilver.
```

### 11.3 Single NVMe failure
- NVMe #2 fails: `fast` degraded → replace disk, `zpool replace fast …`.
- NVMe #1 fails: OS is gone → follow §11.1 (OS reinstall) with a new NVMe #1.

### 11.4 Routine health
- `zpool status`, `zpool list`, `zfs list` — weekly glance (autoScrub runs
  weekly automatically).
- Keep the keyfile backup current and the flake pushed to Git.

## 12. Resolved decisions & remaining assumptions

**Resolved**
- ✅ Host name: **`polaris`**.
- ✅ Static IP: **`192.168.1.50`**.
- ✅ SSH keys: the 4 public keys from `github.com/mattiasgees.keys`, embedded;
  key-only auth.
- ✅ Swap: **8 GiB** (64 GB RAM).
- ✅ Compression: **`zstd`** default, **`lz4`** on `tank/media`.

**Remaining assumptions (adjust if wrong; none block the plan)**
- Gateway/DNS `192.168.1.1` (typical home router default).
- OS/root size ~465 GiB (can shrink to grow `fast`).
- Primary NIC name — confirmed at install from `ip link` (used for the static
  IP binding).

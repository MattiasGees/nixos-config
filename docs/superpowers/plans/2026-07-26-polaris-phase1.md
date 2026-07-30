# polaris Home Server — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a headless AMD NixOS home server `polaris` to this flake — base OS, ZFS storage (fast NVMe mirror + tank RAIDZ1 with per-dataset encryption), the shared shell environment, plus an automated testing ladder and operator docs.

**Architecture:** `polaris` is built by the existing `mkServer` builder (extended to accept `extraModules`). The OS disk is partitioned declaratively with **disko** (ext4 root + ESP + encrypted swap + a raw slot for the fast mirror). The `fast` and `tank` ZFS pools are created by a parameterised script that is **not** in disko's destructive path — the NixOS config only imports them. Reusable `modules/server/{zfs,virtualisation}.nix` carry the ZFS + libvirt config. An aarch64 `polaris-vm` variant reuses the software layer for fast smoke-testing on the M1.

**Tech Stack:** Nix flakes, NixOS (`nixos-unstable`), home-manager, disko, ZFS (OpenZFS), libvirt/QEMU, `pkgs.testers.runNixOSTest`.

## Global Constraints

- Host name: **`polaris`**. Platform: **`x86_64-linux`**, **AMD** CPU.
- Root filesystem: **ext4** (disko-managed). Do **NOT** put root on ZFS.
- Kernel: **stable** `pkgs.linuxPackages`. Do **NOT** use `linuxPackages_latest` (ZFS is out-of-tree and can lag new kernels).
- disko manages **NVMe #1 only**. The `fast`/`tank` pools are **never** declared as disko-formatted resources — created by script, imported by config.
- Encryption: `aes-256-gcm`, `keyformat=raw`, key at `/etc/zfs/keys/polaris.key` (0400, on ext4 root). Encrypt `fast/*` and `tank/data`. Leave `tank/media` **unencrypted**. Encryption properties are immutable after dataset creation — get them right at creation.
- Compression: `zstd` default; **`lz4` on `tank/media`**.
- Swap: **8 GiB** plain partition, `randomEncryption` (no hibernation).
- Static IP **`192.168.1.50`** (gateway/DNS `192.168.1.1`).
- SSH: key-only (password auth off), `PermitRootLogin = no`. Authorized keys = the four from `github.com/mattiasgees.keys` (verbatim in Task 5).
- `networking.hostId` required by ZFS — a fixed 8-hex value in `hardware/polaris.nix`.
- Existing hosts (`server`, `server-arm64`, `desktop`, darwin) must keep building unchanged.
- Commit after every task. Work on the current `mattias` branch.

### Where verifications run

- **eval / parse** steps: run anywhere (macOS included; routes to the aarch64-linux builder for anything that needs a Linux build).
- **`x86_64-linux` builds and the disko/ZFS VM tests (Tasks 6, 8, 9):** these are x86_64-linux derivations. Run them on an **x86_64 Linux host** — the target server booted off the NixOS installer USB, an existing x86_64 NixOS box, or CI. They will **not** build natively on the aarch64 Mac.
- **`polaris-vm` (Task 10):** aarch64 — this is the Mac-runnable smoke test via `build-vm`.

---

## File Structure

| File | Responsibility | Task |
|------|----------------|------|
| `flake.nix` | add `disko` input; `polaris` + `polaris-vm` outputs; `flake.checks` | 1, 6, 8, 9, 10 |
| `lib/mkserver.nix` | accept optional `extraModules` | 1 |
| `modules/server/zfs.nix` | reusable ZFS enable: support, scrub/trim, key-load service | 2 |
| `modules/server/virtualisation.nix` | reusable libvirt/KVM + docker + IOMMU-ready | 2 |
| `disko/polaris-layout.nix` | `device -> disk layout` (shared by real config + disko test) | 3 |
| `disko/polaris.nix` | disko module binding the layout to the real OS NVMe | 3 |
| `hardware/polaris.nix` | hostId, kernel modules, ZFS pool import (real host only) | 4 |
| `machines/polaris.nix` | hostname, kernel, IOMMU, microcode, static IP, SSH keys, module imports | 5 |
| `scripts/create-zfs-pools.sh` | parameterised pool+dataset+key creation (operator + test) | 7 |
| `tests/polaris-zfs.nix` | VM test: run the pool script, assert pools/datasets/encryption | 8 |
| `tests/polaris-disko.nix` | VM test: disko OS-disk layout mounts | 9 |
| `hardware/polaris-vm.nix` | plain VM disk, DHCP, no pools (aarch64 smoke variant) | 10 |
| `machines/polaris-vm.nix` | reuse `machines/polaris.nix` software with VM overrides | 10 |
| `docs/polaris/bios-checklist.md` | operator BIOS/UEFI doc | 11 |
| `docs/polaris/reinstall-runbook.md` | operator reinstall/recovery doc | 11 |

---

## Task 1: Flake wiring — disko input + `mkServer` extraModules

**Files:**
- Modify: `flake.nix` (inputs + outputs arg list)
- Modify: `lib/mkserver.nix`

**Interfaces:**
- Produces: `mkServer name { …; extraModules ? [] }` — the extra modules are appended to the system's `modules` list. `disko` is available in `outputs`.

- [ ] **Step 1: Add the disko input.** In `flake.nix`, inside `inputs = { … }`, after the `xremap-flake` line, add:

```nix
      disko = {
        url = "github:nix-community/disko";
        inputs.nixpkgs.follows = "nixpkgs";
      };
```

- [ ] **Step 2: Expose disko in the outputs argument set.** Change the `outputs` line:

```nix
  outputs = inputs @ { self, xremap-flake, hyprland, nixpkgs, nixpkgs-unstable, home-manager, darwin, disko, ... }:
```

- [ ] **Step 3: Add the `extraModules` parameter to `mkServer`.** Replace line 3 of `lib/mkserver.nix`:

```nix
name: { pkgs, nixpkgs, lib, home-manager, system, user, extraModules ? [] }:
```

- [ ] **Step 4: Append `extraModules` to the modules list.** In `lib/mkserver.nix`, change the closing of the `modules = [ … ]` list (line 20) from `  ];` to:

```nix
  ] ++ extraModules;
```

- [ ] **Step 5: Verify the flake still evaluates and existing hosts are unaffected.**

Run: `NIX_CONFIG="experimental-features = nix-command flakes" nix flake metadata --impure`
Expected: resolves inputs including `disko`, no eval error.

Run: `NIX_CONFIG="experimental-features = nix-command flakes" nix eval --impure .#nixosConfigurations.server.config.system.build.toplevel.drvPath`
Expected: prints a `.drv` path (the existing `server` host still evaluates; `extraModules` defaults to `[]`).

- [ ] **Step 6: Commit.**

```bash
git add flake.nix flake.lock lib/mkserver.nix
git commit -m "feat(polaris): add disko input and mkServer extraModules param"
```

---

## Task 2: Reusable server modules (ZFS + virtualisation)

**Files:**
- Create: `modules/server/zfs.nix`
- Create: `modules/server/virtualisation.nix`

**Interfaces:**
- Produces: two importable NixOS modules. `zfs.nix` enables ZFS support, weekly scrub, trim, and a `zfs-load-key` oneshot that loads file-based encryption keys before mounts. `virtualisation.nix` enables libvirtd + docker and adds `mattias` to the `libvirtd`/`docker` groups. Neither references a specific pool or disk, so both are safe on any host (including the aarch64 VM).

- [ ] **Step 1: Create `modules/server/zfs.nix`.**

```nix
# Reusable ZFS enablement for servers.
# Pool definitions and hostId live in the host's hardware/<host>.nix — this
# module is pool-agnostic and safe to import anywhere.
{ pkgs, lib, ... }:
{
  boot.supportedFilesystems = [ "zfs" ];
  # Don't block boot prompting for encryption credentials: our encrypted
  # datasets are NOT needed for boot (root is ext4) and use file-based keys.
  boot.zfs.requestEncryptionCredentials = false;

  # Weekly scrub + periodic TRIM for pool health.
  services.zfs.autoScrub.enable = true;
  services.zfs.trim.enable = true;

  # Load file-based encryption keys after import, before ZFS mounts.
  # `zfs load-key -a` loads keys for every encrypted dataset whose
  # keylocation is a readable file (set at dataset creation).
  systemd.services.zfs-load-key = {
    description = "Load ZFS encryption keys from keyfiles";
    after = [ "zfs-import.target" ];
    before = [ "zfs-mount.service" ];
    wantedBy = [ "zfs-mount.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # `|| true`: don't fail activation if a key is already loaded or no
      # encrypted datasets exist yet (e.g. before pools are created).
      ExecStart = "${pkgs.zfs}/bin/zfs load-key -a";
      SuccessExitStatus = "0 1";
    };
  };

  # ARC sizing note: ZFS ARC defaults to ~50% of RAM (~32 GB on this 64 GB
  # box). Fine for Phase 1. When VMs/services arrive, cap it here, e.g.:
  #   boot.extraModprobeConfig = "options zfs zfs_arc_max=17179869184"; # 16 GiB
}
```

- [ ] **Step 2: Create `modules/server/virtualisation.nix`.**

```nix
# Reusable virtualisation stack: libvirt/KVM (for running VMs) + docker.
# IOMMU is enabled via kernel params in machines/polaris.nix; GPU passthrough
# is a later phase.
{ pkgs, ... }:
{
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      swtpm.enable = true;
      ovmf = {
        enable = true;
        packages = [ pkgs.OVMFFull.fd ];
      };
    };
    onBoot = "ignore";
    onShutdown = "shutdown";
  };

  virtualisation.docker.enable = true;

  users.users.mattias.extraGroups = [ "libvirtd" "docker" ];
}
```

- [ ] **Step 3: Verify both files parse.**

Run: `nix-instantiate --parse modules/server/zfs.nix >/dev/null && nix-instantiate --parse modules/server/virtualisation.nix >/dev/null && echo OK`
Expected: `OK` (no syntax errors).

- [ ] **Step 4: Commit.**

```bash
git add modules/server/zfs.nix modules/server/virtualisation.nix
git commit -m "feat(polaris): reusable server ZFS and virtualisation modules"
```

---

## Task 3: disko OS-disk layout (NVMe #1 only)

**Files:**
- Create: `disko/polaris-layout.nix`
- Create: `disko/polaris.nix`

**Interfaces:**
- Produces: `disko/polaris-layout.nix` is a function `device -> <disko disk attrset>`. `disko/polaris.nix` is a NixOS module setting `disko.devices.disk.os` to that layout for the real OS NVMe. The `fast` mirror member is a **raw partition** (no content) with stable partlabel `disk-os-fastmember` — disko creates the partition but not the pool.

- [ ] **Step 1: Create `disko/polaris-layout.nix`** (shared by the real config and the disko test).

```nix
# device -> disko layout for the OS NVMe.
# Partitions: ESP (/boot), ext4 root (/), encrypted swap, and a RAW partition
# reserved for the `fast` ZFS mirror member. The raw partition has NO content
# so disko creates the partition but never touches the pool.
device:
{
  type = "disk";
  inherit device;
  content = {
    type = "gpt";
    partitions = {
      ESP = {
        size = "1G";
        type = "EF00";
        content = {
          type = "filesystem";
          format = "vfat";
          mountpoint = "/boot";
          mountOptions = [ "umask=0077" ];
        };
      };
      root = {
        size = "450G";
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/";
        };
      };
      swap = {
        size = "8G";
        content = {
          type = "swap";
          randomEncryption = true;
        };
      };
      fastmember = {
        # Fills the rest of the 1 TB drive (~470 GiB). Raw: no content, so
        # disko leaves it unformatted for the manually-created `fast` mirror.
        size = "100%";
      };
    };
  };
}
```

- [ ] **Step 2: Create `disko/polaris.nix`** binding the layout to the real disk.

```nix
# disko config for polaris' OS disk ONLY. The tank/fast pools are created by
# scripts/create-zfs-pools.sh and are deliberately absent here so a reinstall
# that runs disko cannot destroy them.
{ ... }:
{
  # INSTALL-TIME VALUE: replace with the real by-id path from the target
  # machine, found via `ls -l /dev/disk/by-id/ | grep nvme`. Using by-id (not
  # /dev/nvme0n1) keeps the layout stable across reboots/reorders.
  disko.devices.disk.os =
    import ./polaris-layout.nix "/dev/disk/by-id/REPLACE_ME_NVME1";
}
```

- [ ] **Step 3: Verify both parse.**

Run: `nix-instantiate --parse disko/polaris-layout.nix >/dev/null && nix-instantiate --parse disko/polaris.nix >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 4: Commit.**

```bash
git add disko/polaris-layout.nix disko/polaris.nix
git commit -m "feat(polaris): disko OS-disk layout (ext4 root + ESP + swap + fast slot)"
```

---

## Task 4: `hardware/polaris.nix` — hostId, kernel modules, pool import

**Files:**
- Create: `hardware/polaris.nix`

**Interfaces:**
- Consumes: partitions/filesystems for `/`, `/boot`, swap come from the disko module (Task 3) — do **not** redefine them here.
- Produces: `networking.hostId`, initrd/kernel modules for AMD + NVMe/SATA, and `boot.zfs.extraPools = [ "tank" "fast" ]` so the manually-created pools import at boot. Dataset mounts use ZFS-native mountpoints (set by the pool script), so no `fileSystems` entries for them.

- [ ] **Step 1: Create `hardware/polaris.nix`.**

```nix
# Real-hardware config for polaris. Disk PARTITIONS/filesystems (/,/boot,swap)
# are provided by disko/polaris.nix — not here. This file adds the bits disko
# doesn't: hostId, kernel modules, and import of the manually-created pools.
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # INSTALL-TIME: replace this list with the real box's output from
  #   nixos-generate-config --no-filesystems --show-hardware-config
  # (--no-filesystems omits the fileSystems/swapDevices block that disko owns,
  # so it merges here without conflicting). Values below are an AMD+NVMe default.
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # Required by ZFS. INSTALL-TIME: pick a unique value with
  #   head -c 8 /dev/urandom | od -A none -t x1 | tr -d ' '   (use first 8 hex)
  networking.hostId = "a11c3b0d";

  # Import the manually-created pools at boot (they back no `fileSystems`
  # entries because their datasets use ZFS-native mountpoints).
  boot.zfs.extraPools = [ "tank" "fast" ];

  # No swapDevices / fileSystems here — disko owns them.
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
```

- [ ] **Step 2: Verify it parses.**

Run: `nix-instantiate --parse hardware/polaris.nix >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit.**

```bash
git add hardware/polaris.nix
git commit -m "feat(polaris): hardware config — hostId, AMD/NVMe modules, pool import"
```

---

## Task 5: `machines/polaris.nix` — system config

**Files:**
- Create: `machines/polaris.nix`

**Interfaces:**
- Consumes: `modules/server/zfs.nix`, `modules/server/virtualisation.nix` (Task 2).
- Produces: hostname, stable kernel, IOMMU kernel params, AMD microcode, static IP, and `mattias`'s SSH authorized keys. Reused by the aarch64 `polaris-vm` variant (Task 10), so it contains **no** disk/pool/hostId specifics (those are in `hardware/polaris.nix`).

- [ ] **Step 1: Create `machines/polaris.nix`.** The four authorized keys are copied verbatim from `github.com/mattiasgees.keys`.

```nix
{ config, pkgs, lib, ... }:
{
  imports = [
    ../modules/server/zfs.nix
    ../modules/server/virtualisation.nix
  ];

  networking.hostName = "polaris";

  # Stable kernel (NOT linuxPackages_latest — keep ZFS compatibility).
  boot.kernelPackages = pkgs.linuxPackages;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # IOMMU on now (ready for future GPU passthrough); pt = passthrough mode.
  boot.kernelParams = [ "amd_iommu=on" "iommu=pt" ];

  # Static IP. INSTALL-TIME: confirm the NIC name with `ip -o link` and adjust.
  networking.useDHCP = lib.mkDefault false;
  networking.interfaces.enp4s0.ipv4.addresses = [
    { address = "192.168.1.50"; prefixLength = 24; }
  ];
  networking.defaultGateway = "192.168.1.1";
  networking.nameservers = [ "192.168.1.1" ];

  # SSH: key-only. Keys from github.com/mattiasgees.keys (2x ecdsa, 2x ed25519).
  users.users.mattias.openssh.authorizedKeys.keys = [
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBKkdI6stPG4bOv3p72OsEDxs9o3jrg3Lacsook0VGkzaUcDYC2jXE4gvJtfP7UwTmVxsRJD4YJ8NGxuuRustJh0="
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFtGUiGsLHfTl/Jb5TvKK7ReZ+qa6eT8+Jd3ZbKyE+nYstbN1ZKimi8ojjlrR+NREqV4J3aG8K0e1Pmi2Mfkp Sk="
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBt3dIJVLAvj2IrWprwngbshWN0kwwmbB64GSQsHonqd"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBKfSjZEPrxBJsLTkOiZ6yJiGnjwmVg+YN58J0o+a/29"
  ];
  services.openssh.settings.PasswordAuthentication = false;
}
```

> **NOTE for the implementer:** the second ecdsa key above must have **no space** before `Sk=`. It is shown wrapped only for the page — join it into one token: `…2MfkpSk=`. Verify the final file has exactly four keys, each on one line, no internal spaces in the base64.

- [ ] **Step 2: Verify it parses.**

Run: `nix-instantiate --parse machines/polaris.nix >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit.**

```bash
git add machines/polaris.nix
git commit -m "feat(polaris): system config — kernel, IOMMU, static IP, SSH keys"
```

---

## Task 6: Wire `nixosConfigurations.polaris` + build gate (integration checkpoint)

**Files:**
- Modify: `flake.nix` (add the output)

**Interfaces:**
- Consumes: `mkServer` extraModules (Task 1), `disko` input (Task 1), all files from Tasks 2–5.
- Produces: `nixosConfigurations.polaris`. First point the whole system builds.

- [ ] **Step 1: Add the output.** In `flake.nix`, after the `nixosConfigurations.server-arm64 = …;` block, add:

```nix
      nixosConfigurations.polaris = mkServer "polaris" rec {
        inherit home-manager user nixpkgs system pkgs;
        lib = pkgs.lib;
        extraModules = [
          disko.nixosModules.disko
          ./disko/polaris.nix
        ];
      };
```

- [ ] **Step 2: Evaluate the config (fast check, runs anywhere).**

Run: `NIX_CONFIG="experimental-features = nix-command flakes" nix eval --impure .#nixosConfigurations.polaris.config.networking.hostName`
Expected: `"polaris"`.

- [ ] **Step 3: Build the whole system (run on an x86_64 Linux host — see "Where verifications run").**

Run: `NIX_CONFIG="experimental-features = nix-command flakes" nix build --impure .#nixosConfigurations.polaris.config.system.build.toplevel`
Expected: builds to `./result` with no errors. (Device paths are placeholders — irrelevant at build time; they're only read at activation/boot.)

If evaluation fails on an option conflict (e.g. a `fileSystems."/"` defined in two places), the fix is almost always that a filesystem is declared both in disko and in `hardware/polaris.nix` — remove it from `hardware/polaris.nix`.

- [ ] **Step 4: Commit.**

```bash
git add flake.nix
git commit -m "feat(polaris): wire nixosConfigurations.polaris; system builds"
```

---

## Task 7: Pool-creation script

**Files:**
- Create: `scripts/create-zfs-pools.sh`

**Interfaces:**
- Produces: `create-zfs-pools.sh <fast_dev_a> <fast_dev_b> <hdd1> <hdd2> <hdd3>` — generates the keyfile if absent, creates the encrypted `fast` mirror (`fast/appdata`, `fast/db`) and the `tank` RAIDZ1 (`tank/media` unencrypted+lz4, `tank/data` encrypted), all with ZFS-native mountpoints under `/mnt`. Consumed by the operator (real by-id devices) and by the Task 8 VM test (VM devices).

- [ ] **Step 1: Create `scripts/create-zfs-pools.sh`.**

```bash
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
```

- [ ] **Step 2: Make it executable and lint it.**

Run: `chmod +x scripts/create-zfs-pools.sh && bash -n scripts/create-zfs-pools.sh && echo OK`
Expected: `OK` (no bash syntax errors).

- [ ] **Step 3: Commit.**

```bash
git add scripts/create-zfs-pools.sh
git commit -m "feat(polaris): ZFS pool/dataset creation script"
```

---

## Task 8: ZFS pool VM test (validates the script + encryption)

**Files:**
- Create: `tests/polaris-zfs.nix`
- Modify: `flake.nix` (add `checks`)

**Interfaces:**
- Consumes: `scripts/create-zfs-pools.sh` (Task 7), `modules/server/zfs.nix` (Task 2).
- Produces: `checks.x86_64-linux.polaris-zfs` — a `runNixOSTest` that attaches 5 virtual disks, runs the script, and asserts pools/datasets/encryption. This is the safety net for the riskiest logic.

- [ ] **Step 1: Create `tests/polaris-zfs.nix`.**

```nix
# VM test: run the pool-creation script on virtual disks and assert the
# resulting ZFS topology, mountpoints, and encryption state.
{ pkgs, ... }:
let
  createScript = ../scripts/create-zfs-pools.sh;
in
pkgs.testers.runNixOSTest {
  name = "polaris-zfs";
  nodes.machine = { ... }: {
    imports = [ ../modules/server/zfs.nix ];
    networking.hostId = "deadbeef";
    # 2 disks for the fast mirror + 3 for the tank raidz1 => vdb..vdf.
    virtualisation.emptyDiskImages = [ 512 512 2048 2048 2048 ];
    environment.systemPackages = [ pkgs.zfs ];
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "bash ${createScript} /dev/vdb /dev/vdc /dev/vdd /dev/vde /dev/vdf"
    )
    # Topology
    machine.succeed("zpool status fast | grep -q mirror")
    machine.succeed("zpool status tank | grep -q raidz1")
    # Datasets exist and are mounted
    machine.succeed("zfs list tank/media tank/data fast/appdata fast/db")
    machine.succeed("mountpoint /mnt/media")
    machine.succeed("mountpoint /mnt/data")
    machine.succeed("mountpoint /mnt/fast/appdata")
    # Encryption: data encrypted + key available; media unencrypted
    machine.succeed("zfs get -H -o value keystatus tank/data | grep -q available")
    machine.succeed("zfs get -H -o value encryption tank/data | grep -q aes")
    machine.succeed("zfs get -H -o value encryption tank/media | grep -q off")
    # Compression choices
    machine.succeed("zfs get -H -o value compression tank/media | grep -q lz4")
    machine.succeed("zfs get -H -o value compression tank/data | grep -q zstd")
    # Reboot -> key auto-loads (zfs-load-key.service) and datasets re-mount
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("zfs-mount.service")
    machine.succeed("zfs get -H -o value keystatus tank/data | grep -q available")
    machine.succeed("mountpoint /mnt/data")
  '';
}
```

- [ ] **Step 2: Add a `checks` output to `flake.nix`.** After the `darwinConfigurations.macbook-x86 = …;` block (still inside the `outputs` attrset), add:

```nix
      checks.x86_64-linux.polaris-zfs =
        import ./tests/polaris-zfs.nix { inherit pkgs; };
```

- [ ] **Step 3: Build the check (run on an x86_64 Linux host).**

Run: `NIX_CONFIG="experimental-features = nix-command flakes" nix build --impure .#checks.x86_64-linux.polaris-zfs -L`
Expected: the VM test runs and passes (all `machine.succeed` assertions hold, including the post-reboot key auto-load).

If the post-reboot key check fails, the `zfs-load-key` unit ordering in `modules/server/zfs.nix` needs adjustment (ensure `before = [ "zfs-mount.service" ]` and `after = [ "zfs-import.target" ]`). Iterate here — this test is exactly why it exists.

- [ ] **Step 4: Commit.**

```bash
git add tests/polaris-zfs.nix flake.nix
git commit -m "test(polaris): VM test for ZFS pools, datasets, and encryption"
```

---

## Task 9: disko OS-disk VM test

**Files:**
- Create: `tests/polaris-disko.nix`
- Modify: `flake.nix` (add `checks`)

**Interfaces:**
- Consumes: `disko/polaris-layout.nix` (Task 3), the `disko` input.
- Produces: `checks.x86_64-linux.polaris-disko` — boots the disko OS-disk layout on a virtual disk and asserts `/`, `/boot`, and swap are active.

- [ ] **Step 1: Create `tests/polaris-disko.nix`.** disko ships a test helper `disko.lib.testLib.makeDiskoTest`. Reference: <https://github.com/nix-community/disko/blob/master/docs/reference.md> (search "testLib"). The layout is bound to the test disk `/dev/vdb`.

```nix
{ pkgs, disko }:
disko.lib.testLib.makeDiskoTest {
  inherit pkgs;
  name = "polaris-disko";
  disko-config = {
    disko.devices.disk.os = import ../disko/polaris-layout.nix "/dev/vdb";
  };
  # The layout uses an EFI System Partition -> boot the test VM in UEFI mode.
  efi = true;
  extraTestScript = ''
    machine.succeed("mountpoint /")
    machine.succeed("mountpoint /boot")
    machine.succeed("test \"$(stat -f -c %T /)\" = ext2/ext3")
    machine.succeed("swapon --show=NAME --noheadings | grep -q .")
  '';
}
```

- [ ] **Step 2: Add the check to `flake.nix`.** Next to the Task-8 check:

```nix
      checks.x86_64-linux.polaris-disko =
        import ./tests/polaris-disko.nix { inherit pkgs disko; };
```

- [ ] **Step 3: Build the check (x86_64 Linux host).**

Run: `NIX_CONFIG="experimental-features = nix-command flakes" nix build --impure .#checks.x86_64-linux.polaris-disko -L`
Expected: disko partitions the virtual disk, the VM boots, and `/`, `/boot`, and swap are active.

If `makeDiskoTest`'s argument names differ in the pinned disko version, check the reference doc above and adjust (`efi`/`bios`, `disko-config` vs `disko-config.disko`). The layout attrset itself (from `polaris-layout.nix`) does not change.

- [ ] **Step 4: Commit.**

```bash
git add tests/polaris-disko.nix flake.nix
git commit -m "test(polaris): VM test for disko OS-disk layout"
```

---

## Task 10: aarch64 `polaris-vm` smoke variant (M1)

**Files:**
- Create: `hardware/polaris-vm.nix`
- Create: `machines/polaris-vm.nix`
- Modify: `flake.nix` (add the output)

**Interfaces:**
- Consumes: `machines/polaris.nix` software layer (Task 5).
- Produces: `nixosConfigurations.polaris-vm` (aarch64-linux) that reuses the software/services but drops the real ZFS/disk layout, for `nixos-rebuild build-vm` on the Mac.

- [ ] **Step 1: Create `hardware/polaris-vm.nix`** (minimal; no pools, DHCP-friendly).

```nix
# Throwaway hardware profile for the aarch64 build-vm smoke test.
# No ZFS pools, no static disks — build-vm supplies a virtual root disk.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
  networking.hostId = "0badf00d";
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
```

- [ ] **Step 2: Create `machines/polaris-vm.nix`** reusing the software layer with VM-safe overrides.

```nix
# Reuses the polaris software/system config but overrides host-specific bits
# that don't apply to a throwaway VM (static IP, hostname, AMD-only params).
{ lib, pkgs, ... }:
{
  imports = [ ./polaris.nix ];

  networking.hostName = lib.mkForce "polaris-vm";

  # VM uses NAT/DHCP, not the static LAN address.
  networking.useDHCP = lib.mkForce true;
  networking.interfaces = lib.mkForce { };
  networking.defaultGateway = lib.mkForce null;
  networking.nameservers = lib.mkForce [ ];

  # Drop AMD/x86 IOMMU kernel params on aarch64.
  boot.kernelParams = lib.mkForce [ ];

  # Give the VM a login you can use interactively.
  users.users.mattias.initialPassword = lib.mkForce "polaris";
}
```

- [ ] **Step 3: Add the aarch64 output to `flake.nix`.** After the `nixosConfigurations.polaris = …;` block:

```nix
      nixosConfigurations.polaris-vm = mkServer "polaris-vm" rec {
        inherit home-manager user nixpkgs;
        system = "aarch64-linux";
        pkgs = import nixpkgs {
          system = "aarch64-linux";
          config = { allowUnfree = true; allowInsecure = true; };
        };
        lib = pkgs.lib;
      };
```

- [ ] **Step 4: Build the VM (on the M1).**

Run: `NIX_CONFIG="experimental-features = nix-command flakes" nixos-rebuild build-vm --flake .#polaris-vm --impure`
Expected: produces `./result/bin/run-polaris-vm-vm`.

- [ ] **Step 5: Boot it and smoke-test.**

Run: `./result/bin/run-polaris-vm-vm`
Expected: VM boots to a login prompt; log in as `mattias` / `polaris`; `systemctl is-system-running` is `running` or `degraded` (degraded is acceptable if it's only the absent ZFS pools); `zsh` is the shell; `kubectl version --client` and `git --version` work (shell env present). Close the VM window to exit.

- [ ] **Step 6: Commit.**

```bash
git add hardware/polaris-vm.nix machines/polaris-vm.nix flake.nix
git commit -m "feat(polaris): aarch64 polaris-vm smoke variant for M1"
```

---

## Task 11: Operator docs — BIOS checklist + reinstall runbook

**Files:**
- Create: `docs/polaris/bios-checklist.md`
- Create: `docs/polaris/reinstall-runbook.md`

**Interfaces:**
- Consumes: spec §4 and §11; `scripts/create-zfs-pools.sh` (Task 7); `disko/polaris.nix` (Task 3).
- Produces: two human-facing runbooks. No code verification — these gate on accuracy review.

- [ ] **Step 1: Create `docs/polaris/bios-checklist.md`** from spec §4 (copy the Required/Recommended lists verbatim, plus the post-install verification commands).

- [ ] **Step 2: Create `docs/polaris/reinstall-runbook.md`** with these sections (expand from spec §11 — the OS reinstall procedure MUST reference running disko against NVMe #1 only and importing `tank`/`fast`):

  - **Fresh install** (first-time provisioning):
    1. Set BIOS per `bios-checklist.md`.
    2. Boot NixOS installer; `git clone` this repo.
    3. Fill install-time values: real by-id device in `disko/polaris.nix`, `networking.hostId` in `hardware/polaris.nix`, NIC name in `machines/polaris.nix`.
    4. `nix run github:nix-community/disko -- --mode disko ./disko/polaris.nix` (partitions NVMe #1, mounts under `/mnt`).
    5. Run `scripts/create-zfs-pools.sh` with the real by-id devices (fast member = `/dev/disk/by-partlabel/disk-os-fastmember`, plus NVMe #2 and the 3 HDDs). **Back up `/etc/zfs/keys/polaris.key`.**
    6. `nixos-install --flake .#polaris`; set a root/user password if prompted; reboot.
  - **OS reinstall (disks intact)** — the exact spec §11.1 steps: restore the keyfile, run disko against **NVMe #1 only**, `nixos-install`, then `zpool import tank`, `zpool import fast` (degraded), `zpool replace fast <old-nvme1-part> <new-nvme1-part>`, resilver. Emphasise: **never run disko or the pool script against the HDDs or NVMe #2 on a reinstall.**
  - **Single HDD failure**: `zpool status tank` → replace disk → `zpool replace tank <old> <new>` → wait for resilver.
  - **Single NVMe failure**: NVMe #2 → `zpool replace fast`; NVMe #1 → follow OS reinstall.
  - **Routine health**: `zpool status`, `zfs list`; weekly autoScrub runs automatically; keep the keyfile backup and the flake pushed.

- [ ] **Step 3: Verify internal links/paths resolve.**

Run: `grep -R "create-zfs-pools.sh\|disko/polaris.nix\|polaris.key" docs/polaris/ && echo OK`
Expected: references present; `OK`.

- [ ] **Step 4: Commit.**

```bash
git add docs/polaris/
git commit -m "docs(polaris): BIOS checklist and reinstall/recovery runbook"
```

---

## Task 12 (OPERATOR, on real hardware): provision `polaris`

> **Not agent-executable** — physical steps on the target machine. Do this only
> after Tasks 1–11 are green. Follow `docs/polaris/reinstall-runbook.md`
> "Fresh install", then complete the **real-hardware checklist** (spec Layer 4):

- [ ] BIOS set per `docs/polaris/bios-checklist.md`.
- [ ] `nixos-generate-config --no-filesystems --show-hardware-config` on the box
      (the `--no-filesystems` flag omits the `fileSystems`/`swapDevices` block
      that disko owns, so it merges cleanly); replace
      `boot.initrd.availableKernelModules` in `hardware/polaris.nix` with its
      output; set the real `networking.hostId` and the real NVMe by-id in
      `disko/polaris.nix`; confirm the NIC name in `machines/polaris.nix`.
      Commit any changes.
- [ ] Fresh install completed; system reboots headless.
- [ ] `ssh mattias@192.168.1.50` works with your key; password auth refused.
- [ ] `dmesg | grep -i -e IOMMU -e AMD-Vi` shows IOMMU enabled.
- [ ] `zpool status` clean; `zfs get keystatus tank/data fast` = `available`
      after a real reboot (keyfile auto-unlock works).
- [ ] A throwaway libvirt VM boots (`virt-install`/`virsh`) — validates nested
      KVM on real hardware.
- [ ] Keyfile `/etc/zfs/keys/polaris.key` backed up securely.
- [ ] Deliberate resilver drill: `zpool offline tank <disk>` then
      `zpool online tank <disk>`; confirm `zpool status` returns to healthy.

---

## Self-Review Notes

- **Spec coverage:** §3 hardware → Tasks 4/5; §4 BIOS → Task 11; §5 storage
  (layout/datasets/encryption/swap/ARC/compression) → Tasks 3,4,7,8; §6 disko
  strategy → Tasks 3,9; §7 base OS (kernel/ZFS/virt/user/SSH/shell) → Tasks
  2,5,6 (shell is inherited unchanged via `mkServer`'s `home-manager-server.nix`);
  §8 repo integration → all; §9 testing ladder → Tasks 6 (build gate), 8+9 (VM
  tests), 10 (aarch64 smoke), 12 (real-hardware checklist); §11 runbook → Task
  11; §12 resolved values → Global Constraints.
- **Install-time values** (real device by-id, hostId, NIC name) are explicitly
  flagged as INSTALL-TIME, not lazy placeholders — they are physical facts of
  the target machine, substituted in Task 12, and do not block Tasks 1–11
  (build/eval/VM tests use placeholders or VM devices).
- **Type consistency:** pool/dataset names (`fast`, `fast/appdata`, `fast/db`,
  `tank`, `tank/media`, `tank/data`), mountpoints (`/mnt/...`), keyfile path
  (`/etc/zfs/keys/polaris.key`), and the disko partlabel
  (`disk-os-fastmember`) are used identically across Tasks 3, 4, 7, 8, 11.
- **Shell environment** needs no task: `mkServer` already imports
  `users/default/home-manager-server.nix`, satisfying success criterion #3.

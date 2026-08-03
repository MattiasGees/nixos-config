# vmctl — a KVM VM lab for polaris

**Date:** 2026-08-03
**Status:** Design approved, pending spec review
**Target host:** `polaris` (x86_64 NixOS server, `192.168.1.50/24`)

## Goal

An easy, imperative CLI for spinning up throwaway experimentation VMs on
polaris via QEMU/KVM. Create/destroy/list VMs that:

- run one of two base OSes: **Ubuntu LTS** or **NixOS**,
- take user-chosen **CPU**, **memory**, and **static IP** on the home LAN,
- come up with **consistent IP addresses** across reboots,
- are **idempotent** to create (a second `create` of an existing VM is a no-op),
- store their disks on the ZFS **`scratch`** pool, **thin-provisioned**
  (grow-on-demand, not preallocated).

## Non-goals

- No declarative/git-tracked VM registry — state lives in libvirt on polaris
  only (explicit choice: maximise spur-of-the-moment experimentation).
- No mirroring/durability for VM disks (scratch is disposable by design).
- No GPU passthrough (polaris is IOMMU-ready for a future phase; out of scope).
- No provider abstraction / cloud targets — libvirt/KVM on polaris only.

## Existing foundation (already in the repo)

- `modules/server/virtualisation.nix` already enables `libvirtd` + `qemu_kvm`
  + `swtpm`, and adds `mattias` to the `libvirtd` group. **Reused as-is.**
- `machines/polaris.nix` already sets `iommu=pt` and a **static IP directly on
  `enp6s0`** — this is the part that must change for bridging (see below).
- `hardware/polaris-extra.nix` imports the ZFS `scratch` pool.

## Architecture overview

`vmctl` is a Go (Cobra) CLI, run over SSH on polaris, that orchestrates the
existing libvirt/KVM stack by **shelling out** to `virt-install`, `virsh`,
`qemu-img`, and `cloud-localds` (no libvirt cgo bindings). VMs bridge onto the
LAN and receive their static IP + SSH key + hostname at first boot via
**cloud-init** (NoCloud seed ISO). libvirt is the single source of truth;
OS and IP (which libvirt does not natively track for bridged/static guests)
are stored in the domain XML `<metadata>` block.

```
SSH to polaris ─► vmctl (Go/Cobra)
                    │  shells out to:
                    ├─ virt-install   (define + start domain, bridged NIC)
                    ├─ virsh          (list/start/stop/console/undefine/metadata)
                    ├─ qemu-img       (create qcow2 overlay on scratch)
                    └─ cloud-localds  (build NoCloud seed.iso)

Disks / images on ZFS scratch:  /var/lib/vmctl  (dataset scratch/vms, see §Disk layout)
Network:  br0 (bridges enp6s0) ── VMs get 192.168.1.x static IPs on the LAN
```

## Component 1 — Networking change (bridge)

**Problem:** bridged VMs cannot share the physical `enp6s0`; the host must move
its address onto a bridge.

**Change (in `machines/polaris.nix`, declarative NixOS — `vmctl` never edits
networking):**

- Create `br0` and enslave `enp6s0`:
  `networking.bridges.br0.interfaces = [ "enp6s0" ];`
- Move the static address off `enp6s0` onto `br0`:
  `192.168.1.50/24`, gateway `192.168.1.1`, DNS `192.168.1.1`.
- VMs attach with `virt-install --network bridge=br0,model=virtio`.

**Risk:** this touches polaris's live networking; a bad rebuild can drop SSH.
Mitigation: apply with out-of-band/console access available, and verify the
host keeps `192.168.1.50` and its default route after switch. Called out again
in the implementation plan.

**Firewall/sysctl:** bridged guest traffic is largely independent of the host
firewall, but validate on-host that guests reach the LAN/gateway after the
switch; add `boot.kernel.sysctl` bridge tweaks only if a concrete problem
appears (do not pre-add speculative settings).

## Component 2 — Disk & image layout on `scratch`

A dedicated ZFS dataset for VM storage (exact mountpoint confirmed on-host
against polaris's `/srv` native-mountpoint layout during implementation;
referred to here as `$VMROOT`, default target `scratch/vms`):

```
$VMROOT/
  base/
    ubuntu-24.04-server-cloudimg-amd64.qcow2   # downloaded, pinned URL + sha256
    nixos-base.qcow2                            # built from this flake (see §Comp 3)
  disks/
    <name>.qcow2                                # per-VM qcow2 OVERLAY, backing = base
  seeds/
    <name>-seed.iso                             # per-VM NoCloud cloud-init seed
```

- Per-VM disk = **qcow2 overlay with `backing_file` = the base image** →
  instant creation, thin growth-on-demand, shared read-only base.
  `qemu-img create -f qcow2 -F qcow2 -b <base> disks/<name>.qcow2 <disk-size>`.
- `--disk` sets the **virtual max** (default **20G**); real usage grows as
  written. `destroy` deletes the overlay + seed (base image is retained/cached).

## Component 3 — Base images

- **Ubuntu LTS:** official cloud image, downloaded on first use to `base/`,
  pinned by URL + sha256 checksum, verified before use.
- **NixOS:** `nixos-base.qcow2` built from this flake via **nixos-generators**
  (`format = qcow`), defined under `pkgs/vm-images/nixos-base.nix`, with:
  - `services.cloud-init.enable = true;` (so it consumes the same NoCloud seed),
  - serial console enabled (for `vmctl console`),
  - minimal base (SSH server; user/keys come from cloud-init at boot).
  Referenced by store path so it is pinned to the repo's nixpkgs. `vmctl`
  copies it into `base/` on first NixOS create if absent.

## Component 4 — Provisioning flow (`vmctl create`)

```
vmctl create <name> --ip <ip> [--os ubuntu|nixos] [--cpu N] [--mem SIZE] [--disk SIZE]
```

Required: `<name>`, `--ip`. Defaults: `--os ubuntu`, `--cpu 2`, `--mem 2G`,
`--disk 20G`.

1. **Idempotency:** if domain `<name>` already exists → print its details and
   exit 0 (no-op).
2. **Base image:** ensure present (download+verify Ubuntu, or copy the
   flake-built NixOS image) into `base/`.
3. **Overlay disk:** `qemu-img create` a qcow2 overlay backed by the base.
4. **cloud-init seed:** generate a NoCloud seed ISO via `cloud-localds`
   carrying:
   - **meta-data:** instance-id + hostname = `<name>`,
   - **user-data:** the SSH public key(s) reused from
     `github.com/mattiasgees.keys` (same keys authorised on polaris), user
     `mattias`, passwordless sudo,
   - **network-config:** static `--ip`/24, gateway `192.168.1.1`,
     DNS `192.168.1.1`.
5. **Define + start:** `virt-install` the domain — bridged `br0` virtio NIC,
   virtio system disk + seed CD-ROM, `--autostart` (survive host reboot),
   `--osinfo`/variant set appropriately, `--noautoconsole`.
6. **Persist metadata:** write `os` and `ip` into the domain XML `<metadata>`
   (custom namespace) via `virsh metadata`.
7. Print the new VM's details.

## Component 5 — Subcommands

| Command | Behaviour |
|---|---|
| `create` | Idempotent create (above). |
| `destroy <name>` | `virsh destroy` (if running) + `undefine --nvram`, delete overlay + seed. Confirm prompt unless `--force`. |
| `list` | Table: NAME, OS, CPU, MEM, IP, STATE. OS/IP read from `<metadata>`; CPU/MEM/STATE from libvirt. |
| `info <name>` | One-VM detail: os, cpu, mem, ip, state, disk used vs virtual max (`qemu-img info`), backing image. |
| `ssh <name>` | `exec ssh mattias@<ip>` (IP from `<metadata>`). |
| `start <name>` | `virsh start` (disk + IP preserved). |
| `stop <name>` | `virsh shutdown` (graceful; `--force` → `destroy`). |
| `console <name>` | `exec virsh console <name>` (serial). |

## Component 6 — Packaging & wiring

- **Package:** `pkgs/vmctl/` — a Go module built with `buildGoModule`
  (Cobra dependency; `vendorHash` maintained). Runtime dependencies
  (`libvirt`/`virsh`, `virt-install`, `qemu-img`, `cloud-utils`/`cloud-localds`,
  `openssh`, `coreutils`) wrapped onto `PATH` via `makeWrapper` so the binary
  finds them regardless of system profile.
- **Wiring:** new `modules/server/vmctl.nix` adds the package to
  `environment.systemPackages` and is imported by `machines/polaris.nix`
  (alongside the existing `modules/server/*`). It also declares/creates the
  `$VMROOT` directory (ZFS dataset management stays with the existing pool;
  the module ensures the path + ownership).

## Data / metadata model

- **Source of truth:** libvirt domain definitions on polaris.
- **Extra fields** not native to libvirt for bridged/static guests — `os`,
  `ip` — stored in domain XML `<metadata>` under a `vmctl` namespace, written
  at create, read by `list`/`info`/`ssh`. No sidecar files, no external DB.

## Error handling

- `create` on an existing domain → no-op success (idempotent).
- Missing/failed base-image download or checksum mismatch → fail before any
  domain is defined (no partial state).
- Any failure after overlay/seed creation but before a successful define →
  clean up the overlay + seed so a re-run starts clean.
- Operations on a non-existent VM (`destroy`/`ssh`/`info`/...) → clear error,
  non-zero exit.
- `--ip` collision detection is out of scope (user picks a free IP); document
  it as user responsibility.

## Testing / verification

No test suite exists in this repo — verification is a successful build plus an
on-host smoke test (per `CLAUDE.md`).

1. `nix build` the polaris toplevel (and the `vmctl` package) — must succeed.
2. Go unit tests for the pure logic (arg/flag parsing, cloud-init YAML
   rendering, metadata encode/decode) via `go test`, run in the package build.
3. On-host smoke test:
   - Apply the bridge change; confirm polaris keeps `192.168.1.50` + route + SSH.
   - `vmctl create t-ubuntu --os ubuntu --ip 192.168.1.201`; confirm it boots,
     has exactly that IP, and accepts the SSH key (`vmctl ssh t-ubuntu`).
   - Re-run the same `create` → confirm no-op.
   - `vmctl create t-nixos --os nixos --ip 192.168.1.202`; same checks.
   - `list`/`info` show correct data; `stop`/`start` preserve disk + IP;
     `destroy` removes domain + overlay + seed.

## Known risks / open validation points

1. **NixOS + cloud-init static networking** — the one semi-uncertain piece.
   NixOS's cloud-init `network-config` handling of a static IP is less
   battle-tested than Ubuntu's. **Fallback if it misbehaves:** inject the IP
   via cloud-init `write_files` / a small activation baked into `nixos-base`,
   rather than relying on cloud-init's network-config renderer. Ubuntu is
   well-trodden and low-risk.
2. **Bridge cutover on a live host** — mitigated by applying with console
   access and verifying connectivity post-switch (see Component 1).
3. **`$VMROOT` mountpoint** — confirm the exact scratch dataset/mountpoint on
   polaris during implementation before hardcoding a path.

## Out-of-scope future phases (noted, not built)

- GPU passthrough (IOMMU already prepared on polaris).
- A declarative `apply` mode if imperative use ever proves insufficient.
- Additional base OSes (Debian, Fedora) — the base-image mechanism generalises.

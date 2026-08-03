# vmctl — a KVM VM lab for polaris

**Date:** 2026-08-03
**Status:** Design approved, pending spec review
**Target host:** `polaris` (x86_64 NixOS server, `192.168.1.50/24`)
**Repos:** new `github.com/mattiasgees/vmctl` (the Go/Cobra CLI + NixOS base
image, own CI/releases) consumed by this `nixos-config` repo as a flake input.

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

The Go tool is **generic** — it hardcodes no polaris specifics. Environment
details (bridge name, `$VMROOT`, gateway/DNS, SSH-key source, NixOS base image
path, Ubuntu image URL+sha) are injected by the `nixos-config` module wrapper
as environment variables / defaults, overridable per-invocation by flags. This
keeps the CLI reusable on any libvirt host and confines polaris-specifics to
`modules/server/vmctl.nix`.

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
    nixos-base.qcow2                            # from vmctl repo's flake (see §Comp 3)
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
- **NixOS:** `nixos-base.qcow2` built via **nixos-generators** (`format = qcow`)
  and exposed as a flake package **from the `vmctl` repo** (so the tool ships
  its own NixOS image recipe, pinned to that repo's nixpkgs), with:
  - `services.cloud-init.enable = true;` (so it consumes the same NoCloud seed),
  - serial console enabled (for `vmctl console`),
  - minimal base (SSH server; user/keys come from cloud-init at boot).
  The `nixos-config` module builds `inputs.vmctl.packages.<sys>.nixos-base` and
  passes its **store path** to the CLI via `VMCTL_NIXOS_BASE`; on first NixOS
  create `vmctl` copies it into `base/` if absent. This keeps the image
  declarative and pinned while leaving the Go tool image-agnostic.

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

## Component 6 — Packaging & wiring (two repos)

### `github.com/mattiasgees/vmctl` (new repo)

- **Go module:** the Cobra CLI. Own `go.mod`, `go test`, CI (GitHub Actions:
  build + test + lint), tagged releases.
- **`flake.nix`** exposing:
  - `packages.<sys>.vmctl` — the CLI built with `buildGoModule`
    (`vendorHash` maintained). Runtime deps (`libvirt`/`virsh`, `virt-install`,
    `qemu-img`, `cloud-utils`/`cloud-localds`, `openssh`, `coreutils`) wrapped
    onto `PATH` via `makeWrapper` so the binary finds them regardless of the
    consuming system's profile.
    - `packages.<sys>.nixos-base` — the NixOS base qcow2 (nixos-generators).
  - (optional) `packages.<sys>.default = vmctl`, plus a dev shell.
- **No polaris specifics** in the Go code — see Architecture overview.

### `nixos-config` (this repo)

- **Flake input:** `inputs.vmctl.url = "github:mattiasgees/vmctl";`
  (with `inputs.nixpkgs.follows = "nixpkgs";` where compatible).
- **`modules/server/vmctl.nix`** (imported by `machines/polaris.nix`):
  - adds `inputs.vmctl.packages.<sys>.vmctl` to `environment.systemPackages`,
    wrapped with polaris defaults as env vars: `VMCTL_BRIDGE=br0`,
    `VMCTL_VMROOT=<scratch path>`, `VMCTL_GATEWAY=192.168.1.1`,
    `VMCTL_DNS=192.168.1.1`, `VMCTL_SSH_KEYS_URL=https://github.com/mattiasgees.keys`,
    `VMCTL_NIXOS_BASE=${inputs.vmctl.packages.<sys>.nixos-base}/…qcow2`,
    `VMCTL_UBUNTU_URL` + `VMCTL_UBUNTU_SHA256`.
  - ensures the `$VMROOT` directory + ownership (ZFS pool itself stays managed
    by the existing `scratch` import).
- **`machines/polaris.nix`:** the `br0` bridge change (Component 1).

### Dev-iteration workflow (mitigates cross-repo friction)

While actively developing, avoid the push→`flake update`→rebuild loop by
overriding the input against a local checkout:
`nixos-rebuild … --override-input vmctl path:/home/mattias/git/vmctl`
(or a temporary `path:` input). Pin to the pushed ref once stable.

## Component 7 — CI/CD (GitHub Actions, `vmctl` repo)

All CI lives in the `vmctl` repo (this `nixos-config` repo stays CI-less, per
`CLAUDE.md`).

### PR / push CI — `.github/workflows/ci.yml`

Triggers: `pull_request` and push to `main`. **Every PR must go green before
merge.** Jobs:

- **Lint:** `gofmt -l` (fail on diff), `go vet ./...`, `golangci-lint run`.
- **Unit + argv/parse (tiers 1–2):** `go test ./...` — pure logic, golden
  files, and the fake-runner orchestration tests. No system deps.
- **libvirt `test://` (tier 3):** `apt-get install -y libvirt-clients`, then run
  the gated integration tests against `test:///default` (no KVM required, so it
  runs on a stock `ubuntu-latest` runner).
- **Nix build:** Nix installer action + binary cache, then `nix build .#vmctl`
  to prove the package + wrapper build. (`.#nixos-base` is heavy — built on
  release / on demand, not on every PR.)

### Release CI — `.github/workflows/release.yml`

Trigger: pushing a semver tag `v*`. Uses **GoReleaser** to build, archive, and
publish to the GitHub Release in one step:

- **Build matrix:** `linux/amd64`, `linux/arm64`, `darwin/amd64`,
  `darwin/arm64`. (Windows excluded.) `CGO_ENABLED=0`, version/commit/date
  stamped via `-ldflags`.
- **Artifacts:** per-platform `.tar.gz` archives, a `checksums.txt`
  (sha256), and optional `.deb`/`.rpm` (nfpm) for the Linux targets. All
  uploaded to the GitHub Release; GoReleaser generates the changelog.
- **Runtime caveat, documented in the release notes:** the `darwin/*` binaries
  compile and run but cannot drive libvirt locally (no `virsh`/`virt-install`
  on macOS) — the tool is functional only on a Linux libvirt host. They are
  provided for convenience/future remote-libvirt use.
- **Not a release artifact:** `nixos-base.qcow2` is large and consumed via the
  flake by store path, so it is *not* attached to GitHub Releases.

Nix consumers keep pinning the flake input to a tag/commit; the archives are a
bonus for non-Nix use.

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

Testing is a first-class requirement. The strategy is a test pyramid whose
foundation is a **testability seam in the Go code** (see below); tiers 1–3 run
automatically in CI, tier 5 is an on-host runbook on polaris, and tier 4
(`nixosTest`) is **deferred to a later pass** (see future phases). Per the TDD
skill, tier 1–2 tests are written **before** the implementation they cover.

### Design constraint: the testability seam

The tool is structured so that everything except the actual external process
calls is pure and unit-testable:

- **Pure functions** for input validation, cloud-init artifact rendering
  (user-data / meta-data / network-config), `<metadata>` XML marshal/unmarshal,
  config resolution (env-var defaults ← flag overrides), and VMROOT path
  derivation.
- A single **`Runner` interface** — `Run(ctx, name string, args ...string)
  (stdout, stderr string, err error)` — through which *all* calls to
  `virt-install`/`virsh`/`qemu-img`/`cloud-localds` go. Production uses an
  `os/exec` implementation; tests inject a **fake runner** that records the argv
  it was asked to run and returns canned stdout/stderr/exit codes. Without this
  seam almost nothing is testable; with it, the orchestration logic is.

### Tier 1 — Unit tests (CI, `go test`) — the bulk

- Input validation: name rules; `--ip` a valid in-range IPv4; `--cpu` > 0;
  `--mem`/`--disk` size parsing; `--os ∈ {ubuntu, nixos}`.
- **Golden-file** cloud-init rendering for both OSes across a couple of IPs
  (user-data, meta-data, network-config) — fixtures under `testdata/`.
- `<metadata>` XML round-trip (encode → decode → equal).
- Config precedence: `VMCTL_*` env defaults overridden by explicit flags.
- VMROOT path derivation (overlay/seed/base paths from a name).

### Tier 2 — Command construction & output parsing (CI, `go test`)

- Assert the **exact argv** built for `virt-install`, `qemu-img create`, and
  `virsh metadata` from given inputs (via the fake runner, nothing executed).
- **Fixture-driven parsers:** feed captured real outputs (`virsh list --all`,
  `virsh dumpxml <dom>`, `qemu-img info --output=json`) into the parsing code
  and assert the resulting structs — this backs `list`/`info`.
- Orchestration with the fake runner: idempotent `create` (domain exists →
  no-op success), **cleanup-on-failure** (define fails → overlay + seed removed),
  and `destroy` step ordering.

### Tier 3 — libvirt `test://` driver integration (CI, gated)

Behind a build tag / env gate, run real `virsh` against libvirt's built-in
**mock driver** (`LIBVIRT_DEFAULT_URI=test:///default`): exercises the actual
define → list → metadata → start → stop → undefine lifecycle wiring without any
KVM. Catches real `virsh` CLI incompatibilities the fakes cannot. (Does not
boot guests or run cloud-init — that is tier 5.)

### Tier 4 — `nixosTest` — DEFERRED

Not built in this phase (see future phases). When added: a flake check booting
libvirtd + vmctl and driving it against `test://`, plus a `nixos-config` check
asserting the `br0` result. Until then, the `br0` cutover is verified **by hand
on polaris** (tier 5).

### Tier 5 — On-host end-to-end (manual runbook on polaris, with KVM)

The irreplaceable real-world check; also where the NixOS+cloud-init static-IP
risk is retired.

- Apply the bridge change; confirm polaris **keeps `192.168.1.50` + default
  route + SSH** (do this with console access available).
- `vmctl create t-ubuntu --os ubuntu --ip 192.168.1.201`; confirm it boots, has
  exactly that IP, and accepts the SSH key (`vmctl ssh t-ubuntu`).
- **Reboot the guest** → confirm the IP is unchanged (consistency guarantee).
- Re-run the same `create` → confirm no-op.
- `vmctl create t-nixos --os nixos --ip 192.168.1.202`; same checks.
- `list`/`info` show correct data; `stop`/`start` preserve disk + IP;
  `destroy` removes domain + overlay + seed.

### Where these run

Tiers 1–3 + lint execute on **every PR** via GitHub Actions; releases build
cross-platform artifacts. See **Component 7 — CI/CD** for the workflow details.
Tier 5 is the manual on-host runbook on polaris.

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
   polaris during implementation before setting the module default.
4. **Cross-repo iteration friction** — mitigated by `--override-input
   vmctl path:…` during development (see Component 6); only pin to a pushed
   ref once the tool stabilises.

## Out-of-scope future phases (noted, not built)

- **Tier 4 `nixosTest` checks** (deferred, see Testing): a vmctl-lifecycle
  check against `test://` and a `br0` bridge-config assertion for `nixos-config`.
- GPU passthrough (IOMMU already prepared on polaris).
- A declarative `apply` mode if imperative use ever proves insufficient.
- Additional base OSes (Debian, Fedora) — the base-image mechanism generalises.

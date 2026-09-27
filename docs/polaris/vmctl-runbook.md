# vmctl on-host runbook (polaris)

Purpose: verify `vmctl` on polaris — the `vmctl` flake input,
`modules/server/vmctl.nix`, and the polaris `extraModules` wiring in `flake.nix`
— and run the on-host checks static review couldn't: the double-wrapped `vmctl`
binary and full VM lifecycle against real KVM.

**Current state:** the `br0` bridge (`machines/polaris.nix`) and the `vmctl`
module are both in the polaris config and the `vmctl` input is locked in
`flake.lock`. Still open: `ubuntuSHA` in `modules/server/vmctl.nix` is `""`
(**A.4**). Steps marked *(done)* are kept for a from-scratch redeploy.

The `vmctl` input is a **private** repo fetched over
`git+ssh://git@github.com/MattiasGees/vmctl?ref=main`. Build as your user (with
GitHub SSH access), never with `sudo nixos-rebuild` — see
[updating.md](updating.md).

Run the sections in order (A → E).

---

## A. Pre-flight (before building)

**A.1 — Get an out-of-band session to polaris (only for network changes).**
Open an IPMI/iDRAC/iLO console session, or sit at the physical machine, before
any change to the `br0` bridge in `machines/polaris.nix` — it carries the host's
static IP, and if a change goes wrong you need a way in that isn't the interface
being changed. Pure `vmctl` checks can run over SSH.

*Good:* you have a console prompt open and can see boot/systemd output
independent of the SSH session.

**A.2 — (done) Lock the `vmctl` input.**
`flake.lock` has a `vmctl` node. To pull a newer `vmctl` later:

```bash
nix flake update vmctl
git add flake.lock && git commit -m "flake.lock: update vmctl"
```

**A.3 — Confirm the scratch mountpoint.**

```bash
zfs list scratch
ls -d /srv/scratch
```

`modules/server/vmctl.nix` hardcodes `vmRoot = "/srv/scratch/vms"` on the
assumption the `scratch` pool mounts natively at `/srv/scratch`. If `zfs list`
shows a different `MOUNTPOINT`, update the `vmRoot` binding in
`modules/server/vmctl.nix` to match before building.

*Good:* `zfs list scratch` mountpoint column reads `/srv/scratch`, and
`ls -d /srv/scratch` succeeds.

**A.4 — Pin the Ubuntu cloud image checksum.**

```bash
curl -fsSL https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img | sha256sum
```

(The URL above is `ubuntuURL` from `modules/server/vmctl.nix` — re-check that
file in case it has since changed.) Copy the resulting hash into `ubuntuSHA`
in `modules/server/vmctl.nix`, which is currently `""`:

```nix
ubuntuSHA = ""; # TODO(on-host): set to the pinned image's sha256
```

*Good:* `ubuntuSHA` is a non-empty 64-character hex string matching the
`sha256sum` output.

**A.5 — Confirm the NixOS base image filename.**
`modules/server/vmctl.nix` assumes:

```nix
nixosBase = "${vmctlPackages.nixos-base}/nixos.qcow2";
```

Do a first build (section B.6 will also do this) or a targeted dry build, then
inspect the actual store path:

```bash
nix build --impure .#nixosConfigurations.polaris.config.system.build.toplevel --dry-run
# after B.6 has produced a real store path for nixos-base:
ls "$(nix eval --impure --raw .#nixosConfigurations.polaris.config._module.args.vmctlPackages.nixos-base 2>/dev/null || true)"
```

If the simpler path above doesn't resolve cleanly, just build normally (B.6)
and then find the derivation output directly:

```bash
find /nix/store -maxdepth 1 -iname '*nixos-base*' 2>/dev/null
ls <that-path>
```

`nixos-generators`'s `qcow` format normally names the output `nixos.qcow2`. If
the real basename differs, fix `nixosBase` in `modules/server/vmctl.nix`
accordingly.

*Good:* the file referenced by `nixosBase` actually exists in the built store
path.

---

## B. Build (the evaluation safety net static review couldn't run)

**B.6 — Build the polaris toplevel.**

```bash
nix build --impure .#nixosConfigurations.polaris.config.system.build.toplevel
```

This must succeed. It also builds the NixOS base qcow2 image via the `vmctl`
flake's `nixos-base` package — expect this to be slow the first time
(NixOS image generation from scratch).

*Good:* the build exits 0 and produces a `result` symlink into `/nix/store`.

**B.7 — Confirm `polaris-vm` (aarch64) wasn't regressed.**
`polaris-vm` does NOT get the `vmctl` module or `vmctlPackages` arg (it's
x86_64/GPU-specific wiring in `polaris`'s `extraModules`), so it must still
evaluate cleanly without a missing-argument error:

```bash
nix eval .#nixosConfigurations.polaris-vm.config.system.build.toplevel.drvPath
# or, broader:
nix flake check
```

*Good:* no error about a missing `vmctlPackages` module argument, and (if used)
`nix flake check` completes without new failures.

**B.8 — Double-wrap check on the `vmctl` binary.**
`modules/server/vmctl.nix` wraps the already-wrapped upstream `vmctl` binary
a second time (`symlinkJoin` + `wrapProgram`) to inject `VMCTL_*` env vars.
This composition was never verified against a real build. Confirm both
wrapper layers are present and the `--set` flags survived:

```bash
cat "$(readlink -f "$(command -v vmctl)")"
```

*Good:* the script shows an outer wrapper exporting `VMCTL_BRIDGE`,
`VMCTL_VMROOT`, `VMCTL_GATEWAY`, `VMCTL_DNS`, `VMCTL_USER`,
`VMCTL_SSH_KEYS_URL`, `VMCTL_NIXOS_BASE`, `VMCTL_UBUNTU_URL`, and
`VMCTL_UBUNTU_SHA256`, which then `exec`s an inner wrapper (from the upstream
`vmctl` flake) that sets up `PATH` for its own runtime deps (e.g. `virsh`,
`qemu-img`, `genisoimage`). If either layer or any `--set` value is missing,
this is the first thing to fix before touching real VMs.

---

## C. Bridge + install checks

Confirms the bridge is healthy, optionally smoke-tests `vmctl` without the
module, then confirms the declarative install.

**C.9a — Confirm the `br0` bridge is live.**

From the **console** (or SSH, if the host is already reachable):

```bash
ip -o addr show br0        # expect 192.168.1.50/24
ip -o addr show enp6s0     # expect NO inet address, but present as bridge member
bridge link show           # enp6s0 should show master br0
ip route                   # default via 192.168.1.1 should be present
cat /etc/resolv.conf       # nameservers 192.168.1.86, then 8.8.8.8
ssh mattias@192.168.1.50 -o ConnectTimeout=5 true   # from another machine
cat /proc/sys/net/ipv4/conf/br0/rp_filter           # not strict (1) for bridged guests
```

If the host's own networking is unhealthy (no IP on `br0`, no default route, SSH
unreachable), fix that from the console before continuing.

*Good:* `br0` carries `192.168.1.50/24`, `enp6s0` is a member with no IP,
default route + DNS work, SSH reachable.

**C.9b — (optional) Smoke-test `vmctl` without the module.**

Run `vmctl` straight from its flake, bypassing the NixOS module — useful when
testing an unreleased `vmctl` change. The flake package wraps
`virsh`/`virt-install`/`qemu-img`/`cloud-localds` onto PATH, and most `VMCTL_*`
now default sensibly (bridge `br0`, gateway/DNS derived from the IP, Ubuntu
image + your SSH keys), so you only override where you want a non-default:

```bash
VMCTL='git+ssh://git@github.com/MattiasGees/vmctl?ref=main'
nix run $VMCTL#vmctl -- --help

# Only these differ from the defaults for a scratch-backed run as mattias:
sudo install -d -o mattias -g libvirtd -m 0755 \
  /srv/scratch/vms /srv/scratch/vms/base /srv/scratch/vms/disks /srv/scratch/vms/seeds
export VMCTL_VMROOT=/srv/scratch/vms   # else defaults to ~/.local/share/vmctl (home, not scratch)
export VMCTL_USER=mattias              # else defaults to root

nix run $VMCTL#vmctl -- create t-smoke --ip 192.168.1.201
nix run $VMCTL#vmctl -- list
nix run $VMCTL#vmctl -- ssh t-smoke      # logs in with your key
nix run $VMCTL#vmctl -- destroy t-smoke --force
```

*Good:* the hand-run `vmctl` creates a bridged Ubuntu VM that boots and comes up
on `192.168.1.201`, you can SSH in, and `destroy` cleans it up — so you've
validated the tool + the bridge before committing to the declarative install.

**C.9c — Confirm the declarative install.**

```bash
make switch NIXNAME=polaris
```

`vmctl` is on PATH system-wide with the `VMCTL_*` env baked in by the module
(you no longer set them by hand).

*Good:* `vmctl list` works with no `VMCTL_*` exported in your shell (the wrapper
supplies them), and the bridge is unchanged.

**C.10 — Confirm the ZFS mount-race didn't shadow the storage dirs.**
`systemd.tmpfiles.rules` in `modules/server/vmctl.nix` creates
`vmRoot`/`base`/`disks`/`seeds` — but if `tmpfiles` ran before the `scratch`
dataset was mounted, those directories would have been created on the
underlying (empty) mountpoint directory instead of on the actual ZFS dataset.

```bash
mount | grep /srv/scratch
ls -la /srv/scratch/vms
ls -la /srv/scratch/vms/base /srv/scratch/vms/disks /srv/scratch/vms/seeds
```

*Good:* `/srv/scratch` shows up in `mount` output as the `scratch` ZFS
dataset (not just a bare directory), and `vms`/`base`/`disks`/`seeds` are all
owned `mattias:libvirtd` with mode `0755`. If they were created before the
mount, `umount`-ing (if safe) would reveal empty directories underneath —
in that case, remove the shadowed dirs and re-run
`systemd-tmpfiles --create` after confirming the ZFS mount is active.

---

## D. Tier-5 end-to-end (real KVM)

**D.11 — Create and verify an Ubuntu VM.**

```bash
vmctl create t-ubuntu --ip 192.168.1.201
# wait for boot
vmctl list                          # t-ubuntu should be listed, running
vmctl ssh t-ubuntu                  # should log in with your key, no password
```

Inside the guest:

```bash
ip a                                # should show 192.168.1.201 on the bridged NIC
```

*Good:* the domain boots, appears in `vmctl list`, SSH succeeds with your key
(from `VMCTL_SSH_KEYS_URL`), and the guest's address matches what was
requested.

**D.12 — Reboot consistency.**

```bash
vmctl stop t-ubuntu && vmctl start t-ubuntu
vmctl ssh t-ubuntu -- ip a          # or: vmctl ssh t-ubuntu, then `ip a`
```

*Good:* after a stop/start cycle the guest comes back up with the **same**
`192.168.1.201` address (cloud-init/DHCP-reservation behavior didn't drift).

**D.13 — Idempotency.**

```bash
vmctl create t-ubuntu --ip 192.168.1.201
```

*Good:* this errors with an "already exists" message (or equivalent) rather
than silently duplicating or clobbering the existing domain.

**D.14 — NixOS guest.**

```bash
vmctl create t-nixos --os nixos --ip 192.168.1.202
# wait for boot
vmctl list
vmctl ssh t-nixos
```

Inside the guest, confirm `ip a` shows `192.168.1.202`. Also confirm
`virt-install` accepted the OS variant used by the code
(`--os-variant generic` for NixOS guests) — check for a warning/error about
an unrecognized `--os-variant` in the `vmctl create` output or in
`journalctl`/libvirt logs.

**If the static IP does not come up on the NixOS guest** (the known design
risk — NixOS's cloud-init network stage doesn't always apply a static IP the
same way Ubuntu's does), apply the documented fallback in the `vmctl` repo:
inject the IP via cloud-init `write_files` (or a small activation script)
baked into `nix/nixos-base.nix`, rebuild the base image
(`nix build .#nixos-base` in the `vmctl` repo), and re-release/re-pull it here
before retrying `vmctl create t-nixos ...`.

*Good:* `t-nixos` boots, is reachable at `192.168.1.202`, and SSH works — or,
if the fallback was needed, it works after applying it and the fix is noted
for upstreaming.

**D.15 — Inspect and tear down.**

```bash
vmctl info t-ubuntu                 # shows disk used/max and the backing (base) image
vmctl destroy t-ubuntu
vmctl destroy t-nixos
ls /srv/scratch/vms/disks           # overlays for t-ubuntu/t-nixos should be gone
ls /srv/scratch/vms/seeds           # seed ISOs for t-ubuntu/t-nixos should be gone
vmctl list                          # neither domain should be listed
```

*Good:* `vmctl info` reports sane disk usage against the correct backing
image, `vmctl destroy` removes the libvirt domain plus its overlay disk and
seed ISO, and nothing is left behind in `disks`/`seeds` for either VM.

---

## E. Wrap-up

**E.16 — (done) Flake input tracks `vmctl` `main`.**
`flake.nix` points at `git+ssh://git@github.com/MattiasGees/vmctl?ref=main` and
the lock is committed; refresh with `nix flake update vmctl` (A.2).

**E.17 — Cut the first vmctl release.**
Once this runbook passes end-to-end, tag a release in the `vmctl` repo so
there's a stable artifact to point at going forward:

```bash
git -C <path-to-vmctl-checkout> tag v0.1.0
git -C <path-to-vmctl-checkout> push origin v0.1.0
```

*Good:* `v0.1.0` exists on `MattiasGees/vmctl` and (if the repo has a release
workflow) a GitHub Release with build artifacts is produced.

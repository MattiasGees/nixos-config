# polaris — Updating & Maintenance

How to move polaris' software forward: the OS, the kernel, Plex, the *arr apps,
and Caddy. Run everything here **on polaris** (it builds for `x86_64-linux` and
activates locally).

## The update model

- **nixpkgs tracks `nixos-unstable`** (a rolling branch), and `flake.lock` pins
  the exact commit. "Updating" means moving that lock forward — there is **no
  discrete release upgrade** to do (no `25.05 → 26.11` branch bump).
- **Everything comes from the flake**: kernel, ZFS, Plex, Sonarr/Radarr/Prowlarr,
  Caddy, CLI tools. One update mechanism covers all of them.
- **Do not update apps from their own web UIs.** Nix owns the binary versions; an
  in-app update won't survive the next `nixos-rebuild` and can leave the app's
  database ahead of the binary Nix reinstalls. Update via the flake only.

## Routine update (all software)

```bash
cd ~/Documents/git/nixos-config
git pull                                  # get the latest committed config first

make update                               # = nix flake update — bumps every input
sudo nixos-rebuild build --flake .#polaris --impure   # optional: build without activating
make switch NIXNAME=polaris               # build + activate

git add flake.lock
git commit -m "flake: update inputs"      # the lock IS the reproducibility record
git push
```

Committing `flake.lock` is what makes the update reproducible and rollback-able
from Git — don't skip it.

**Update just one input** instead of everything (e.g. only nixpkgs):

```bash
nix flake update nixpkgs                  # newer syntax
# older syntax: nix flake lock --update-input nixpkgs
```

## Test before you switch, and rolling back

```bash
# Build the new system without activating it — catches build failures safely:
sudo nixos-rebuild build --flake .#polaris --impure

# See what a switch would change without committing to it:
sudo nixos-rebuild dry-activate --flake .#polaris --impure
```

If a `switch` leaves the box unhappy, roll back to the previous generation:

```bash
sudo nixos-rebuild switch --rollback                       # last-known-good
sudo nix-env --list-generations -p /nix/var/nix/profiles/system   # or pick one
# or: reboot and choose an older generation in the systemd-boot menu
```

Rollback only works while the old generation still exists — garbage collection
(below) eventually removes it, so roll back before GC runs if something broke.

## Caddy (the FOD-hash gotcha)

Caddy is built from source with the `route53` plugin vendored in
(`pkgs.caddy.withPlugins`), which requires a fixed-output `hash` in
`modules/media/caddy.nix`. That hash goes stale in **two** situations:

1. **You bump the plugin** (e.g. `route53@v1.6.2` → a newer tag) or add a plugin.
2. **A routine `make update` bumps Caddy itself** in nixpkgs — the vendored
   source changes, so the pinned hash no longer matches.

Both surface the same way — the build fails on `caddy-src-with-plugins` with:

```
hash mismatch ... specified: sha256-AAAA... got: sha256-<real hash>
```

This is expected, not a bug. Fix it with the two-step re-derive:

```bash
# 1. set  hash = lib.fakeHash;  in modules/media/caddy.nix (forces a clean mismatch)
make switch NIXNAME=polaris          # fails, printing "got: sha256-..."
# 2. paste that value:  hash = "sha256-...";
make switch NIXNAME=polaris          # builds
```

When bumping the **plugin version**, also check it still targets the `libdns`
version the current Caddy uses — a mismatch fails at compile with
`invalid composite literal type libdns.Record` (that's why we're on `v1.6.2`,
which targets libdns v1). See the comments in `modules/media/caddy.nix`.

## Kernel & ZFS (read before updating)

polaris pins `boot.kernelPackages = pkgs.linuxPackages` (the LTS-ish kernel, **not**
`_latest`) specifically for **ZFS compatibility** — see `machines/polaris.nix`.
On `nixos-unstable` the newest kernel can still outrun what the ZFS module
supports.

- If a build fails right after `make update` with a ZFS-vs-kernel error (e.g.
  *"ZFS does not support this kernel version"*), that's the lag — not your
  change. Options: **wait a few days** and update again (ZFS catches up quickly),
  or temporarily pin an older kernel.
- **Reboot after any kernel bump.** The ZFS module and the NVIDIA driver load
  against the running kernel; `nvidia-persistenced` has failed after a driver/
  kernel bump until a reboot before. After reboot, confirm:
  ```bash
  zpool status                     # all pools ONLINE
  nvidia-smi                       # driver loads, GPU visible
  systemctl --failed               # nothing failed
  ```

## Apps (Plex, Sonarr, Radarr, Prowlarr)

- Versions move with `make update` + switch like everything else. Their config
  and SQLite DBs live on `/srv/fast/appdata/<app>` and **persist across updates**
  and rollbacks.
- Again: don't use the in-app updaters — let Nix manage the binaries.

## Housekeeping

- **Garbage collection runs automatically** (`nix.gc` in `machines/shared.nix`),
  removing old generations over time. Manual sweep when disk is tight:
  ```bash
  sudo nix-collect-garbage -d      # deletes old generations (disables rollback to them)
  df -h /                          # check root free space
  ```
- Glance at `zpool status` / `zfs list` occasionally; scrub + TRIM are automatic.

## Related repos (not part of `make switch`)

- **Seedbox** (HAProxy Plex front-door): the **ansible** repo. Update the VPS with
  its normal `apt` upgrades and re-run `ansible-playbook server.yml --limit seedbox`.
- **AWS IAM / Terraform** (Caddy's Route53 user): the **infrastructure** repo.
  Provider updates via `terraform init -upgrade` then `plan` / `apply`.

See also: [manual-steps.md](manual-steps.md) (secrets, DNS, first-run setup) and
[manual-install-guide.md](manual-install-guide.md) (from-ISO OS + ZFS).

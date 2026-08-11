# NFS mirror of tank/data to 192.168.1.88 for polaris — Design

**Status:** Draft for review
**Date:** 2026-08-11
**Host:** `polaris`

## 1. Purpose & scope

A **local, on-LAN second copy** of the `tank/data` dataset (`/srv/data`) mirrored
**hourly** to an NFS share on `192.168.1.88`. This complements — does not replace
— the existing encrypted restic→Hetzner backup of `/srv/data/immich`
(`modules/server/restic.nix`): restic is the offsite, encrypted, deduplicated tier
for the irreplaceable subset; this is a fast, browsable 1:1 mirror of the whole
data dir on the house NAS.

One new module (`modules/server/data-nfs-backup.nix`) wired into
`machines/polaris.nix`, plus a short runbook for the manual NAS-side steps.

**Out of scope:** `tank/media` (`/srv/media`) — bulk and re-downloadable, explicitly
not synced. No second offsite tier. No restic on the NFS target (this is a plain
rsync mirror, by request).

## 2. Decisions (locked)

- **Transport:** NFS, mounting the share **`192.168.1.88:/polaris`** directly (the
  export itself is `/polaris`, not a subfolder we create).
- **NFS version:** **`nfsvers=4.0`**, pinned so the client does not negotiate up to
  4.1/4.2. (NFSv4 needs no rpcbind on the client.)
- **Local mountpoint:** `/mnt/polaris-nfs`, **automounted on demand** — mounts on
  first access, unmounts after 10 min idle, `nofail` so an offline NAS never blocks
  boot or other units.
- **Source:** `/srv/data/` (trailing slash — rsync copies the *contents* into the
  mount root, not a nested `data/` dir).
- **Sync mode:** **mirror**, `rsync -a --delete` — the NAS copy tracks deletions on
  polaris exactly.
- **Excludes:** `/srv/data/immich/thumbs` and `/srv/data/immich/encoded-video` —
  Immich regenerates both on demand, same rationale as the restic module. Keeps the
  hourly diff and NAS footprint down. Everything else under `/srv/data` is mirrored
  wholesale.
- **Schedule:** **hourly**, `OnCalendar = "hourly"`, `Persistent = true` (a run
  missed while the box was off fires at next boot).
- **Runs as root** so it can read the root-owned `immich/` subtree.

## 3. Accepted trade-offs

- **Plaintext on the wire and at rest on the NAS.** `tank/data` is encrypted at
  rest on ZFS, but rsync reads it decrypted and NFSv4.0 here is unencrypted over the
  LAN, so the copy lands as plaintext on `192.168.1.88`. Accepted: this is a
  trusted-LAN NAS mirror; the encrypted-end-to-end tier remains restic→Hetzner.
- **Overlapping runs.** An hourly mirror of a large tree could in theory still be
  running when the next timer fires. systemd will not start a second instance of a
  `oneshot` service that is still active, so hours are naturally skipped rather than
  stacked — acceptable for a mirror.
- **NFS ownership squashing.** If the export applies `root_squash`, root-owned files
  land owned by the anonymous UID on the NAS; `rsync -a` will try to reset owner each
  run and log a benign permission error per file. The runbook notes `no_root_squash`
  as the fix if that churn is unwanted. `--numeric-ids` keeps UIDs from being remapped
  through the NAS's name service.

## 4. The module (`modules/server/data-nfs-backup.nix`)

A new server module imported by `machines/polaris.nix`, carrying a header comment
in the repo's style (what/why, the automount rationale, the plaintext trade-off,
and a pointer to the runbook).

```nix
{ pkgs, ... }:
{
  # On-demand NFS automount of the house NAS share. noauto + nofail so an
  # offline NAS never blocks boot; idle-timeout unmounts it between hourly runs.
  fileSystems."/mnt/polaris-nfs" = {
    device = "192.168.1.88:/polaris";
    fsType = "nfs";
    options = [
      "nfsvers=4.0"
      "noauto"
      "nofail"
      "_netdev"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
    ];
  };

  systemd.services.polaris-data-nfs-sync = {
    description = "Mirror /srv/data to NFS share on 192.168.1.88";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # Pull in (and thus trigger) the automount; fail cleanly if the NAS is down.
    unitConfig.RequiresMountsFor = "/mnt/polaris-nfs";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = ''
        ${pkgs.rsync}/bin/rsync -a --delete --numeric-ids \
          --exclude=/immich/thumbs \
          --exclude=/immich/encoded-video \
          /srv/data/ /mnt/polaris-nfs/
      '';
    };
  };

  systemd.timers.polaris-data-nfs-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };
}
```

Notes:
- **Exclude paths are anchored** (`/immich/thumbs`) so they match only the top-level
  Immich dirs relative to the rsync source root, not any `thumbs/` elsewhere.
- **`RequiresMountsFor`** ties the sync to the automount unit: accessing the path
  triggers the mount, and the service fails (rather than writing into an empty local
  dir) if the NAS is unreachable — a real failure surfaces in `journalctl` instead of
  silently mirroring into `/mnt/polaris-nfs` on the root disk.

## 5. Manual prerequisites (out of git)

Operator does these by hand on `192.168.1.88`; the config only references the path:

- Create/confirm the NFS export **`/polaris`**, allowing the polaris host
  (`192.168.1.50`) read-write, NFSv4.
- Decide `root_squash` vs `no_root_squash` (see §3 ownership note).
- Ensure the export has capacity for the full `/srv/data` mirror minus the two
  excluded Immich dirs.

## 6. Repo structure

| File | Responsibility |
|------|----------------|
| `modules/server/data-nfs-backup.nix` | NFS automount + hourly rsync mirror — new |
| `machines/polaris.nix` | import `../modules/server/data-nfs-backup.nix` |
| `docs/polaris/nfs-data-backup-runbook.md` | operator NAS-side steps + verify — new |

## 7. Verification

- `make switch NIXNAME=polaris`.
- Automount armed: `systemctl status mnt-polaris\\x2dnfs.automount` shows it loaded.
- Trigger a mount: `ls /mnt/polaris-nfs` (first access mounts it);
  `mountpoint /mnt/polaris-nfs` succeeds.
- First run: `sudo systemctl start polaris-data-nfs-sync.service`; then
  `journalctl -u polaris-data-nfs-sync` shows rsync completing without error.
- Spot-check the mirror: a file present under `/srv/data` appears under
  `/mnt/polaris-nfs`, and the two excluded Immich dirs do **not**.
- Timer armed: `systemctl list-timers polaris-data-nfs-sync` shows the next hourly run.

## 8. Deferred / future

- Failure notification (the restic tier has none either today) — journal-only for now.
- Encrypting the NAS-side copy, if the trusted-LAN assumption ever changes.
- Bandwidth/`--bwlimit` throttling if the hourly mirror ever contends with media I/O.

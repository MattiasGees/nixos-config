# restic → Hetzner offsite backup for polaris — Design

**Status:** Draft for review
**Date:** 2026-08-10
**Host:** `polaris`

## 1. Purpose & scope

Offsite, **encrypted, deduplicated** backup of the irreplaceable data on polaris
— the Immich photo/video library and Immich's own database dumps — to **Hetzner
Object Storage** via `services.restic`. One new module plus a **runbook** that
documents the manual bucket/secret steps the operator must do by hand.

**Out of scope** (deferred): the local **ZFS-snapshot** fast-rollback tier; a
**central `pg_dumpall`** for future non-Immich databases (Immich is the only DB
today, and its built-in dump covers it); and backing up Plex's `/srv/media`
(bulk and re-downloadable — not worth the object-storage cost).

## 2. Decisions (locked)

- **Repository:** `s3:https://nbg1.your-objectstorage.com/backups-polaris`
  (Hetzner Object Storage, restic's S3 backend; bucket `backups-polaris`, region
  `nbg1`).
- **What:** `paths = [ "/srv/data/immich" ]` — one sweep captures the originals
  **and** Immich's DB dumps (which Immich writes to `/srv/data/immich/backups/`).
  Exclude `thumbs/` and `encoded-video/` — regenerable, ~halves the size/egress.
- **Database:** rely on Immich's **built-in DB backup** (stays enabled); no
  separate `pg_dumpall` in this change.
- **Schedule:** **daily 03:00**, after Immich's ~02:00 built-in DB dump, so restic
  always sweeps a fresh dump.
- **Retention:** `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`.
- **Secrets:** hand-placed on the box, `0600`, out of git — matching the existing
  `/etc/caddy/route53.env` convention. No sops/agenix introduced.
- `initialize = true` — restic creates the repo on first run.

## 3. The module (`modules/server/restic.nix`)

A new reusable server module, imported by `machines/polaris.nix`:

```nix
services.restic.backups.polaris = {
  repository = "s3:https://nbg1.your-objectstorage.com/backups-polaris";
  passwordFile = "/etc/restic/polaris.pass";      # restic repo encryption key
  environmentFile = "/etc/restic/hetzner.env";    # AWS_ACCESS_KEY_ID / _SECRET / _DEFAULT_REGION
  paths = [ "/srv/data/immich" ];
  exclude = [
    "/srv/data/immich/thumbs"
    "/srv/data/immich/encoded-video"
  ];
  initialize = true;
  pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 6" ];
  timerConfig = { OnCalendar = "03:00"; Persistent = true; };
};
```

- **Excludes:** `thumbs/` and `encoded-video/` are derived from the originals —
  Immich regenerates them — so we skip them and keep the irreplaceable `library/`,
  `upload/`, `profile/`, and `backups/` (the DB dumps). Immich's own recommended
  file-backup set.
- **`Persistent = true`:** a missed run (box off at 03:00) fires at next boot.
- Header comment (repo convention) explains: what's backed up and why, the
  Immich-dump dependency + the 03:00-after-02:00 ordering, the exclude rationale,
  and that the two secret files are placed by hand (see the runbook).

## 4. Secrets & manual prerequisites (out of git)

The operator does these **by hand**; the config only references the paths:

- **Hetzner:** create bucket `backups-polaris` in region `nbg1`, and an S3
  access key / secret key.
- **`/etc/restic/hetzner.env`** (`0600`, root):
  ```
  AWS_ACCESS_KEY_ID=<hetzner key>
  AWS_SECRET_ACCESS_KEY=<hetzner secret>
  AWS_DEFAULT_REGION=nbg1
  ```
- **`/etc/restic/polaris.pass`** (`0600`, root): a strong restic repo password.
  **⚠️ Store it in a password manager off-box — lose it and every backup is
  permanently unrecoverable.**
- Confirm Immich → Admin → Settings → **Backup is enabled** (so the DB dump exists
  under `/srv/data/immich/backups/` before restic runs).

## 5. Documentation deliverable (required)

Create **`docs/polaris/restic-backup-runbook.md`**, matching the style of the
existing `docs/polaris/*-runbook.md` (e.g. `vmctl-runbook.md`). It must document,
for the operator:

1. Creating the Hetzner bucket + S3 key (region `nbg1`).
2. Placing the two secret files (exact contents, `0600` ownership, the
   password-safety warning).
3. Enabling Immich's built-in DB backup and confirming its schedule vs the 03:00
   restic timer.
4. The verify + **restore-drill** commands (§6).
5. The region gotcha note (§6).

This runbook is part of the implementation, not a follow-up.

## 6. Repo structure

| File | Responsibility |
|------|----------------|
| `modules/server/restic.nix` | `services.restic.backups.polaris` config — new |
| `machines/polaris.nix` | import `../modules/server/restic.nix` |
| `docs/polaris/restic-backup-runbook.md` | operator manual actions (§5) — new |

## 7. Verification

- `make switch NIXNAME=polaris`.
- First run: `sudo systemctl start restic-backups-polaris.service`; then
  `journalctl -u restic-backups-polaris` shows repo init + a completed snapshot.
- `sudo restic-polaris snapshots` lists the snapshot.
- **Restore drill:** `sudo restic-polaris restore latest --target /tmp/restore-test
  --include /srv/data/immich/backups` → a DB dump comes back; diff it. Then
  `rm -rf /tmp/restore-test`.
- **Timer armed:** `systemctl list-timers restic-backups-polaris` shows the next
  03:00 run.
- ⚠️ **Region gotcha (bounded iteration):** if restic errors on bucket
  location/region against Hetzner, ensure `AWS_DEFAULT_REGION=nbg1` is in the env
  file (already specified above) or add an `-o s3.region=nbg1` extra option. Not a
  redesign.

## 8. Deferred / future

- Local **ZFS snapshots** (`services.sanoid` on `tank/data` + `fast/db`) — the
  fast-rollback tier that complements this offsite copy.
- A **central `pg_dumpall`** (`services.postgresqlBackup`) once a non-Immich DB
  exists, whose dump dir restic also backs up.
- **Restore-drill automation** / monitoring that the nightly backup succeeded.

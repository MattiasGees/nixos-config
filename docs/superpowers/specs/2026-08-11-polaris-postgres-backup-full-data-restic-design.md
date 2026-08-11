# Cluster pg_dumpall + full /srv/data restic sweep for polaris — Design

**Status:** Draft for review
**Date:** 2026-08-11
**Host:** `polaris`

## 1. Purpose & scope

Two related backup improvements, picking up the thread deferred in
`2026-08-10-polaris-restic-backup-design.md` §8 ("a central `pg_dumpall` once a
non-Immich DB exists, whose dump dir restic also backs up"):

1. **Widen the restic sweep** from `/srv/data/immich` to the whole **`/srv/data`**
   dataset, so any current or future tenant that stores data there is backed up
   offsite for free.
2. **Add a cluster-wide `pg_dumpall`** of the shared PostgreSQL, landing under
   `/srv/data` so the same restic sweep captures every database — Immich today,
   and future services with zero per-service wiring.

No new module: edits to `modules/server/restic.nix` and
`modules/server/postgresql.nix`, plus a runbook update.

**Out of scope / deferred (unchanged):** per-database `pg_dump` splitting (see
§7 for why not now), dump-file encryption, the ZFS-snapshot fast-rollback tier.

## 2. Decisions (locked)

- **restic paths:** `paths = [ "/srv/data" ]` (was `/srv/data/immich`). Keep the
  two excludes `/srv/data/immich/thumbs` and `/srv/data/immich/encoded-video`
  (regenerable). Everything else under `/srv/data` is swept.
- **Postgres backup:** `services.postgresqlBackup` with **`backupAll = true`** —
  a single `pg_dumpall` capturing **every database plus cluster globals**
  (roles, grants, passwords). Chosen over per-DB `databases = [...]` because it
  **auto-covers future tenants** (no list to maintain) **and** captures globals,
  which per-DB `pg_dump` does not. Restore granularity (extracting one DB from
  the combined dump) is the accepted trade-off.
- **Dump location:** **`/srv/data/postgres-backup`** — under `/srv/data`, so it
  rides the widened restic sweep. The `postgresqlBackup` module creates this dir
  itself (its own tmpfiles rule, `postgres:postgres 0700`); no extra
  provisioning in `postgresql.nix`.
- **Schedule:** `startAt = "02:30"` — after Immich's ~02:00 built-in dump, before
  restic's 03:00, so restic always sweeps a fresh cluster dump.
- **Immich's built-in DB dump stays enabled.** It remains the blessed restore
  path for the pgvector/vectorchord data (which a plain `pg_dumpall` restores
  less reliably); `pg_dumpall` is the safety net for everything else + globals.
  Minor duplication of Immich's DB in the backup, accepted.

## 3. Why the live DB isn't double-backed-up

The live PostgreSQL data dir is `/srv/fast/db/postgres/18` — on the `fast` pool,
**not** under `/srv/data`. So widening restic to `/srv/data` never sweeps
inconsistent live database files; it only ever captures the **dumps**
(`/srv/data/postgres-backup/*.sql.gz` and Immich's own under
`/srv/data/immich/backups/`). This is the intended shape.

## 4. The edits

### `modules/server/restic.nix`
```nix
paths = [ "/srv/data" ];
exclude = [
  "/srv/data/immich/thumbs"
  "/srv/data/immich/encoded-video"
];
```
Header comment updated: the sweep now covers **all of `/srv/data`** — Immich
originals + its DB dump, the cluster `pg_dumpall`, and any future tenant — and
the ordering note becomes `~02:00 Immich dump → 02:30 pg_dumpall → 03:00 restic`.

### `modules/server/postgresql.nix`
```nix
services.postgresqlBackup = {
  enable = true;
  backupAll = true;
  location = "/srv/data/postgres-backup";
  startAt = "02:30";
};
```
Header comment gains a short section: this is the cluster's backup story
(`pg_dumpall`, all DBs + globals), it lands under `tank/data` so restic sweeps
it, it stays tenant-agnostic (new tenants are captured automatically), and it
runs at 02:30 to be fresh before the 03:00 restic run. On-disk it keeps the
latest dump (+ one `.prev`); restic snapshots provide the history.

## 5. Repo structure

| File | Change |
|------|--------|
| `modules/server/restic.nix` | `paths` → `/srv/data`; comment update |
| `modules/server/postgresql.nix` | add `services.postgresqlBackup` (backupAll); comment |
| `docs/polaris/restic-backup-runbook.md` | document full-data sweep + pg_dumpall restore |

## 6. Documentation deliverable

Update **`docs/polaris/restic-backup-runbook.md`**:
- restic now backs up all of `/srv/data`, not just Immich.
- A cluster `pg_dumpall` lands at `/srv/data/postgres-backup/all.sql.gz`
  (`+ all.prev.sql.gz`), refreshed nightly at 02:30.
- **Restore drill:** cluster dump →
  `gunzip -c all.sql.gz | sudo -u postgres psql`; Immich itself is restored via
  Immich's own dump (its documented path), not the pg_dumpall.

## 7. Verification

- `make switch NIXNAME=polaris`.
- `sudo systemctl start postgresqlBackup.service`; then
  `ls -la /srv/data/postgres-backup/` shows `all.sql.gz`, and
  `journalctl -u postgresqlBackup` shows a clean run.
- Sanity-check the dump content: `gunzip -c /srv/data/postgres-backup/all.sql.gz
  | grep -c "CREATE DATABASE"` is ≥ 1 (immich), and `grep -q "CREATE ROLE"`
  confirms globals are present.
- `systemctl list-timers postgresqlBackup` shows the next 02:30 run.
- restic: `sudo systemctl start restic-backups-polaris.service`; a subsequent
  `sudo restic-polaris snapshots` lists a snapshot whose path is `/srv/data`, and
  a restore of `/srv/data/postgres-backup` brings the dump back.

## 8. Deferred / future

- Per-database `pg_dump` files (`databases = [...]`) if granular single-DB
  restore ever becomes a real need — costs list-maintenance and drops globals, so
  not now.
- Encrypting the dumps at rest before they hit `/srv/data` (restic already
  encrypts the offsite copy; the on-tank copy is plaintext).
- ZFS-snapshot fast-rollback tier (`services.sanoid`).

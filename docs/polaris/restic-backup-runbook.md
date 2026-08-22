# restic → Hetzner offsite backup runbook (polaris)

Purpose: get `services.restic.backups.polaris` (`modules/server/restic.nix`)
actually backing up — the manual bucket/key/secret steps that can't live in
git, plus the verify and restore-drill checks. This is the ordered,
copy-pasteable checklist to run **on polaris** (or in the Hetzner console)
after `../modules/server/restic.nix` is merged and deployed.

The module itself only references two secret file paths
(`/var/lib/secrets/restic-backend.env`, `/var/lib/secrets/restic-repo.pass`) —
it ships no credentials. Both are rendered at deploy time by the op-secrets
engine (`modules/server/op-secrets.nix`) from 1Password
(`op://polaris/restic/repo-password` and `op://polaris/restic-backend/*`); see
the **op-secrets** section of [`manual-steps.md`](manual-steps.md) for the full
bootstrap, deploy, and rotation flow. Section A below (creating the Hetzner
bucket + access key)
still applies — only the *placement* of the resulting credentials has moved,
which section B covers.

---

## A. Hetzner Object Storage: bucket + access key

**A.1 — Create the bucket.**
In the Hetzner Cloud console, Object Storage → create a bucket named
`backups-polaris` in region **`nbg1`** (Nuremberg). The region matters — it's
baked into the repository URL in `modules/server/restic.nix`
(`s3:https://nbg1.your-objectstorage.com/backups-polaris`); a bucket created
in a different region will not match.

**A.2 — Create an S3 access key.**
Still in Object Storage, generate an S3-compatible access key/secret pair
scoped to this project (or the `backups-polaris` bucket, if Hetzner's console
supports per-bucket scoping). Copy both values somewhere temporary — they go
into the `restic-backend` item in 1Password in the next section, and are not
stored anywhere else.

*Good:* the bucket `backups-polaris` exists in `nbg1`, and you're holding an
access key ID + secret key.

---

## B. Place the secrets

Both secrets are now managed through 1Password and rendered onto polaris by
the op-secrets engine (`modules/server/op-secrets.nix`) — they are **no
longer hand-placed** under `/etc/restic/`. Full bootstrap (vault/item/field
layout, service-account token), the deploy flow, and rotation are documented
once in the **op-secrets** section of [`manual-steps.md`](manual-steps.md); this
section only covers what's specific to restic's two secrets.

**B.3 — restic repo password → `restic` item, field `repo-password`.**
This is the restic **repository encryption password**, not a login password.
If you're bootstrapping fresh (no existing repo), generate a strong random one
and store it as the `repo-password` field of the `polaris/restic` item in
1Password:

```bash
openssl rand -base64 32   # paste the output into the 1Password field
```

**⚠️ Before doing anything else, make sure this value is durably stored in
1Password (with your normal 1Password backup/sync).** restic repositories are
encrypted client-side — there is no recovery mechanism. If this password is
lost, every snapshot in `backups-polaris` becomes permanently unreadable,
forever, even though the data is still sitting in the bucket.

**B.4 — Hetzner S3 credentials → `restic-backend` item.**
Store the access key ID and secret from A.2 as the `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` fields of the `polaris/restic-backend` item. The
region (`AWS_DEFAULT_REGION=nbg1`) is **not** secret and is not stored in
1Password — it's a literal in the render template.

**B.5 — Deploy and verify the render.**

```bash
make switch NIXNAME=polaris
sudo ls -l /var/lib/secrets/restic-repo.pass /var/lib/secrets/restic-backend.env
```

*Good:* both files exist, `-rw-------` owned by `root:root`; `journalctl -b |
grep op-secrets` shows `rendered restic-repo` / `rendered restic-backend`
with no `WARNING`. See the **op-secrets** section of
[`manual-steps.md`](manual-steps.md) for the token bootstrap, the per-secret
render/rollback behavior, and how to rotate either value later (edit in
1Password → `make switch` → restart the consuming unit).

---

## C. Confirm the database dumps land before restic runs

restic sweeps the whole `/srv/data` dataset — it does not dump any database
itself, it just backs up whatever dump files are on disk when it runs. Two
producers write those dumps under `/srv/data`, and both must finish *before*
the 03:00 restic timer:

- **Immich's built-in DB backup** writes to `/srv/data/immich/backups/`
  (nightly, ~02:00). restic depends on Immich doing this first.
- **The cluster `pg_dumpall`** (`services.postgresqlBackup` in
  `modules/server/postgresql.nix`) writes
  `/srv/data/postgres-backup/all.sql.gz` (plus one `all.prev.sql.gz`) nightly
  at 02:30. It captures every database plus cluster globals (roles, grants,
  passwords), so it needs no per-tenant setup — a new database is picked up
  automatically. It runs unattended; there's nothing to enable by hand.

**C.5 — Check the Immich setting.**
Immich web UI → **Administration → Settings → Backup**. Confirm the built-in
backup is **enabled**, and note its schedule (default is a nightly dump
around 02:00).

**C.6 — Confirm the ordering still holds.**
The nightly chain is `~02:00 Immich dump → 02:30 pg_dumpall → 03:00 restic`
(`startAt = "02:30"` for `postgresqlBackup`; `OnCalendar = "03:00"` in
`modules/server/restic.nix`) — so restic always sweeps fresh dumps rather
than racing them. If Immich's backup schedule ever moves away from ~02:00,
keep this chain intact: both dumps must finish a comfortable margin before
whatever time restic now runs.

*Good:* Immich's Backup setting is enabled, its scheduled time is meaningfully
earlier than 02:30, and the pg_dumpall's 02:30 timer sits before 03:00.

---

## D. Deploy

```bash
make switch NIXNAME=polaris
```

*Good:* the switch succeeds; `systemctl cat restic-backups-polaris.service`
and `systemctl cat restic-backups-polaris.timer` both exist.

---

## E. Verify + restore drill

**E.7 — First run.**

```bash
sudo systemctl start restic-backups-polaris.service
sudo journalctl -u restic-backups-polaris
```

*Good:* the log shows the repository being initialized (first run only) and
a completed snapshot, with no error exit.

**E.8 — List snapshots.**

```bash
sudo restic-polaris snapshots
```

*Good:* at least one snapshot is listed, with a path of `/srv/data` and a
size roughly matching that dataset minus `/srv/data/immich/thumbs` and
`/srv/data/immich/encoded-video`.

**E.9 — Restore drill.**
Prove the backup is actually restorable, not just uploaded — pull the cluster
dump directory back out:

```bash
sudo restic-polaris restore latest --target /tmp/restore-test \
  --include /srv/data/postgres-backup
```

Confirm `all.sql.gz` comes back under
`/tmp/restore-test/srv/data/postgres-backup/` and that it decompresses
cleanly:

```bash
gunzip -t /tmp/restore-test/srv/data/postgres-backup/all.sql.gz
sudo rm -rf /tmp/restore-test
```

*Good:* the restored dump is present and passes `gunzip -t`;
`/tmp/restore-test` is removed afterward.

**E.10 — Timer armed.**

```bash
systemctl list-timers restic-backups-polaris
```

*Good:* shows a next-run time at (or shortly after, if `Persistent` caught a
missed run) the next 03:00.

---

## F. Restoring for real

Two different databases live in these backups, restored two different ways.

**F.11 — Restore the cluster from the `pg_dumpall`.**
For a full cluster rebuild (all databases + globals), restore the dump
directory from restic as in E.9, then replay it:

```bash
gunzip -c /srv/data/postgres-backup/all.sql.gz | sudo -u postgres psql
```

`pg_dumpall` output is a plain SQL script that recreates every role and
database, so it's fed straight into `psql` as the `postgres` superuser — no
`-d <db>`, it targets the whole cluster. This is the path for disaster
recovery or resurrecting a non-Immich tenant.

**F.12 — Restore Immich from Immich's own dump, not the `pg_dumpall`.**
Immich's database uses pgvector/vectorchord, which `pg_dumpall` restores less
reliably. Restore Immich from *its own* built-in dump under
`/srv/data/immich/backups/`, following Immich's documented restore procedure
— the `pg_dumpall` is the safety net for the rest of the cluster and the
globals, not the blessed path for Immich itself.

*Good:* you know which dump to reach for — cluster or non-Immich tenant →
`all.sql.gz` piped into `psql`; Immich → Immich's own dump via Immich's docs.

---

## G. Gotcha: region mismatches

⚠️ **Region (bounded iteration).** If restic errors on bucket location/region
against Hetzner (e.g. a `BadRequest`/region-mismatch error from the S3
endpoint), double-check:

- The bucket in A.1 was actually created in `nbg1`, matching the
  `nbg1.your-objectstorage.com` host in the `repository` URL.
- `AWS_DEFAULT_REGION=nbg1` is present in the rendered
  `/var/lib/secrets/restic-backend.env` (it's a literal in the render
  template, not a 1Password field — see B.4 above).

If both already match and restic still complains, set
`services.restic.backups.polaris.extraOptions = [ "s3.region=nbg1" ]` in
`modules/server/restic.nix`. Note the bare value with **no** leading `-o` —
NixOS prepends `-o` to each `extraOptions` element itself, so writing
`-o s3.region=nbg1` would produce a doubled `-o -o s3.region=nbg1` and fail.
This is a one-line config fix, not a reason to redesign the backup.

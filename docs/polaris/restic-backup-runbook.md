# restic → Hetzner offsite backup runbook (polaris)

Purpose: get `services.restic.backups.polaris` (`modules/server/restic.nix`)
actually backing up — the manual bucket/key/secret steps that can't live in
git, plus the verify and restore-drill checks. This is the ordered,
copy-pasteable checklist to run **on polaris** (or in the Hetzner console)
after `../modules/server/restic.nix` is merged and deployed.

The module itself only references two secret file paths
(`/etc/restic/hetzner.env`, `/etc/restic/polaris.pass`) — it ships no
credentials. Everything in section A and B below is what makes those paths
real.

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
into `/etc/restic/hetzner.env` in the next section and are not stored
anywhere else.

*Good:* the bucket `backups-polaris` exists in `nbg1`, and you're holding an
access key ID + secret key.

---

## B. Place the secrets on polaris

Both files are hand-placed, `0600`, owned by `root` — the same convention as
`/etc/caddy/route53.env` (see `modules/media/caddy.nix`). Nothing under
`/etc/restic/` is tracked in git.

**B.3 — `/etc/restic/hetzner.env`.**

```bash
sudo install -d -m 0700 /etc/restic
sudo tee /etc/restic/hetzner.env >/dev/null <<'EOF'
AWS_ACCESS_KEY_ID=<hetzner access key from A.2>
AWS_SECRET_ACCESS_KEY=<hetzner secret key from A.2>
AWS_DEFAULT_REGION=nbg1
EOF
sudo chown root:root /etc/restic/hetzner.env
sudo chmod 0600 /etc/restic/hetzner.env
```

**B.4 — `/etc/restic/polaris.pass`.**
This is the restic **repository encryption password**, not a login password —
generate a strong random one:

```bash
openssl rand -base64 32 | sudo tee /etc/restic/polaris.pass >/dev/null
sudo chown root:root /etc/restic/polaris.pass
sudo chmod 0600 /etc/restic/polaris.pass
```

**⚠️ Before doing anything else, copy this password into a password manager,
off-box.** restic repositories are encrypted client-side — there is no
recovery mechanism. If `/etc/restic/polaris.pass` is lost and no copy exists
elsewhere, every snapshot in `backups-polaris` becomes permanently
unreadable, forever, even though the data is still sitting in the bucket.

*Good:* `sudo cat /etc/restic/hetzner.env` shows the three `AWS_*` lines;
`sudo cat /etc/restic/polaris.pass` shows a random password; both files are
`-rw-------` owned by `root:root`; the password also lives in a password
manager, not just on polaris.

---

## C. Confirm Immich's built-in DB backup is still on

The restic module backs up whatever is on disk under `/srv/data/immich` —
including `/srv/data/immich/backups/`, where Immich writes its own database
dumps. restic does not dump the database itself; it depends on Immich doing
that first.

**C.5 — Check the setting.**
Immich web UI → **Administration → Settings → Backup**. Confirm the built-in
backup is **enabled**, and note its schedule (default is a nightly dump
around 02:00).

**C.6 — Confirm the ordering still holds.**
`modules/server/restic.nix` fires the restic timer at `OnCalendar = "03:00"`
— an hour after Immich's ~02:00 dump — so restic always sweeps a fresh
database backup rather than racing it. If the Immich backup schedule is ever
changed away from ~02:00, the restic timer should move with it (stay at
least a comfortable margin after whatever time Immich now runs).

*Good:* Immich's Backup setting is enabled, and its scheduled time is
meaningfully earlier than 03:00.

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

*Good:* at least one snapshot is listed, with a size roughly matching
`/srv/data/immich` minus `thumbs/` and `encoded-video/`.

**E.9 — Restore drill.**
Prove the backup is actually restorable, not just uploaded:

```bash
sudo restic-polaris restore latest --target /tmp/restore-test \
  --include /srv/data/immich/backups
```

Confirm a DB dump file comes back under `/tmp/restore-test/srv/data/immich/backups/`
and diff it against what's currently in `/srv/data/immich/backups/` (it
should be an earlier or matching dump, not empty or corrupt). Then clean up:

```bash
sudo rm -rf /tmp/restore-test
```

*Good:* the restored DB dump is present and readable; `/tmp/restore-test` is
removed afterward.

**E.10 — Timer armed.**

```bash
systemctl list-timers restic-backups-polaris
```

*Good:* shows a next-run time at (or shortly after, if `Persistent` caught a
missed run) the next 03:00.

---

## F. Gotcha: region mismatches

⚠️ **Region (bounded iteration).** If restic errors on bucket location/region
against Hetzner (e.g. a `BadRequest`/region-mismatch error from the S3
endpoint), double-check:

- The bucket in A.1 was actually created in `nbg1`, matching the
  `nbg1.your-objectstorage.com` host in the `repository` URL.
- `AWS_DEFAULT_REGION=nbg1` is present in `/etc/restic/hetzner.env` (already
  specified in B.3 above).

If both already match and restic still complains, add an explicit
`-o s3.region=nbg1` to `extraOptions` in
`services.restic.backups.polaris` (`modules/server/restic.nix`). This is a
one-line config fix, not a reason to redesign the backup.

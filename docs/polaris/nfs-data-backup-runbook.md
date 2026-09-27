# NFS data-mirror backup runbook (polaris)

Purpose: get `polaris-data-nfs-sync` (`modules/server/data-nfs-backup.nix`)
mirroring `/srv/data` to the house NAS every 12 hours (00:00 and 12:00) — the
manual NAS-side export steps that can't live in git, plus the verify checks.
Run section A **on the NAS (`192.168.1.88`)**, the rest **on polaris**.

The module only references the mountpoint `/mnt/polaris-nfs` (an on-demand
automount) and the share `192.168.1.88:/volume1/polaris` — it creates no export.
The mirror is a plain `rsync -a --delete --no-owner --no-group` copy on a trusted
LAN and lands as plaintext on the NAS; the encrypted offsite tier is
restic→Hetzner ([restic-backup-runbook.md](restic-backup-runbook.md)).

---

## A. NAS side: create the `/volume1/polaris` NFS export

Do these by hand on `192.168.1.88` (a Synology — its web UI or `/etc/exports`).
The polaris config references the export path only — it does not create it.

**A.1 — Create/confirm the `/volume1/polaris` export.**
Create (or confirm) a shared folder named **`polaris`**. On Synology, shared
folders live under `/volume1`, so its NFS export path is **`/volume1/polaris`**
(not `/polaris`) — this is exactly the path the client mounts
(`192.168.1.88:/volume1/polaris`). Make sure it is served over **NFSv4** — the
client pins `nfsvers=4.0` and will not fall back to v3.

**A.2 — Allow the polaris host, read-write.**
Grant the polaris host **`192.168.1.50`** **read-write** access to the export
(that's polaris's static LAN address, the `br0` IP from
`machines/polaris.nix`). Read-only would let the mount succeed but every rsync
run would fail on write.

**A.3 — `root_squash` is fine.**
The sync runs as **root** on polaris (to read the root-owned `immich/` subtree).
The module passes `--no-owner --no-group`, so rsync never tries to `chown` on the
NAS; the export can keep the default `root_squash` (files land owned by the NAS's
anonymous UID). There's no need to grant `no_root_squash`.

**A.4 — Confirm capacity.**
Make sure the export has room for the full `/srv/data` mirror **minus** the two
excluded Immich dirs (`immich/thumbs`, `immich/encoded-video`, which Immich
regenerates on demand). It's a 1:1 mirror with `--delete`, so budget for the
live size of `/srv/data` on polaris, not just the current delta.

*Good:* `showmount -e 192.168.1.88` (or the NAS UI) lists `/volume1/polaris`
allowing `192.168.1.50` RW, and the export has capacity for `du -sh --exclude=immich/thumbs
--exclude=immich/encoded-video /srv/data` worth of data.

---

## B. Deploy

```bash
make switch NIXNAME=polaris
```

*Good:* the switch succeeds; `systemctl cat polaris-data-nfs-sync.service` and
`systemctl cat polaris-data-nfs-sync.timer` both exist.

---

## C. Verify

**C.5 — Automount armed.**

```bash
systemctl status mnt-polaris\\x2dnfs.automount
```

*Good:* the automount unit is loaded and active (listening); the NAS is not
mounted yet, and that's expected — it mounts on first access.

**C.6 — Trigger the mount.**

```bash
ls /mnt/polaris-nfs
mountpoint /mnt/polaris-nfs
```

*Good:* the first `ls` triggers the automount, and `mountpoint` reports it *is*
a mountpoint. If the NAS is offline this is where it fails cleanly rather than
booting into a broken state.

**C.7 — First manual run.**

```bash
sudo systemctl start polaris-data-nfs-sync.service
sudo journalctl -u polaris-data-nfs-sync
```

*Good:* rsync completes and the unit exits 0. Any non-zero exit is a genuine
failure (ownership errors are no longer possible — see A.3). If the NAS is
unreachable the unit fails on the mount dependency rather than mirroring into
an empty `/mnt/polaris-nfs` on the root disk.

**C.8 — Spot-check the mirror.**

```bash
ls /mnt/polaris-nfs
ls /mnt/polaris-nfs/immich
```

*Good:* a file present under `/srv/data` shows up under `/mnt/polaris-nfs`, and
the two excluded dirs — `/mnt/polaris-nfs/immich/thumbs` and
`/mnt/polaris-nfs/immich/encoded-video` — are **absent**, while the rest of
`immich/` (`library/`, `upload/`, `profile/`, `backups/`) is present.

**C.9 — Timer armed.**

```bash
systemctl list-timers polaris-data-nfs-sync
```

*Good:* shows a next-run time at the next 00:00 or 12:00 (or shortly after, if
`Persistent` caught a run missed while the box was off).

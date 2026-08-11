# NFS data-mirror backup runbook (polaris)

Purpose: get `polaris-data-nfs-sync` (`modules/server/data-nfs-backup.nix`)
actually mirroring `/srv/data` to the house NAS — the manual NAS-side export
steps that can't live in git, plus the post-deploy verify checks. This is the
ordered, copy-pasteable checklist to run **on the NAS (`192.168.1.88`)** and
then **on polaris**, after `../modules/server/data-nfs-backup.nix` is merged
and deployed.

The module itself only references the mountpoint `/mnt/polaris-nfs` and the
share `192.168.1.88:/polaris` — it creates no export and ships no NAS config.
Everything in section A below is what makes that share real. This mirror is a
plain `rsync -a --delete` copy on a trusted LAN; it lands as plaintext on the
NAS (the encrypted end-to-end tier stays restic→Hetzner, see
`docs/polaris/restic-backup-runbook.md`).

---

## A. NAS side: create the `/polaris` NFS export

Do these by hand on `192.168.1.88` (its web UI or `/etc/exports`, depending on
the NAS). The polaris config references the export path only — it does not
create it.

**A.1 — Create/confirm the `/polaris` export.**
Create (or confirm) an NFS export whose path is **`/polaris`**. The client
mounts `192.168.1.88:/polaris` directly, so the export must be `/polaris`
itself, not a parent directory with a `polaris/` subfolder. Make sure it is
served over **NFSv4** — the client pins `nfsvers=4.0` and will not fall back to
v3.

**A.2 — Allow the polaris host, read-write.**
Grant the polaris host **`192.168.1.50`** **read-write** access to the export
(that's polaris's static LAN address, the `br0` IP from
`machines/polaris.nix`). Read-only would let the mount succeed but every rsync
run would fail on write.

**A.3 — Decide `root_squash` vs `no_root_squash`.**
The sync runs as **root** on polaris (it has to, to read the root-owned
`immich/` subtree), and `rsync -a` tries to preserve ownership on the NAS side:

- With **`root_squash`** (the usual default), root-owned files land owned by
  the NAS's anonymous UID, and `rsync -a` tries to reset owner on every run —
  producing a benign permission error logged per file, every hour. Harmless,
  but noisy in the journal.
- With **`no_root_squash`**, polaris's root maps to the NAS's root and
  ownership is preserved cleanly, so there's no per-file churn. Choose this if
  the noise is unwanted and you trust polaris's root on this export.

`--numeric-ids` is already set in the module so UIDs aren't remapped through the
NAS's name service either way — this decision only affects the ownership-reset
churn above.

**A.4 — Confirm capacity.**
Make sure the export has room for the full `/srv/data` mirror **minus** the two
excluded Immich dirs (`immich/thumbs`, `immich/encoded-video`, which Immich
regenerates on demand). It's a 1:1 mirror with `--delete`, so budget for the
live size of `/srv/data` on polaris, not just the current delta.

*Good:* `showmount -e 192.168.1.88` (or the NAS UI) lists `/polaris` allowing
`192.168.1.50` RW; the `root_squash` choice is made deliberately; and the
export has capacity for `du -sh --exclude=immich/thumbs
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

*Good:* the log shows rsync completing without a non-zero exit. (With
`root_squash` on the export you may see benign per-file `chown`/permission
warnings — see A.3; those are expected and not a failure.)

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

*Good:* shows a next-run time at the next hourly boundary (or shortly after, if
`Persistent` caught a run missed while the box was off).

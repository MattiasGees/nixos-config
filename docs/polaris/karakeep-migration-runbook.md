# Karakeep — k8s → polaris migration runbook

What **you** run by hand to move Karakeep off the Hetzner Kubernetes cluster onto
polaris. `make switch` builds the service; this guide covers the dataset, the
secret, and the one-shot data move (SQLite DB + assets). Design + rationale:
[`docs/superpowers/specs/2026-08-15-polaris-karakeep-design.md`](../superpowers/specs/2026-08-15-polaris-karakeep-design.md).

**Data lives at** `/srv/fast/appdata/karakeep` (fast NVMe mirror, encrypted),
bind-mounted onto `/var/lib/karakeep` (the module's pinned `DATA_DIR`).
**Backup:** it lives under `/srv/fast/appdata`, which `restic.nix` sweeps offsite;
a 02:45 timer writes a consistent `.backup` + `.dump` into `backups/` before the
03:00 sweep.

> **Version note (safe):** k8s runs app `0.33.1`; polaris nixpkgs ships `0.33.0`.
> The drizzle schema is **identical** (94 migrations), so this is not a downgrade —
> `karakeep-init` migrate is a no-op against the copied DB. No flake bump needed.

Prereqs on your workstation: the **hetzner kubectl context** and SSH to polaris
(`mattias@192.168.1.50`). polaris sudo needs a **password** and the setuid
wrapper `/run/wrappers/bin/sudo`, so the sudo steps below use `ssh -t`.

---

## 1. Storage — nothing to provision

The data dir is a plain subdir of the existing `fast/appdata` dataset
(`/srv/fast/appdata/karakeep`), created automatically by the karakeep module
(tmpfiles, owned `karakeep`) and bind-mounted onto `/var/lib/karakeep` on the
first `make switch`. No `zfs create`, no manual step — it inherits `fast/appdata`'s
encryption and rides the `/srv/fast/appdata` restic sweep. (Verify after deploy
with `findmnt /var/lib/karakeep` — step 3.)

## 2. Place the OpenAI key (polaris)

See [manual-steps.md §12](manual-steps.md#12-karakeep-openai-key) — the key is
pulled from the old k8s Secret so it never enters the repo:

```bash
# workstation (hetzner kubectl context):
KEY=$(kubectl get secret karakeep-secrets -n karakeep \
        -o jsonpath='{.data.OPENAI_API_KEY}' | base64 -d)

# on polaris:
ssh -t mattias@192.168.1.50 "
  /run/wrappers/bin/sudo install -d -m 0755 /etc/karakeep &&
  printf 'OPENAI_API_KEY=%s\n' '$KEY' \
    | /run/wrappers/bin/sudo install -m 0600 /dev/stdin /etc/karakeep/karakeep.env
"
```

## 3. Deploy (polaris) — empty instance first

```bash
ssh -t mattias@192.168.1.50 'cd ~/git/nixos-config && make switch NIXNAME=polaris'
```

This proves config + TLS + the bind mount before real data moves. `karakeep-init`
generates `/var/lib/karakeep/settings.env` (fresh `NEXTAUTH_SECRET`/`MEILI_MASTER_KEY`)
and an empty, schema-current DB. Check `https://karakeep.polaris.mattiasgees.be`
loads (the sign-up is disabled — that's expected; the admin arrives with the data).

Sanity:
```bash
ssh mattias@192.168.1.50 'systemctl is-active karakeep-web karakeep-workers meilisearch; findmnt /var/lib/karakeep'
```
`findmnt` must show `/var/lib/karakeep` bound to `/srv/fast/appdata/karakeep`.

---

## 4. Freeze the source

Scale the only writer (`web`) to zero so the SQLite DB is closed cleanly (WAL
checkpointed) and the RWO PVC detaches:

```bash
kubectl -n karakeep scale deploy/web --replicas=0
kubectl -n karakeep rollout status deploy/web --timeout=120s   # waits for 0 pods
```

## 5. Copy the data out of the PVC

Spin a throwaway pod that mounts `data-pvc` read-only:

```bash
kubectl -n karakeep apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: karakeep-migrate
  namespace: karakeep
spec:
  restartPolicy: Never
  containers:
  - name: shell
    image: alpine:3
    command: ["sleep", "3600"]
    volumeMounts:
    - { name: data, mountPath: /data, readOnly: true }
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: data-pvc
EOF
kubectl -n karakeep wait --for=condition=Ready pod/karakeep-migrate --timeout=120s
```

Record the **source bookmark count** (compare after cutover):

```bash
kubectl -n karakeep exec karakeep-migrate -- \
  sh -c 'apk add -q sqlite >/dev/null && sqlite3 /data/db.db "select count(*) from bookmarks;"'
```

Stream the whole data dir (DB + assets) to polaris as a tarball:

```bash
kubectl -n karakeep exec karakeep-migrate -- tar -C /data -cf - . \
  | ssh mattias@192.168.1.50 'cat > /tmp/karakeep-data.tar'
```

## 6. Load it on polaris (keeps the generated `settings.env`)

The tar has no `settings.env`, so extracting over `/var/lib/karakeep` overwrites
`db.db` + `assets/` while leaving the fresh secrets in place:

```bash
ssh -t mattias@192.168.1.50 '
  S=/run/wrappers/bin/sudo
  $S systemctl stop karakeep-web karakeep-workers karakeep-browser &&
  $S tar -C /var/lib/karakeep -xf /tmp/karakeep-data.tar &&
  $S chown -R karakeep:karakeep /var/lib/karakeep &&
  $S systemctl restart karakeep-init &&   # drizzle migrate: no-op, schema already current
  $S systemctl start karakeep-workers karakeep-web &&
  rm -f /tmp/karakeep-data.tar
'
```

## 7. Reindex Meilisearch

The k8s search index is **not** migrated — rebuild it from the copied DB. In the
web UI: **Admin → Background jobs / "Reindex all bookmarks"** (log in first; you
get one fresh login because `NEXTAUTH_SECRET` was regenerated). Watch it drain:

```bash
ssh mattias@192.168.1.50 'journalctl -u karakeep-workers -f'
```

---

## 8. Verify

```bash
# polaris bookmark count — must match the source count from step 5:
ssh mattias@192.168.1.50 \
  'sqlite3 /var/lib/karakeep/db.db "select count(*) from bookmarks;"'
```

- Log in at `https://karakeep.polaris.mattiasgees.be` (your migrated account).
- Open a bookmark → its screenshot/archive asset renders (assets copied).
- Search returns a known bookmark (Meilisearch reindex worked).
- Add a new bookmark → the worker crawls it and AI tagging fills tags (OpenAI key
  wired). If tagging stalls, check `journalctl -u karakeep-workers` for auth errors.
- Backup exports land:
  ```bash
  ssh mattias@192.168.1.50 '
    /run/wrappers/bin/sudo systemctl start karakeep-sqlite-backup &&
    ls -l /srv/fast/appdata/karakeep/backups/ &&
    sqlite3 /srv/fast/appdata/karakeep/backups/db.db "pragma integrity_check;"'
  ```
  Expect `db.db` + `db.sql.gz` and `ok`.

## 9. Clean up / rollback

```bash
kubectl -n karakeep delete pod karakeep-migrate     # remove the temp pod
```

**Rollback** (any time before decommissioning): `kubectl -n karakeep scale
deploy/web --replicas=1` — the k8s PVC was mounted read-only and is untouched, so
the old instance comes straight back.

**Decommission** (only once polaris is confirmed good, per the design's
follow-ups): delete `config/bases/karakeep` from the k8s config, then the CNPG-less
PVCs and the AWS `karakeep` secret.

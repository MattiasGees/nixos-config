# Karakeep on polaris — Design (bookmark app; migrate off Kubernetes)

**Status:** Draft for review
**Date:** 2026-08-15
**Host:** `polaris`

## 1. Purpose & scope

Move **Karakeep** (self-hostable bookmark-everything app — links, notes, images,
with full-text search and OpenAI-based auto-tagging/OCR) off the Hetzner
Kubernetes cluster onto polaris, served at
**`https://karakeep.polaris.mattiasgees.be`**, via the upstream `services.karakeep`
NixOS module. Existing bookmarks, assets, and user accounts are migrated by
copying the app's SQLite DB + assets out of the k8s `data-pvc`.

**Scope:** the `services.karakeep` module wiring (`modules/media/karakeep.nix`),
storage on a dedicated `fast`-pool dataset with an explicit restic path and
consistency-dump exports, the AI settings + hand-placed OpenAI key, the Caddy
vhost, the one-shot data migration, and a runbook. **Out of scope** (follow-ups):
deleting the k8s manifests (`config/bases/karakeep`) once polaris is verified, and
moving the OpenAI key into sops-nix.

## 2. Source state (k8s, `config/bases/karakeep`)

- **App image `ghcr.io/karakeep-app/karakeep:0.33.1`**; `web`, `chrome`
  (headless chromium :9222), `meilisearch v1.11.1` deployments. No separate
  workers deployment.
- **Data:** a 10Gi `data-pvc` mounted at `/data` (SQLite `db.db` + `assets/`).
  A separate `meilisearch-pvc` (search index — re-derivable, **not** migrated).
- **Config (ConfigMap + web env):** `NEXTAUTH_URL=http://karakeep.k8s.mattiasgees.be`,
  `INFERENCE_TEXT_MODEL=gpt-4o-mini`, `INFERENCE_IMAGE_MODEL=gpt-4o-mini` (both
  pinned "due to bug"), `OCR_USE_LLM=true`, `DATA_DIR=/data`,
  `MEILI_ADDR`/`BROWSER_WEB_URL` (module sets these automatically on polaris).
- **Secrets (AWS Secrets Manager → `karakeep-secrets`):** `MEILI_MASTER_KEY`,
  `NEXTAUTH_SECRET`, `NEXT_PUBLIC_SECRET`, `OPENAI_API_KEY`. Only `OPENAI_API_KEY`
  carries over (see §4.6); the rest are regenerated or unused on polaris.

## 3. Key facts

### 3.1 Karakeep is SQLite-only
Unlike Immich/Miniflux (shared pg18 tenants), Karakeep has **no PostgreSQL
support** — confirmed upstream (DB lives in `DATA_DIR` as SQLite; only a
`DB_WAL_MODE` toggle, no `DATABASE_URL`) and in the module (no DB option;
bundled `better-sqlite3`). The shared Postgres is not used.

### 3.2 The version gap is schema-safe (no flake change)
k8s runs app **0.33.1**; the `mattias`-pinned nixpkgs (`0e251e2`) ships karakeep
**0.33.0** (built from the `cli/v0.33.0` tag — karakeep versions its CLI tag
separately, and there is no `v0.33.0` app release). The drizzle **migration set is
identical** across `cli/v0.33.0`, `cli/v0.33.1`, and `v0.33.1` — **94 migrations,
last `0093_reader_view_assessment`**. So 0.33.0↔0.33.1 is code/bugfix only, no
schema change: running the 0.33.1 data on the 0.33.0 binary is safe (migrate is a
no-op). **No `nix flake update` or overlay pin required.** (Optionally moves to
≥0.33.1 on a later flake update.)

## 4. Decisions (locked)

### 4.1 `DATA_DIR` stays `/var/lib/karakeep`
The module hardcodes `DATA_DIR=/var/lib/karakeep` for the runtime services while
`karakeep-init`/migrate derives it from `StateDirectory` (also `/var/lib/karakeep`).
Overriding only the runtime value desyncs migrate from runtime and collides in the
env `lib.mkMerge`; docs call changing it "not supported". **So storage is mounted
at `/var/lib/karakeep`, not repointed.**

### 4.2 Storage — dedicated `fast`-pool dataset, bind-mounted
Data goes on the **fast** pool (mirrored, encrypted NVMe — better than the HDD
`tank` for a busy SQLite DB, and the user's `appdata` convention):

- Dedicated child dataset **`fast/appdata/karakeep`** at **`/srv/fast/appdata/karakeep`**
  (inherits `fast/appdata` encryption; manual `zfs create`, §7 — datasets are
  out-of-band on this host).
- **Bind-mount** `/srv/fast/appdata/karakeep → /var/lib/karakeep` in `karakeep.nix`,
  so the module runs unchanged. Chosen over a **symlink**: the services use systemd
  `StateDirectory=karakeep`, so systemd owns/creates/chowns `/var/lib/karakeep` each
  start; a symlink there is fragile (systemd may recreate/replace it, version-
  dependent), a bind mount presents a real directory it manages cleanly.

### 4.3 Backup — explicit restic path (not under `/srv/data`)
`/srv/fast/appdata/karakeep` is outside the `/srv/data` sweep, so `karakeep.nix`
adds it explicitly (list-merges with restic.nix's `/srv/data`):
```nix
services.restic.backups.polaris.paths = [ "/srv/fast/appdata/karakeep" ];
```
The hourly NFS mirror (tank/data only) is **not** extended — restic offsite is the
backup tier for this app.

### 4.4 SQLite consistency exports (reliability)
restic copies live files; a live SQLite DB (WAL) can be captured torn. A
`karakeep-sqlite-backup` oneshot+timer runs at **02:45** (before 03:00 restic), as
the `karakeep` user, producing **both** into `/srv/fast/appdata/karakeep/backups/`:
- `db.db` via `sqlite3 … ".backup"` — consistent binary snapshot (exact, fast restore).
- `db.sql.gz` via `sqlite3 … ".dump" | gzip` — portable SQL text (format-independent,
  inspectable).
Both ride the restic path. `DB_WAL_MODE=true`; the `.backup`/`.dump` APIs are
WAL-aware. Assets are immutable blobs, safe to copy live.

### 4.5 Meilisearch — default location, reindexed post-migration
Left at the module default (on, `/var/lib/meilisearch`, root disk; runs keyless on
localhost — the module doesn't set a master key, so `MEILI_MASTER_KEY` is moot).
The index is re-derivable, so it is **not** on `fast` and **not** backed up. The
k8s meili index is **not** migrated; after cutover the bookmarks are **reindexed**
on polaris (§6 step 6).

### 4.6 AI features + ingress + auth
- **AI (carried over):** `INFERENCE_TEXT_MODEL=gpt-4o-mini`,
  `INFERENCE_IMAGE_MODEL=gpt-4o-mini`, `OCR_USE_LLM=true` in `extraEnvironment`
  (git). The **`OPENAI_API_KEY`** secret goes in hand-placed
  `/etc/karakeep/karakeep.env` (0600, out of git) via `services.karakeep.environmentFile`
  — same convention as miniflux `admin.env` / caddy `route53.env`. The module feeds
  this file to the `web` + `workers` units (workers do the inference).
- **Ingress:** Caddy `karakeep.polaris.mattiasgees.be → localhost:3000` via the
  existing `proxy` helper. No firewall change, no new DNS record (wildcard already
  resolves); remote access via Tailscale.
- **`NEXTAUTH_URL=https://karakeep.polaris.mattiasgees.be`** (new host).
- **`NEXTAUTH_SECRET`:** module-generated (fresh). It only signs session JWTs — no
  DB data is encrypted with it — so the only effect is a one-time re-login after
  cutover. Not reused (keeps the secret file to `OPENAI_API_KEY` only).
- **Signups:** the migrated DB already contains the admin account, so
  `DISABLE_SIGNUPS=true` is set from the start. `DISABLE_NEW_RELEASE_CHECK=true`
  (Nix-managed).

## 5. NixOS changes (declarative)

### `modules/media/karakeep.nix` (new)
Beside `immich.nix`/`miniflux.nix`. Header documents SQLite-not-Postgres, the
`DATA_DIR` constraint, the bind mount, the explicit restic path, and the exports.

```nix
{ pkgs, ... }:
{
  services.karakeep = {
    enable = true;                         # meilisearch + headless chromium on by default
    environmentFile = "/etc/karakeep/karakeep.env";   # OPENAI_API_KEY (hand-placed, 0600)
    extraEnvironment = {
      NEXTAUTH_URL = "https://karakeep.polaris.mattiasgees.be";
      DB_WAL_MODE = "true";
      DISABLE_NEW_RELEASE_CHECK = "true";
      DISABLE_SIGNUPS = "true";            # admin already exists in the migrated DB
      INFERENCE_TEXT_MODEL = "gpt-4o-mini";
      INFERENCE_IMAGE_MODEL = "gpt-4o-mini";
      OCR_USE_LLM = "true";
    };
  };

  # Data on the fast pool (redundant, encrypted); DATA_DIR is pinned to
  # /var/lib/karakeep by the module, so bind the dataset there.
  fileSystems."/var/lib/karakeep" = {
    device = "/srv/fast/appdata/karakeep";
    options = [ "bind" ];
  };

  # Outside /srv/data → add to restic explicitly (merges with the /srv/data path).
  services.restic.backups.polaris.paths = [ "/srv/fast/appdata/karakeep" ];

  # Consistency exports before the 03:00 restic run: a WAL-aware binary .backup
  # and a portable gzipped .dump. Restic sweeps both via the path above.
  systemd.services.karakeep-sqlite-backup = {
    description = "Consistent SQLite exports of Karakeep DB for backup";
    after = [ "karakeep-web.service" ];
    path = [ pkgs.sqlite pkgs.gzip ];
    serviceConfig = {
      Type = "oneshot";
      User = "karakeep";
      Group = "karakeep";
      ExecStart = pkgs.writeShellScript "karakeep-sqlite-backup" ''
        set -euo pipefail
        db=/var/lib/karakeep/db.db
        out=/var/lib/karakeep/backups
        [ -f "$db" ] || { echo "no db yet: $db"; exit 0; }
        install -d -m 0700 "$out"
        sqlite3 "$db" ".backup '$out/db.db'"
        sqlite3 "$db" ".dump" | gzip -c > "$out/db.sql.gz"
      '';
    };
  };
  systemd.timers.karakeep-sqlite-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "02:45"; Persistent = true; };
  };
}
```

### `modules/media/caddy.nix` (edit)
```nix
virtualHosts."karakeep.polaris.mattiasgees.be".extraConfig = proxy 3000;
```

### `machines/polaris.nix` (edit)
Add `../modules/media/karakeep.nix` to `imports`.

## 6. Data migration (user-run, like miniflux)

Run from the workstation (has the hetzner kubectl context + SSH to polaris,
`mattias@192.168.1.50`; sudo needs a password and `/run/wrappers/bin/sudo`).

1. **Create the dataset + place the secret** on polaris (§7), then
   **`make switch NIXNAME=polaris`** — karakeep comes up **empty** at the new URL
   over TLS; `karakeep-init` generates `settings.env` and an empty migrated DB.
   Proves config/TLS/bind mount before real data moves.
2. **Freeze source** — `kubectl scale deploy/web -n karakeep --replicas=0`
   (the only writer); wait for the pod to terminate.
3. **Count source** — record bookmark/asset counts (temp pod reading `data-pvc`,
   or from a pre-freeze `sqlite3` count) for the verify step.
4. **Copy `/data` out** — spin a temp pod mounting `data-pvc`, tar `db.db` +
   `assets/`, stream over SSH to polaris; `systemctl stop karakeep-{web,workers,browser}`,
   extract into `/srv/fast/appdata/karakeep` (**keep** the generated `settings.env`;
   overwrite `db.db`, merge `assets/`), then `chown -R karakeep:karakeep`.
5. **Re-run init + start** — `systemctl restart karakeep-init` (drizzle migrate is a
   no-op against the schema-current data — sanity check), then start
   `karakeep-workers`/`karakeep-web`.
6. **Reindex Meilisearch** — trigger "Reindex all bookmarks" (admin settings / CLI)
   to populate the fresh local index from the migrated DB.
7. **Verify** — counts match source (step 3); log in (fresh session — expected one
   re-login); open a bookmark (asset present); search returns it; after 02:45 (or a
   manual `systemctl start karakeep-sqlite-backup`) `backups/db.db` +
   `backups/db.sql.gz` exist and `pragma integrity_check` passes.

Rollback: `kubectl scale deploy/web -n karakeep --replicas=1` — the k8s PVC is
untouched.

## 7. Manual steps (runbook — `docs/polaris/karakeep-runbook.md`)

```bash
# 1. Dataset on the fast pool (inherits fast/appdata encryption):
sudo zfs create -o mountpoint=/srv/fast/appdata/karakeep fast/appdata/karakeep

# 2. OpenAI key (pulled from the k8s secret; never enters the repo):
KEY=$(kubectl get secret karakeep-secrets -n karakeep \
        -o jsonpath='{.data.OPENAI_API_KEY}' | base64 -d)
sudo install -d -m 0755 /etc/karakeep
printf 'OPENAI_API_KEY=%s\n' "$KEY" \
  | sudo install -m 0600 /dev/stdin /etc/karakeep/karakeep.env
```
Then the migration procedure (§6), and finally the reindex + verify checklist.

## 8. Follow-ups (not this change)

- Remove the k8s manifests (`config/bases/karakeep`) + AWS secret once polaris is
  confirmed good.
- Move `OPENAI_API_KEY` into **sops-nix** (with the queued miniflux/caddy secrets).
- Optionally bump karakeep to ≥0.33.1/0.33.2 on the next `nix flake update`.
- Revisit the `gpt-4o-mini` inference pin if the upstream bug that forced it is fixed.

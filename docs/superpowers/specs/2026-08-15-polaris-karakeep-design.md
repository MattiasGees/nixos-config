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

### 4.1 `DATA_DIR` can't be repointed — `/var/lib/karakeep` is unavoidable
Overriding `DATA_DIR` does **not** work cleanly: (a) `karakeep-init`/migrate
ignores the env value and does `export DATA_DIR="$STATE_DIRECTORY"`, and
`StateDirectory` is always relative to `/var/lib` (→ `/var/lib/karakeep`), so the
DB is always built there; (b) the units load the generated secrets from a
hardcoded `EnvironmentFile=/var/lib/karakeep/settings.env`. Overriding only the
runtime `DATA_DIR` would split the DB from the app. Truly moving it means
replacing the module's init script — fragile across updates. **So we keep
`/var/lib/karakeep` and back it with a bind mount.**

### 4.2 Storage — plain `fast/appdata` subdir, bind-mounted (no dataset)
Data goes on the **fast** pool (mirrored, encrypted NVMe — better than the HDD
`tank` for a busy SQLite DB), as a plain subdir of the **existing** `fast/appdata`
dataset — the same convention as bazarr/sonarr/… — so **no `zfs create`, no manual
step**:

- `systemd.tmpfiles` creates **`/srv/fast/appdata/karakeep`** owned `karakeep`
  (inherits `fast/appdata` encryption).
- A hand-rolled **`systemd.mounts`** bind unit binds it onto `/var/lib/karakeep`,
  ordered **after `systemd-tmpfiles-setup`** so the source subdir exists first. A
  plain `fileSystems` bind can't be used: it mounts at `local-fs.target`, *before*
  tmpfiles runs, and would bind an empty dir. The karakeep units carry
  `RequiresMountsFor=/var/lib/karakeep` so none start before the bind is up (never
  writing to the empty underlying dir on the root disk).

(Rejected: a dedicated child dataset — cleaner boot story, but a manual `zfs
create`; and mounting a dataset directly at `/var/lib/karakeep` — would fall
outside `/srv/fast/appdata` and need its own restic path.)

### 4.3 Backup — the whole `/srv/fast/appdata` (restic.nix)
`/srv/fast/appdata` (every service's config/SQLite on the fast mirror) is added to
restic's paths in `modules/server/restic.nix`, so karakeep and the rest of the app
stack all ride the offsite sweep — no per-app restic path in `karakeep.nix`. Those
app DBs are copied live; karakeep is the only one with a consistent export (§4.4).
The hourly NFS mirror (tank/data only) is **not** extended.

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

  # Data on the fast pool as a plain fast/appdata subdir (no dataset). DATA_DIR is
  # pinned to /var/lib/karakeep, so bind the subdir there. The bind is a mount
  # unit ordered after tmpfiles (which creates the subdir) — a fileSystems bind
  # would mount at local-fs, before tmpfiles, and bind an empty dir.
  systemd.tmpfiles.rules = [ "d /srv/fast/appdata/karakeep 0700 karakeep karakeep - -" ];
  systemd.mounts = [{
    what = "/srv/fast/appdata/karakeep";
    where = "/var/lib/karakeep";
    type = "none";
    options = "bind";
    requires = [ "systemd-tmpfiles-setup.service" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    wantedBy = [ "multi-user.target" ];
  }];
  # Backup rides modules/server/restic.nix's /srv/fast/appdata sweep — no per-app
  # restic path here.

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

1. **Place the secret** on polaris (§7), then **`make switch NIXNAME=polaris`** —
   the module auto-creates + binds the fast-pool data dir, and karakeep comes up
   **empty** at the new URL over TLS; `karakeep-init` generates `settings.env` and
   an empty migrated DB. Proves config/TLS/bind mount before real data moves.
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

## 7. Manual steps (runbook — `docs/polaris/karakeep-migration-runbook.md`)

Storage needs no provisioning (§4.2 — the module auto-creates the subdir). The one
hand-placed item is the OpenAI key:

```bash
# OpenAI key (pulled from the k8s secret; never enters the repo):
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

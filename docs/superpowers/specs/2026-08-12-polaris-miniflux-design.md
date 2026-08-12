# Miniflux on polaris — Design (RSS reader; migrate off Kubernetes)

**Status:** Draft for review
**Date:** 2026-08-12
**Host:** `polaris`

## 1. Purpose & scope

Move **Miniflux** (self-hosted RSS reader) off the Hetzner Kubernetes cluster
and onto polaris, served at **`https://miniflux.polaris.mattiasgees.be`**, as the
**second tenant of the shared PostgreSQL** (Immich was the first). Existing feeds,
entries, and user accounts are migrated by dumping the k8s Postgres and restoring
into the polaris pg18 cluster.

**Scope:** the `services.miniflux` NixOS module, its DB wiring, the Caddy vhost,
the hand-placed admin secret (commands documented for the user to run), and the
one-shot data migration. **Out of scope** (each its own follow-up): deleting the
k8s manifests (`config/bases/miniflux` + the hetzner kustomization) — done later
once polaris is verified; and moving the secret to **sops-nix** — a separate
investigation.

## 2. Current state (source, k8s)

- Deployment `miniflux` (image `miniflux/miniflux:2.3.3`), 1 replica, healthy.
- CNPG cluster `miniflux-postgresql`, **PostgreSQL 17.5**, DB `miniflux` **~55 MB**.
- Two admin users in the `users` table: `miniflux` (id 1, the `CREATE_ADMIN`
  bootstrap) and `mattias` (id 2, real account). Both carry over with their
  existing password hashes — login on polaris uses current credentials.
- Admin bootstrap password lives in k8s secret `miniflux-secrets` key
  `minifluxPassword` (sourced from AWS Secrets Manager via the CSI provider).
- No `BASE_URL` is set on k8s (miniflux default). Feed URLs are external and
  unaffected by the move.

## 3. Decisions (locked)

- **Database:** `services.miniflux` with `createDatabaseLocally = true` (default).
  The module adds the `miniflux` role + DB to the **existing** shared pg18 cluster
  via `services.postgresql.ensure{Databases,Users}` and connects over the unix
  socket (`/run/postgresql`, peer auth, no password) — the same tenant pattern as
  Immich. **No change to `modules/server/postgresql.nix`.**
- **Ingress:** Caddy `miniflux.polaris.mattiasgees.be → localhost:8080`
  (miniflux `LISTEN_ADDR = localhost:8080`). No firewall change (Caddy already
  opens 80/443); no new DNS record (the `*.polaris.mattiasgees.be` wildcard already
  resolves). Remote access is Tailscale, same model as the *arr stack + Immich.
- **`BASE_URL = https://miniflux.polaris.mattiasgees.be`** — set explicitly so
  generated links / PWA use the new host.
- **Admin secret:** hand-placed `/etc/miniflux/admin.env` (0600, out of git),
  containing `ADMIN_USERNAME` + `ADMIN_PASSWORD`, reusing the existing `miniflux`
  password from the k8s secret. **The user places this file** using the documented
  commands in §7 — it never passes through the assistant. After the data restore
  the `miniflux` user already exists, so `CREATE_ADMIN` is a harmless no-op; the
  file is the module's requirement and a working break-glass admin.
- **Migration:** a single **committed script the user runs from their
  workstation** (which has both the kubectl context and SSH to polaris): scale k8s
  to 0 → `pg_dump` the k8s DB → stream over SSH → restore into a freshly-recreated
  `miniflux` DB on polaris → start miniflux (runs forward migrations) → print a
  verification summary. k8s deployment is left at **replicas = 0** as the rollback
  net. The assistant does **not** execute it.

## 4. Version safety

Miniflux records a `schema_version` and **refuses to start if the binary is older
than the schema** it finds. Source schema is miniflux 2.3.3. Polaris runs NixOS
26.11 (nixpkgs `0954f7e`, 2026-07-29), which ships miniflux ≥ 2.3.x. **Before
cutover the implementer verifies the exact polaris miniflux version is ≥ 2.3.3**
(`nix eval .#nixosConfigurations.polaris.config.services.miniflux.package.version`
or `miniflux -version` on the host). If somehow older, pin the package to
`nixpkgs-unstable` via the existing overlay in `flake.nix`. Forward migrations run
automatically on first start; pg 17→18 is a non-issue for a logical dump.

## 5. NixOS changes (declarative)

Three files:

### `modules/media/miniflux.nix` (new)

Sits beside `immich.nix` — its sibling shared-Postgres + Caddy tenant. Header
comment documents the hand-placed secret (mirroring how `caddy.nix` documents
`route53.env`).

```nix
{ ... }:
{
  services.miniflux = {
    enable = true;                          # createDatabaseLocally defaults true
    adminCredentialsFile = "/etc/miniflux/admin.env";
    config = {
      LISTEN_ADDR = "localhost:8080";
      BASE_URL = "https://miniflux.polaris.mattiasgees.be";
    };
  };
}
```

### `modules/media/caddy.nix` (edit)

Add one vhost alongside the existing ones:

```nix
virtualHosts."miniflux.polaris.mattiasgees.be".extraConfig = proxy 8080;
```

### `machines/polaris.nix` (edit)

Add `../modules/media/miniflux.nix` to `imports`.

## 6. Data migration

Ordering (manual steps the user does around the script):

1. **Place secret** — `/etc/miniflux/admin.env` on polaris (§7 commands).
2. **Deploy** — `make switch NIXNAME=polaris` on polaris → miniflux starts
   **empty** at the new URL. Proves config + TLS + DB wiring before prod data moves.
3. **Run the migration script** (below) from the workstation.
4. **Verify** — script prints source-vs-polaris row counts; then log in at
   `https://miniflux.polaris.mattiasgees.be` as `mattias` and trigger a feed
   refresh to confirm it succeeds.

### The script — `migrate-miniflux.sh` (new, committed at repo root)

Run from the workstation (needs the hetzner kubectl context + SSH to polaris).
Parameterised at the top (`POLARIS_HOST=mattias@192.168.1.50`, namespace, DB pod,
`SUDO=/run/wrappers/bin/sudo`). `set -euo pipefail`; each destructive step is
announced and the sudo/restore step asks for confirmation before running.

**Sudo constraint (drives the two-step shape):** polaris requires a password for
sudo, and only `/run/wrappers/bin/sudo` is setuid (a non-interactive SSH shell
resolves the wrong, non-setuid `sudo`). So the dump transfer (no sudo) and the
restore (needs sudo, hence a TTY for the password prompt) **must be separate SSH
calls** — you can't prompt for a password while stdin is the dump stream.

Flow:

1. **Pre-flight:** confirm `kubectl` reaches the miniflux namespace, the CNPG pod
   is running, and `ssh $POLARIS_HOST systemctl is-enabled miniflux` succeeds
   (i.e. the deploy in step 2 happened). Abort otherwise.
2. **Count source** — `SELECT count(*)` on `feeds`/`entries`/`users` via
   `kubectl exec` (the CNPG DB pod stays up; only the app deployment is scaled).
3. **Freeze source** — `kubectl scale deploy/miniflux -n miniflux --replicas=0`
   and wait for the pod to terminate.
4. **Transfer dump (no sudo)** — stream custom-format dump to a temp file on
   polaris:
   ```bash
   kubectl exec -n miniflux miniflux-postgresql-1 -c postgres -- \
     pg_dump -U postgres -Fc miniflux \
   | ssh "$POLARIS_HOST" 'cat > /tmp/miniflux.dump'
   ```
5. **Restore + verify (interactive, one password prompt)** — a single `ssh -t`
   session using the wrapper sudo, so the timestamp is cached across the calls:
   ```bash
   ssh -t "$POLARIS_HOST" "
     $SUDO systemctl stop miniflux &&
     $SUDO -u postgres dropdb --if-exists miniflux &&
     $SUDO -u postgres createdb -O miniflux miniflux &&
     $SUDO -u postgres pg_restore --no-owner --role=miniflux -d miniflux /tmp/miniflux.dump &&
     $SUDO systemctl start miniflux &&
     $SUDO -u postgres psql -d miniflux -c 'SELECT
       (SELECT count(*) FROM feeds)   AS feeds,
       (SELECT count(*) FROM entries) AS entries,
       (SELECT count(*) FROM users)   AS users;'
   "
   ```
6. **Report** — print the source counts (step 2) next to the polaris counts
   (step 5) and a PASS/FAIL on equality; remove `/tmp/miniflux.dump`.

Rollback (documented in the script header): `kubectl scale deploy/miniflux
-n miniflux --replicas=1` restores the old instance — its DB is untouched.

## 7. User-run secret placement (documented commands)

Run these **on polaris** before the deploy (step 1 of §6, ahead of `make switch`).
The password is pulled from
the k8s secret with the local `kubectl` context, so it never appears in the repo:

```bash
# From a machine with kubectl access to the hetzner cluster:
PW=$(kubectl get secret miniflux-secrets -n miniflux \
      -o jsonpath='{.data.minifluxPassword}' | base64 -d)

# On polaris (or piped there over SSH), write the 0600 env file:
sudo install -d -m 0755 /etc/miniflux
printf 'ADMIN_USERNAME=miniflux\nADMIN_PASSWORD=%s\n' "$PW" \
  | sudo install -m 0600 /dev/stdin /etc/miniflux/admin.env
```

## 8. Follow-ups (not this change)

- Remove k8s manifests (`config/bases/miniflux`, `config/flavours/hetzner/miniflux.yaml`,
  its kustomization entry) once polaris is confirmed good, then delete the CNPG
  cluster / AWS secret.
- Investigate **sops-nix** to bring `/etc/miniflux/admin.env` (and caddy's
  `route53.env`) into encrypted git.
- Backups: the `miniflux` DB is already captured by the cluster-wide nightly
  `pg_dumpall` in `postgresql.nix` (restic-swept offsite) — **no per-app backup
  work needed**, unlike the k8s CNPG→S3 setup being retired.

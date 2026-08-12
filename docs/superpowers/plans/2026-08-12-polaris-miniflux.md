# Miniflux on polaris (migrate off k8s) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Miniflux on polaris at `https://miniflux.polaris.mattiasgees.be` as the second shared-Postgres tenant, and migrate all data (feeds/entries/users) from the Hetzner Kubernetes cluster.

**Architecture:** A new NixOS module (`services.miniflux`, `createDatabaseLocally = true`) adds a `miniflux` role/DB to the existing pg18 cluster over the unix socket (peer auth) — same tenant pattern as Immich. Caddy fronts it with Route53 DNS-01 TLS. Data moves via a committed `migrate-miniflux.sh` run from the workstation: scale k8s to 0, `pg_dump` → SSH stream to polaris → `pg_restore` into a recreated DB.

**Tech Stack:** NixOS (`services.miniflux`), Caddy, PostgreSQL 18, `pg_dump`/`pg_restore`, kubectl, bash.

## Global Constraints

- **Design doc:** `docs/superpowers/specs/2026-08-12-polaris-miniflux-design.md` (authoritative).
- **Miniflux version:** polaris nixpkgs ships **2.3.3**, identical to the k8s source (image `miniflux/miniflux:2.3.3`). Schema versions match → migration is a no-op. If a future nixpkgs bump ever drops this below 2.3.3, pin via the unstable overlay in `flake.nix`.
- **No changes to `modules/server/postgresql.nix`** — the miniflux module registers its own role/DB via `ensure*`.
- **No new DNS record** (`*.polaris.mattiasgees.be` wildcard already resolves) and **no firewall change** (Caddy already opens 80/443).
- **Secret is out of git**, hand-placed at `/etc/miniflux/admin.env` (0600), same pattern as caddy's `route53.env`.
- **Branch:** work on feature branch `feat/polaris-miniflux`; PR targets `mattias`.
- **Verification model:** this repo has no test suite — verification is a successful `nix eval`/build. Config builds happen **on polaris** (`/home/mattias/git/nixos-config`, x86_64-linux); the Mac workstation has no working `nix`.
- **polaris facts:** host `mattias@192.168.1.50`; sudo **requires a password** and only `/run/wrappers/bin/sudo` is setuid; CNPG source pod `miniflux-postgresql-1` (container `postgres`), namespace `miniflux`, deployment `miniflux` (pod label `app=miniflux`).

---

## File Structure

- **Create** `modules/media/miniflux.nix` — the miniflux service + DB wiring; header documents the hand-placed secret. Sits beside `immich.nix` (its sibling shared-Postgres + Caddy tenant).
- **Modify** `modules/media/caddy.nix` — add one `virtualHosts` line.
- **Modify** `machines/polaris.nix` — add the module to `imports`.
- **Create** `migrate-miniflux.sh` (repo root, executable) — the one-shot data migration, run from the workstation.

---

## Task 1: NixOS config — miniflux module, Caddy vhost, host import

**Files:**
- Create: `modules/media/miniflux.nix`
- Modify: `modules/media/caddy.nix` (add vhost after the immich line, ~`:51`)
- Modify: `machines/polaris.nix` (add import after the immich line, ~`:19`)

**Interfaces:**
- Consumes: `modules/server/postgresql.nix` (shared pg18, socket + peer auth — already imported by `machines/polaris.nix`); `modules/media/caddy.nix`'s `proxy` helper (`proxy = port: "reverse_proxy localhost:${port} …"`).
- Produces: miniflux listening on `localhost:8080`; Caddy vhost `miniflux.polaris.mattiasgees.be`; a `miniflux` Postgres role/DB created on first activation.

- [ ] **Step 1: Create the module `modules/media/miniflux.nix`**

```nix
# Miniflux (self-hosted RSS reader) — second tenant of the shared PostgreSQL
# from modules/server/postgresql.nix, migrated off the Hetzner k8s cluster.
#
# `createDatabaseLocally = true` (default) makes the module add the `miniflux`
# role + DB to the existing pg18 cluster via services.postgresql.ensure*, and
# connect over the unix socket (/run/postgresql, peer auth, no password) — the
# same tenant pattern as immich.nix. Nothing is added to postgresql.nix.
#
# Ingress is Caddy only (miniflux.polaris.mattiasgees.be -> localhost:8080, wired
# in caddy.nix); LISTEN_ADDR stays on localhost and no firewall port is opened.
#
# Secret: `adminCredentialsFile` is an EnvironmentFile with ADMIN_USERNAME and
# ADMIN_PASSWORD, hand-placed at /etc/miniflux/admin.env (0600, out of git) —
# same out-of-band pattern as caddy's route53.env. After the data migration the
# `miniflux` admin already exists in the restored DB, so CREATE_ADMIN is a no-op;
# the file is the module's requirement and a break-glass admin. Place it with:
#
#   PW=$(kubectl get secret miniflux-secrets -n miniflux \
#         -o jsonpath='{.data.minifluxPassword}' | base64 -d)
#   sudo install -d -m 0755 /etc/miniflux
#   printf 'ADMIN_USERNAME=miniflux\nADMIN_PASSWORD=%s\n' "$PW" \
#     | sudo install -m 0600 /dev/stdin /etc/miniflux/admin.env
#
# (Moving this secret into sops-nix is a queued follow-up.)
{ ... }:
{
  services.miniflux = {
    enable = true;
    adminCredentialsFile = "/etc/miniflux/admin.env";
    config = {
      LISTEN_ADDR = "localhost:8080";
      BASE_URL = "https://miniflux.polaris.mattiasgees.be";
    };
  };
}
```

- [ ] **Step 2: Add the Caddy vhost**

In `modules/media/caddy.nix`, add after the `immich` line (currently `:51`):

```nix
    virtualHosts."miniflux.polaris.mattiasgees.be".extraConfig = proxy 8080;
```

- [ ] **Step 3: Import the module on polaris**

In `machines/polaris.nix`, add to `imports` after `../modules/media/immich.nix`:

```nix
    ../modules/media/miniflux.nix
```

- [ ] **Step 4: Push the branch and evaluate on polaris**

The Mac has no `nix`; eval runs on polaris against its checkout.

```bash
# workstation
git add modules/media/miniflux.nix modules/media/caddy.nix machines/polaris.nix
git commit -m "feat(miniflux): run miniflux on polaris as shared-postgres tenant"
git push -u origin feat/polaris-miniflux

# polaris
ssh mattias@192.168.1.50 'bash -lc "
  cd /home/mattias/git/nixos-config &&
  git fetch origin && git checkout feat/polaris-miniflux && git pull --ff-only &&
  export NIX_CONFIG=\"experimental-features = nix-command flakes\" &&
  echo -n \"miniflux version: \" &&
  nix eval --impure --raw .#nixosConfigurations.polaris.config.services.miniflux.package.version && echo &&
  echo \"evaluating toplevel…\" &&
  nix eval --impure --raw .#nixosConfigurations.polaris.config.system.build.toplevel.drvPath
"'
```

Expected: `miniflux version: 2.3.3`, then a `/nix/store/….drv` path printed (evaluation succeeds — imports resolve, options are valid, Caddy vhost accepted). A failure here means a config error to fix before deploying.

- [ ] **Step 5: Verify the Caddy vhost is wired**

```bash
ssh mattias@192.168.1.50 'bash -lc "
  cd /home/mattias/git/nixos-config &&
  export NIX_CONFIG=\"experimental-features = nix-command flakes\" &&
  nix eval --impure --raw .#nixosConfigurations.polaris.config.services.caddy.virtualHosts.\"miniflux.polaris.mattiasgees.be\".extraConfig
"'
```

Expected: output contains `reverse_proxy localhost:8080` and the `tls { dns route53 … }` block.

> Deploy (`make switch`) is deliberately deferred to Task 3, gated on the secret file existing.

---

## Task 2: `migrate-miniflux.sh` — one-shot data migration

**Files:**
- Create: `migrate-miniflux.sh` (repo root, `chmod +x`)

**Interfaces:**
- Consumes: workstation `kubectl` (hetzner context) + SSH to `mattias@192.168.1.50`; on polaris, miniflux already deployed (Task 3 step order enforces this at runtime via the pre-flight check).
- Produces: nothing other repo code depends on — it's an operational script. Leaves k8s deployment at `replicas=0`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
#
# migrate-miniflux.sh — one-shot migration of Miniflux data from the Hetzner
# Kubernetes cluster to polaris.
#
# Run from a workstation that has BOTH:
#   - the hetzner kubectl context active (`kubectl get pods -n miniflux` works)
#   - SSH access to polaris ($POLARIS_HOST)
#
# Prerequisites (must be done first — see design doc §6):
#   1. /etc/miniflux/admin.env placed on polaris (design doc §7).
#   2. `make switch NIXNAME=polaris` deployed — miniflux is up (empty) on polaris.
#
# Flow: count source -> scale k8s to 0 -> pg_dump (custom fmt) streamed to
#       /tmp/miniflux.dump on polaris -> stop/drop/create/restore/start ->
#       re-count -> PASS/FAIL on row-count equality.
#
# Rollback: kubectl scale deploy/miniflux -n miniflux --replicas=1
#   (this script never modifies the k8s database).
#
# sudo note: polaris requires a password for sudo, and only
# /run/wrappers/bin/sudo is setuid. The restore runs in one `ssh -t` session so
# the password is typed once (timestamp cached across the sudo calls).

set -euo pipefail

POLARIS_HOST="${POLARIS_HOST:-mattias@192.168.1.50}"
NS="${NS:-miniflux}"
PG_POD="${PG_POD:-miniflux-postgresql-1}"
DEPLOY="${DEPLOY:-miniflux}"
DUMP_REMOTE="${DUMP_REMOTE:-/tmp/miniflux.dump}"
SUDO="/run/wrappers/bin/sudo"

COUNTS_SQL="SELECT (SELECT count(*) FROM feeds) AS feeds, (SELECT count(*) FROM entries) AS entries, (SELECT count(*) FROM users) AS users;"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- 1. Pre-flight -----------------------------------------------------------
say "Pre-flight checks"
kubectl get ns "$NS" >/dev/null 2>&1 || die "kubectl cannot see namespace '$NS' (wrong context?)"
kubectl get pod "$PG_POD" -n "$NS" >/dev/null 2>&1 || die "CNPG pod '$PG_POD' not found in '$NS'"
ssh "$POLARIS_HOST" 'systemctl is-enabled miniflux' >/dev/null 2>&1 \
  || die "miniflux not enabled on $POLARIS_HOST — deploy 'make switch NIXNAME=polaris' first"

# --- 2. Count source ---------------------------------------------------------
say "Counting rows on the k8s source"
src_counts=$(kubectl exec -n "$NS" "$PG_POD" -c postgres -- \
  psql -U postgres -d miniflux -At -F'|' -c "$COUNTS_SQL")
echo "source feeds|entries|users = $src_counts"

# --- 3. Freeze source --------------------------------------------------------
say "Scaling k8s deployment '$DEPLOY' to 0"
kubectl scale deploy/"$DEPLOY" -n "$NS" --replicas=0
kubectl wait --for=delete pod -l app="$DEPLOY" -n "$NS" --timeout=120s || true

# --- 4. Transfer dump (no sudo) ---------------------------------------------
say "Dumping k8s DB -> $POLARIS_HOST:$DUMP_REMOTE"
kubectl exec -n "$NS" "$PG_POD" -c postgres -- \
  pg_dump -U postgres -Fc miniflux \
  | ssh "$POLARIS_HOST" "cat > '$DUMP_REMOTE'"
ssh "$POLARIS_HOST" "test -s '$DUMP_REMOTE'" || die "dump file is empty on polaris"

# --- 5. Restore + verify (interactive; one sudo password) --------------------
say "Restoring on polaris (you will be prompted for your sudo password)"
dst_counts=$(ssh -t "$POLARIS_HOST" "
  set -e
  $SUDO systemctl stop miniflux
  $SUDO -u postgres dropdb --if-exists --force miniflux
  $SUDO -u postgres createdb -O miniflux miniflux
  $SUDO -u postgres pg_restore --no-owner --role=miniflux -d miniflux '$DUMP_REMOTE'
  $SUDO systemctl start miniflux
  printf 'COUNTS:'
  $SUDO -u postgres psql -d miniflux -At -F'|' -c \"$COUNTS_SQL\"
" | tr -d '\r' | sed -n 's/^COUNTS://p')
echo "polaris feeds|entries|users = $dst_counts"

# --- 6. Cleanup + report -----------------------------------------------------
ssh "$POLARIS_HOST" "rm -f '$DUMP_REMOTE'" || true

say "Result"
echo "  source : $src_counts"
echo "  polaris: $dst_counts"
if [[ -n "$dst_counts" && "$src_counts" == "$dst_counts" ]]; then
  printf '\033[1;32mPASS — row counts match.\033[0m\n'
  echo "Log in at https://miniflux.polaris.mattiasgees.be as 'mattias' and trigger a feed refresh."
  echo "Leave k8s at replicas=0 as the rollback net."
else
  printf '\033[1;31mFAIL — counts differ or empty. Investigate before decommissioning k8s.\033[0m\n'
  echo "Rollback: kubectl scale deploy/$DEPLOY -n $NS --replicas=1"
  exit 1
fi
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x migrate-miniflux.sh
```

- [ ] **Step 3: Syntax + lint check**

```bash
bash -n migrate-miniflux.sh && echo "syntax OK"
shellcheck migrate-miniflux.sh || echo "(shellcheck not installed — bash -n suffices)"
```

Expected: `syntax OK`. If `shellcheck` is present, no errors (warnings about `ssh -t` word-splitting inside the double-quoted remote command are acceptable — the remote string is intentionally expanded locally for `$SUDO`, `$DUMP_REMOTE`, `$COUNTS_SQL`).

- [ ] **Step 4: Commit**

```bash
git add migrate-miniflux.sh
git commit -m "feat(miniflux): add k8s->polaris data migration script"
```

---

## Task 3: Cutover runbook (operational — executor runs, no repo change)

This task has no code; it executes the migration in the correct order. Do it only after Tasks 1–2 are merged/pulled onto polaris. **Nothing here is committed.**

**Interfaces:**
- Consumes: Task 1 config (deployed), Task 2 script, workstation kubectl + SSH.
- Produces: miniflux serving migrated data at the new URL; k8s at `replicas=0`.

- [ ] **Step 1: Place the admin secret on polaris**

Run from the workstation (kubectl context = hetzner). Password is pulled from the k8s secret, never typed by hand:

```bash
PW=$(kubectl get secret miniflux-secrets -n miniflux \
      -o jsonpath='{.data.minifluxPassword}' | base64 -d)
ssh mattias@192.168.1.50 "bash -lc '
  sudo install -d -m 0755 /etc/miniflux &&
  printf \"ADMIN_USERNAME=miniflux\nADMIN_PASSWORD=%s\n\" \"$PW\" \
    | sudo install -m 0600 /dev/stdin /etc/miniflux/admin.env &&
  sudo test -s /etc/miniflux/admin.env && echo secret-placed'"
```

Expected: `secret-placed`. (You'll be prompted for the sudo password.)

- [ ] **Step 2: Deploy the config on polaris**

```bash
ssh mattias@192.168.1.50 'bash -lc "
  cd /home/mattias/git/nixos-config &&
  git checkout feat/polaris-miniflux && git pull --ff-only &&
  make switch NIXNAME=polaris
"'
```

Expected: build completes and switches. `systemctl status miniflux` is active; `journalctl -u miniflux` shows it created the `miniflux` DB, ran migrations, and is listening on `localhost:8080`.

- [ ] **Step 3: Confirm the empty instance answers over TLS**

```bash
ssh mattias@192.168.1.50 'curl -sS -o /dev/null -w "%{http_code}\n" https://miniflux.polaris.mattiasgees.be/healthcheck'
```

Expected: `200` (Caddy issued the cert and proxied; miniflux `/healthcheck` returns OK on the empty DB).

- [ ] **Step 4: Run the migration**

```bash
./migrate-miniflux.sh
```

Expected: ends with `PASS — row counts match.` and prints matching `feeds|entries|users` for source and polaris.

- [ ] **Step 5: Functional verification**

Log in at `https://miniflux.polaris.mattiasgees.be` as `mattias` with your existing password. Confirm feeds/categories are present, open an entry, and click "Refresh all feeds" — confirm it fetches without error. Leave the k8s deployment at `replicas=0` (rollback net).

- [ ] **Step 6: Open the PR**

```bash
gh pr create --base mattias --head feat/polaris-miniflux \
  --title "Run miniflux on polaris (migrate off k8s)" \
  --body "Adds services.miniflux as the second shared-postgres tenant on polaris, a Caddy vhost for miniflux.polaris.mattiasgees.be, and migrate-miniflux.sh. Data migrated from the Hetzner cluster (row counts verified equal). k8s left at replicas=0 as rollback. Removing the k8s manifests is a queued follow-up. See docs/superpowers/specs/2026-08-12-polaris-miniflux-design.md."
```

---

## Self-Review

**Spec coverage:**
- §3 shared-Postgres tenant → Task 1 module (`createDatabaseLocally`). ✓
- §3 Caddy ingress → Task 1 vhost. ✓
- §3 BASE_URL → Task 1 `config`. ✓
- §3/§7 hand-placed secret → Task 1 header docs + Task 3 step 1. ✓
- §4 version safety → Global Constraints + Task 1 step 4 (verified 2.3.3). ✓
- §5 three file changes → Task 1. ✓
- §6 migration script (two-step for sudo) → Task 2. ✓
- §6 ordering (secret → deploy → script → verify) → Task 3. ✓
- §8 follow-ups (manifest removal, sops-nix) → out of scope, noted in PR body + module header. ✓

**Placeholder scan:** none — every step has concrete commands/code and expected output.

**Type/name consistency:** `POLARIS_HOST`, `NS`, `PG_POD`, `DEPLOY`, `DUMP_REMOTE`, `SUDO`, `COUNTS_SQL` used consistently across Task 2; `feat/polaris-miniflux` branch and `/etc/miniflux/admin.env` path consistent across Tasks 1/3; miniflux `localhost:8080` matches the Caddy `proxy 8080`.

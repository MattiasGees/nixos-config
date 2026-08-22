# Polaris 1Password Secrets — Operator Manual

Migrate Polaris secrets to 1Password (`op inject` at deploy), rolled out in **two
stacked PRs** so you can verify the rendered secrets against the live ones
*before* any service depends on them:

- **PR A — engine + render** (`polaris/op-secrets-engine`): installs the
  op-secrets engine and renders every secret into `/var/lib/secrets/`, but **no
  service consumes them yet** (apps still read the old `/etc/*` files). Deploying
  this is risk-free.
- **PR B — flip consumers** (`polaris/op-secrets-consumers`, stacked on A):
  repoints each service at its rendered file and removes the old `/etc/*` files.

The safety win: after PR A you `diff` each rendered file against the live one. If
they match byte-for-byte, PR B's flip is guaranteed safe. This catches a wrong
value (e.g. a mistyped region or credential) on the host, before it can break TLS
issuance or backups silently.

- **Host:** `ssh mattias@192.168.1.50` — repo at `/home/mattias/git/nixos-config`
- **sudo:** needs your password via `/run/wrappers/bin/sudo`
- **Golden rule:** never delete an old `/etc/*` secret file until that service's
  functional check passes on the rendered file. The old file is your rollback.

---

## Phase 0 — One-time bootstrap (before deploying PR A)

### 0.1 Capture the current secret values

Copy today's live values into 1Password so nothing changes functionally. On
polaris, dump the current files:

```bash
sudo cat /etc/miniflux/admin.env      # ADMIN_USERNAME, ADMIN_PASSWORD
sudo cat /etc/caddy/route53.env       # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
sudo cat /etc/restic/polaris.pass     # the restic repo password (single value)
sudo cat /etc/restic/hetzner.env      # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
```

### 0.2 Create the 1Password vault + items

Create a vault named **`polaris`** with these items/fields (field names must
match **exactly** — the templates reference them):

| Item | Fields | Source |
|---|---|---|
| `miniflux` | `username`, `password` | `/etc/miniflux/admin.env` |
| `caddy-route53` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `/etc/caddy/route53.env` |
| `restic` | `repo-password` | `/etc/restic/polaris.pass` |
| `restic-backend` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `/etc/restic/hetzner.env` |

> Regions are **not** secret and are **not** stored in 1Password — they're
> literals in the templates: caddy uses `AWS_DEFAULT_REGION=us-east-1` (AWS
> Route53 is global; us-east-1 is the conventional value), restic uses
> `AWS_DEFAULT_REGION=nbg1` (Hetzner object storage).

### 0.3 Create a service account and place its token

1. Create a 1Password **service account** with **read** access to **only** the
   `polaris` vault. Copy its token (starts with `ops_`).
2. On polaris, place the token — the single bootstrap secret:

```bash
sudo install -d -m 0700 /etc/op
printf '%s' 'ops_PASTE_YOUR_TOKEN' | sudo install -m 0600 /dev/stdin /etc/op/token
```

### 0.4 Verify the token reads **every** reference

The 1Password CLI is unfree, so an ad-hoc `nix run` needs
`NIXPKGS_ALLOW_UNFREE=1` **and** `--impure` (so `nix run` reads that env var);
without them every line fails with an "unfree license" error before any lookup
happens.

```bash
sudo sh -c 'export OP_SERVICE_ACCOUNT_TOKEN="$(cat /etc/op/token)"; \
  export NIXPKGS_ALLOW_UNFREE=1; \
  for r in \
    op://polaris/miniflux/username \
    op://polaris/miniflux/password \
    op://polaris/caddy-route53/AWS_ACCESS_KEY_ID \
    op://polaris/caddy-route53/AWS_SECRET_ACCESS_KEY \
    op://polaris/restic/repo-password \
    op://polaris/restic-backend/AWS_ACCESS_KEY_ID \
    op://polaris/restic-backend/AWS_SECRET_ACCESS_KEY; do \
    printf "%s -> " "$r"; \
    nix run --impure nixpkgs#_1password-cli -- read "$r" >/dev/null && echo OK || echo FAIL; \
  done'
```

Expected: **all seven print `OK`**. Any `FAIL` is a vault/item/field-name
mismatch or a scope problem — fix before deploying.

---

## Phase 1 — Deploy PR A (engine + render), then diff against live

Merge/checkout `polaris/op-secrets-engine`, then on polaris:

```bash
cd /home/mattias/git/nixos-config
git pull
make switch NIXNAME=polaris
ls -ld /var/lib/secrets                       # drwx------ root root
sudo journalctl -b | grep op-secrets          # 4 "rendered ..." lines, no WARNING
sudo ls -l /var/lib/secrets/                  # 4 files
```

Expected: four `rendered` lines (miniflux-admin, caddy-route53, restic-repo,
restic-backend), no `WARNING`. **No service is touched** — every app still reads
its `/etc/*` file, so this deploy cannot break anything.

**The checkpoint — diff each rendered file against the live one.** They must
match (the restic repo password has no `KEY=`, so compare its raw content):

```bash
sudo diff /var/lib/secrets/caddy-route53.env  /etc/caddy/route53.env   && echo "caddy OK"
sudo diff /var/lib/secrets/miniflux-admin.env /etc/miniflux/admin.env  && echo "miniflux OK"
sudo diff /var/lib/secrets/restic-backend.env /etc/restic/hetzner.env  && echo "restic-backend OK"
sudo diff /var/lib/secrets/restic-repo.pass   /etc/restic/polaris.pass && echo "restic-repo OK"
```

Notes:
- `caddy-route53.env` will differ **only** if your live file used
  `AWS_REGION=` while the template emits `AWS_DEFAULT_REGION=` (both are honored
  by the AWS SDK, same value `us-east-1`) — confirm the credential values match
  and the region value is `us-east-1`.
- Any *other* difference means a value in 1Password doesn't match what's live —
  fix the 1Password field and re-run `make switch` until the diffs are clean.
- Do **not** proceed to Phase 2 until every diff is clean.

---

## Phase 2 — Deploy PR B (flip consumers), verify, remove old files

Merge/checkout `polaris/op-secrets-consumers` (stacked on A), then:

```bash
cd /home/mattias/git/nixos-config
git pull
make switch NIXNAME=polaris
```

Now each service reads its `/var/lib/secrets/*` file. Verify per service, and
**only then** remove the old `/etc` file (your rollback until this point):

**miniflux**
```bash
systemctl status miniflux                          # active (running)
# log in at https://miniflux.polaris.mattiasgees.be with the migrated admin creds
sudo rm /etc/miniflux/admin.env; sudo rmdir /etc/miniflux 2>/dev/null || true
```

**caddy**
```bash
systemctl status caddy                             # active (running)
curl -I https://miniflux.polaris.mattiasgees.be    # still serving TLS
sudo rm /etc/caddy/route53.env
```

**restic**
```bash
sudo systemctl start restic-backups-polaris.service
systemctl status restic-backups-polaris.service
sudo sh -c 'set -a; . /var/lib/secrets/restic-backend.env; \
  restic -r s3:https://nbg1.your-objectstorage.com/backups-polaris \
  --password-file /var/lib/secrets/restic-repo.pass snapshots' | tail   # lists snapshots
sudo rm /etc/restic/polaris.pass /etc/restic/hetzner.env
sudo rmdir /etc/restic 2>/dev/null || true
```

---

## Phase 3 — Outage-independence check

Prove a 1Password outage never breaks a deploy or boot — services fall back to
the last rendered files:

```bash
sudo mv /etc/op/token /etc/op/token.bak
cd /home/mattias/git/nixos-config
make switch NIXNAME=polaris
sudo journalctl -b | grep 'op-secrets: no token'   # skip message present
systemctl status miniflux caddy                     # still active
sudo ls -l /var/lib/secrets/                         # files intact, untouched
sudo mv /etc/op/token.bak /etc/op/token              # restore the token
```

Expected: switch succeeds, warning logged, nothing disrupted.

---

## After migration — routine rotation

1. Edit the value in 1Password (`polaris` vault).
2. `cd /home/mattias/git/nixos-config && make switch NIXNAME=polaris` — re-renders.
3. `sudo systemctl restart <service>` — an `EnvironmentFile`/`passwordFile`
   change does **not** auto-restart the consuming unit.

To rotate the **bootstrap token**: create a new service-account token in
1Password, re-place `/etc/op/token` (step 0.3), then `make switch`.

## Troubleshooting

- **`op-secrets: WARNING <name> render failed`** in `journalctl` → the template's
  `{{ op://... }}` reference doesn't match a 1P item/field, or the token can't
  read it. The old rendered file is kept. Fix the field/scope and `make switch`.
- **`op-secrets: no token` and a service won't start** → `/etc/op/token` is
  missing/unreadable and there's no last-good file yet (fresh host). Place the
  token (step 0.3) and `make switch`.
- **Debug a render without writing a file** (once op-secrets is deployed, the
  system `op` is on PATH — `op inject -i <template-path>`). Before that, via an
  ad-hoc unfree `nix run`:
  `sudo sh -c 'OP_SERVICE_ACCOUNT_TOKEN="$(cat /etc/op/token)" NIXPKGS_ALLOW_UNFREE=1 nix run --impure nixpkgs#_1password-cli -- inject -i <template-path>'`
  prints the rendered result to stdout.

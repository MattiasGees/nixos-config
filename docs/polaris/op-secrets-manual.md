# Polaris 1Password Secrets — Operator Manual

Your hands-on steps to migrate Polaris secrets to 1Password (`op inject` at
deploy). Claude drives the in-repo Nix changes and build gates via subagents;
**you** do everything in this manual — 1Password, the token, `make switch`, and
the functional checks. Steps are in execution order and flag each handoff.

- **Plan:** `docs/superpowers/plans/2026-08-17-polaris-op-secrets.md`
- **Design:** `docs/superpowers/specs/2026-08-17-polaris-op-secrets-design.md`
- **Host:** `ssh mattias@192.168.1.50` — repo at `/home/mattias/git/nixos-config`
- **sudo:** needs your password via `/run/wrappers/bin/sudo`
- **Golden rule:** never delete an old `/etc/*` secret file until that service's
  functional check passes on the rendered file. The old file is your rollback.

---

## Phase 0 — One-time bootstrap (do this first)

### 0.1 Capture the current secret values

You'll copy today's live values into 1Password so nothing changes functionally.
On polaris, dump the current files so you have the values to hand:

```bash
sudo cat /etc/miniflux/admin.env      # ADMIN_USERNAME, ADMIN_PASSWORD
sudo cat /etc/caddy/route53.env       # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
sudo cat /etc/restic/polaris.pass     # the restic repo password (single value)
sudo cat /etc/restic/hetzner.env      # AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
```

### 0.2 Create the 1Password vault + items

In 1Password, create a vault named **`polaris`** and these items/fields (field
names must match **exactly** — they are referenced by the templates):

| Item | Fields | Source |
|---|---|---|
| `miniflux` | `username`, `password` | `/etc/miniflux/admin.env` |
| `caddy-route53` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `/etc/caddy/route53.env` |
| `restic` | `repo-password` | `/etc/restic/polaris.pass` |
| `restic-backend` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `/etc/restic/hetzner.env` |

> The region (`nbg1`) is **not** secret and is **not** stored in 1Password — it
> stays as a literal in the templates.

### 0.3 Create a service account and place its token

1. In 1Password, create a **service account** with **read** access to **only**
   the `polaris` vault. Copy its token (starts with `ops_`).
2. On polaris, place the token — the single bootstrap secret:

```bash
sudo install -d -m 0700 /etc/op
printf '%s' 'ops_PASTE_YOUR_TOKEN' | sudo install -m 0600 /dev/stdin /etc/op/token
```

### 0.4 Verify the token reads the vault

```bash
sudo sh -c 'OP_SERVICE_ACCOUNT_TOKEN="$(cat /etc/op/token)" \
  nix run nixpkgs#_1password-cli -- read "op://polaris/miniflux/username"'
```

Expected: prints the miniflux admin username. If it errors, fix the vault/item/
field names or the service-account scope before continuing.

**→ Tell Claude "Phase 0 done."** Claude runs **Task 2** (adds the op-secrets
engine module) and reports back with a build result.

---

## Phase 1 — Deploy the engine (Task 2)

After Claude reports the engine module builds, deploy it. It declares **no**
secrets yet — this only proves the plumbing and the `/var/lib/secrets` dir.

```bash
cd /home/mattias/git/nixos-config
make switch NIXNAME=polaris
ls -ld /var/lib/secrets                       # expect: drwx------ root root
sudo journalctl -b | grep op-secrets          # token found (no renders yet)
```

Expected: switch succeeds, `/var/lib/secrets` exists `0700 root:root`, no errors.

**→ Tell Claude "engine deployed."** Claude runs **Task 3** (miniflux).

---

## Phase 2 — Miniflux (Task 3)

After Claude reports Task 3 builds:

```bash
cd /home/mattias/git/nixos-config
make switch NIXNAME=polaris
sudo ls -l /var/lib/secrets/miniflux-admin.env   # -rw------- miniflux miniflux
sudo journalctl -b | grep 'rendered miniflux-admin'
systemctl status miniflux                         # active (running)
```

Then log in at `https://miniflux.polaris.mattiasgees.be` with the migrated
admin credentials to confirm they work.

**Only after that passes**, remove the old file:

```bash
sudo rm /etc/miniflux/admin.env
sudo rmdir /etc/miniflux 2>/dev/null || true
```

**→ Tell Claude "miniflux verified."** Claude runs **Task 4** (caddy).

---

## Phase 3 — Caddy Route53 (Task 4)

After Claude reports Task 4 builds:

```bash
cd /home/mattias/git/nixos-config
make switch NIXNAME=polaris
sudo ls -l /var/lib/secrets/caddy-route53.env    # -rw------- caddy caddy
sudo journalctl -b | grep 'rendered caddy-route53'
systemctl status caddy                            # active (running)
curl -I https://miniflux.polaris.mattiasgees.be   # still serving TLS
```

**Only after that passes**, remove the old file:

```bash
sudo rm /etc/caddy/route53.env
```

**→ Tell Claude "caddy verified."** Claude runs **Task 5** (restic).

---

## Phase 4 — Restic (Task 5)

After Claude reports Task 5 builds:

```bash
cd /home/mattias/git/nixos-config
make switch NIXNAME=polaris
sudo ls -l /var/lib/secrets/restic-repo.pass /var/lib/secrets/restic-backend.env  # -rw------- root root
sudo journalctl -b | grep -E 'rendered restic-(repo|backend)'

# Functional check: restic authenticates with the rendered creds
sudo systemctl start restic-backups-polaris.service
systemctl status restic-backups-polaris.service
sudo sh -c 'set -a; . /var/lib/secrets/restic-backend.env; \
  restic -r s3:https://nbg1.your-objectstorage.com/backups-polaris \
  --password-file /var/lib/secrets/restic-repo.pass snapshots' | tail
```

Expected: `restic snapshots` lists existing snapshots.

**Only after that passes**, remove the old files:

```bash
sudo rm /etc/restic/polaris.pass /etc/restic/hetzner.env
sudo rmdir /etc/restic 2>/dev/null || true
```

**→ Tell Claude "restic verified."** Claude runs **Task 6** (outage check + runbook).

---

## Phase 5 — Outage-independence check (Task 6)

Prove that a 1Password outage never breaks a deploy or boot — services fall back
to the last rendered files:

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

**→ Tell Claude "outage check done."** Claude finalizes the rotation runbook.

---

## After migration — routine rotation

To rotate any secret from now on (no git, no ciphertext):

1. Edit the value in 1Password (`polaris` vault).
2. `cd /home/mattias/git/nixos-config && make switch NIXNAME=polaris` — re-renders.
3. `sudo systemctl restart <service>` — an `EnvironmentFile`/`passwordFile`
   change does **not** auto-restart the consuming unit.

To rotate the **bootstrap token**: create a new service-account token in
1Password, re-place `/etc/op/token` (step 0.3), then `make switch`.

## Troubleshooting

- **`op-secrets: WARNING <name> render failed`** in `journalctl` → the template's
  `{{ op://... }}` reference doesn't match a 1P item/field, or the token can't
  read it. The old rendered file is kept. Fix the field name or scope and
  `make switch` again.
- **`op-secrets: no token` and a service won't start** → `/etc/op/token` is
  missing/unreadable and there's no last-good file yet (fresh host). Place the
  token (step 0.3) and `make switch`.
- **A field mismatch you can debug by hand:**
  `sudo sh -c 'OP_SERVICE_ACCOUNT_TOKEN="$(cat /etc/op/token)" nix run nixpkgs#_1password-cli -- inject -i <template-path>'`
  prints the rendered result to stdout without writing a file.

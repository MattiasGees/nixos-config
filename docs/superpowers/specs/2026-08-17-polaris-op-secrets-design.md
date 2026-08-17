# Polaris secrets via 1Password (`op inject` at deploy) — Design

**Status:** Draft for review
**Date:** 2026-08-17
**Host:** `polaris`

## 1. Purpose & scope

Polaris secrets are currently **hand-placed** on the host as 0600 files outside
git (`/etc/restic/polaris.pass`, `/etc/restic/hetzner.env`,
`/etc/miniflux/admin.env`, `/etc/caddy/route53.env`). Each new service means
another manual scp-to-host step with no source of truth, and the count is
growing. `miniflux.nix` already carries a "move this to sops-nix" TODO.

This design makes **1Password the single source of truth** and renders secret
files onto Polaris at deploy time using the `op` CLI. It replaces N hand-placed
files with **one** bootstrap secret (a 1Password service-account token) and a
declarative, per-service secret registry.

Explicitly chosen over git-based tools (sops-nix / agenix): no ciphertext lives
in the repo at all, rotation happens in 1Password with no git commit, and there
are no age/host keys to manage.

**Scope:** a reusable `modules/server/op-secrets.nix` engine, per-service
`.env.tpl` templates + `opSecrets` declarations, repointing the four existing
file-based secrets, and the one-time bootstrap. **Out of scope:** recyclarr's
`SONARR_API_KEY` (only used on manual runs, not a persisted file) — can be added
later with the same pattern; any non-file secrets.

## 2. Decisions (locked)

- **Backend:** 1Password (already the user's source of truth). Not AWS Secrets
  Manager — same architecture but a heavier bootstrap and a second home for
  secrets the user isn't already using.
- **Fetch model:** **render at deploy** (`op inject` during `make switch`), not
  runtime pull. After a deploy the host is self-contained — a 1Password outage
  never affects boot.
- **1P storage shape:** field-per-value. Each value is its own 1Password field;
  a `.env.tpl` template committed to git carries the `{{ op://... }}` references
  and is rendered with `op inject`.
- **Trigger:** a NixOS `system.activationScripts` step, so rendering happens
  automatically as part of `nixos-rebuild switch`.
- **Output location:** a **persistent** directory `/var/lib/secrets` (root, 0700;
  files 0600), **not** tmpfs `/run` — so a reboot-without-deploy keeps the
  last-rendered secrets and never re-fetches.
- **Failure behavior:** atomic + last-good-preserving. Render to a temp file and
  only `mv` into place on success; on any failure (no token, 1P unreachable,
  timeout) warn and leave the existing file untouched. Rendering is wrapped in a
  short `timeout` so a network hang cannot stall activation/boot.

## 3. Bootstrap (single hand-placed secret)

A 1Password **service account** with a token scoped to a `polaris` vault. The
token is the only thing ever placed by hand again:

```bash
sudo install -d -m 0700 /etc/op
printf '%s' 'ops_...' | sudo install -m 0600 /dev/stdin /etc/op/token
```

If `/etc/op/token` is absent, the activation step skips all rendering (with a
warning) so a fresh install still boots.

## 4. The engine — `modules/server/op-secrets.nix`

Imported by `machines/polaris.nix` (added to its `imports`). Provides:

- **Option** `opSecrets` — `attrsOf` a submodule:
  - `template` (path) — the `.env.tpl` in git.
  - `path` (str) — output file, under `/var/lib/secrets`.
  - `owner` (str) — file owner (the consuming service's user).
  - `group` (str, default = `owner`).
  - `mode` (str, default `"0600"`).
- Adds `pkgs._1password-cli` to `environment.systemPackages`.
- `systemd.tmpfiles.rules` to create `/var/lib/secrets` `0700 root root`.
- `system.activationScripts.opSecrets` (runs after users exist). Pseudocode:

  ```sh
  test -r /etc/op/token || { echo "op-secrets: no token, skipping"; exit 0; }
  export OP_SERVICE_ACCOUNT_TOKEN="$(cat /etc/op/token)"
  for each opSecrets.<name>:
    tmp="$(mktemp)"
    if timeout 15 ${op}/bin/op inject -i <template> -o "$tmp"; then
      chown <owner>:<group> "$tmp"; chmod <mode> "$tmp"
      mv -f "$tmp" <path>
    else
      echo "op-secrets: <name> render failed, keeping last-good"; rm -f "$tmp"
    fi
  ```

  Notes: `op inject` never emits a partial file to `<path>` (temp + atomic
  `mv`); a failed field reference fails the whole file, preserving last-good.

## 5. Per-service wiring

Each secret gets a template (references only — safe in git) and an `opSecrets`
entry declared in the service's own module, then the consumer is repointed at the
rendered path. Example (miniflux):

`modules/media/miniflux.admin.env.tpl`
```
ADMIN_USERNAME={{ op://polaris/miniflux/username }}
ADMIN_PASSWORD={{ op://polaris/miniflux/password }}
```

`modules/media/miniflux.nix`
```nix
opSecrets.miniflux-admin = {
  template = ./miniflux.admin.env.tpl;
  path = "/var/lib/secrets/miniflux-admin.env";
  owner = "miniflux";
};
services.miniflux.adminCredentialsFile = "/var/lib/secrets/miniflux-admin.env";
```

## 6. Migration inventory

Migrated one at a time (create 1P item/fields → add template + `opSecrets` entry
→ repoint consumer → `make switch` → verify service → remove the old `/etc`
file). `owner`/service user in parentheses.

| Secret | Today (path) | Template | 1P references |
|---|---|---|---|
| restic repo password | `/etc/restic/polaris.pass` (root) | `restic.pass.tpl` | `op://polaris/restic/repo-password` |
| restic S3 backend env | `/etc/restic/hetzner.env` (root) | `restic.backend.env.tpl` | `op://polaris/restic-backend/{AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY}` |
| miniflux admin | `/etc/miniflux/admin.env` (miniflux) | `miniflux.admin.env.tpl` | `op://polaris/miniflux/{username,password}` |
| caddy Route53 | `/etc/caddy/route53.env` (caddy) | `caddy.route53.env.tpl` | `op://polaris/caddy-route53/{AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY,AWS_REGION}` |

Notes:
- The restic repo password is a single value; its template is one line with just
  the `{{ op://... }}` reference (no key=), matching `passwordFile` semantics.
- `restic.repository` is S3 (`s3:https://nbg1.your-objectstorage.com/...`), so
  the backend env holds the S3-compatible `AWS_*` keys restic reads. Confirm the
  exact key names against the current `/etc/restic/hetzner.env` before creating
  the 1P fields.
- Field names in the table are the intended 1P field names; create them to match
  the template references exactly.

## 7. Rotation & operations

- **Rotate:** edit the value in 1Password → `make switch NIXNAME=polaris`
  (re-renders) → restart the affected service (`systemctl restart <svc>`).
  No git commit, no ciphertext.
- **Add a secret:** create the 1P fields, add a `.tpl` + `opSecrets` entry in the
  service module, point the consumer at the path, deploy.
- **Disaster/first boot:** with no token, services fall back to whatever is in
  `/var/lib/secrets` (last-good). A truly fresh host needs the token placed and
  one `make switch` before secret-dependent services are healthy.

## 8. Risks & mitigations

- **Activation stall on network hang** → `timeout` around each `op inject`;
  failures are non-fatal.
- **`/var/lib/secrets` on disk** → same exposure as today's `/etc/*` files
  (0700 dir / 0600 files, root-owned dir), now sourced from 1P instead of manual
  scp. Not tmpfs by design (outage independence).
- **Token compromise** → single blast radius; scope the service account to the
  `polaris` vault only and rotate the token independently.
- **Field-name drift** → template reference and 1P field name must match exactly;
  a mismatch fails that file's render and keeps last-good (loud warning in the
  activation log).

## 9. Verification

No test suite — verification is a successful `make switch NIXNAME=polaris` plus:
- `/var/lib/secrets/*` files exist with correct owner/mode after switch.
- Each migrated service restarts cleanly reading the rendered file
  (`systemctl status` + a functional check: restic snapshot list, miniflux login,
  caddy cert issuance/serving).
- Simulate outage: temporarily move `/etc/op/token`, `make switch`, confirm the
  step warns and services keep running on last-good files.

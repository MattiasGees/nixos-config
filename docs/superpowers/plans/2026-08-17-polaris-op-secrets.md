# Polaris 1Password Secrets (op inject at deploy) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make 1Password the single source of truth for Polaris secrets, rendered to persistent files on the host at `make switch` time via `op inject`, replacing the hand-placed `/etc/*` secret files.

**Architecture:** A reusable `modules/server/op-secrets.nix` engine exposes an `opSecrets.<name>` option (template + output path + owner/mode). A `system.activationScripts.opSecrets` step runs during `nixos-rebuild switch`, reads a single service-account token from `/etc/op/token`, and renders each declared `.env.tpl` (which contains only `{{ op://... }}` references) into `/var/lib/secrets/` atomically and non-fatally (last-good preserved on any failure). Each service module declares its own secret inline and points its consumer at the rendered path.

**Tech Stack:** NixOS modules (Nix, `lib`), `pkgs._1password-cli` (`op`), 1Password service accounts, systemd activation scripts.

**Spec:** `docs/superpowers/specs/2026-08-17-polaris-op-secrets-design.md`

## Global Constraints

- **No secrets in git.** Only `op://` references (in `.env.tpl` files) and non-secret literals (e.g. `AWS_DEFAULT_REGION=nbg1`) may be committed. Never commit a rendered file or a real credential value.
- **Output path is persistent, not tmpfs:** all rendered files live under `/var/lib/secrets/` (dir `0700 root:root`; files `0600`, owned by the consuming service). Never write secrets to `/run`.
- **Rendering is atomic + last-good-preserving:** render to a temp file; only `mv` into place on success. On any failure (missing token, 1P unreachable, timeout, bad reference) warn and leave the existing file untouched. Wrap each `op inject` in `timeout 15` so activation/boot can never stall on the network.
- **Single bootstrap secret:** the 1Password service-account token at `/etc/op/token` (`0700` dir, `0600` file, root). If absent, the activation step skips all rendering with a warning so a fresh host still boots.
- **Build/verify runs on polaris.** The Mac has no nix. Build/eval over SSH to `mattias@192.168.1.50` (repo at `/home/mattias/git/nixos-config`). `make switch NIXNAME=polaris` needs an interactive sudo password (`/run/wrappers/bin/sudo`) and is run by the operator on the box. There is no test suite — verification is a clean `nix build` of the polaris toplevel plus a functional check per service.
- **1P field names must match the template references exactly.** A mismatch fails that one file's render and keeps last-good (loud warning in the activation log).

---

### Task 1: Bootstrap — 1Password vault, service account, token on host

Provisions the single root secret everything else derives from. No repo changes; this is an operational prerequisite for every later task.

**Files:**
- None in-repo. Host-side: create `/etc/op/token`.

**Interfaces:**
- Consumes: nothing.
- Produces: a 1Password vault named `polaris`; a service-account token readable at `/etc/op/token` on polaris via `OP_SERVICE_ACCOUNT_TOKEN`.

- [ ] **Step 1: Create the vault and items in 1Password**

In the 1Password app/CLI, create a vault named `polaris`. Create these items with these exact fields (values are the *current* live secrets — copy them from the existing `/etc/*` files on polaris so nothing changes functionally):

- Item `miniflux` — fields `username`, `password` (from `/etc/miniflux/admin.env` `ADMIN_USERNAME`/`ADMIN_PASSWORD`).
- Item `caddy-route53` — fields `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (from `/etc/caddy/route53.env`; the region is a non-secret literal, not stored here).
- Item `restic` — field `repo-password` (from `/etc/restic/polaris.pass`).
- Item `restic-backend` — fields `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (from `/etc/restic/hetzner.env`).

- [ ] **Step 2: Create a service account scoped to `polaris`**

Create a 1Password **service account** with **read** access to only the `polaris` vault. Copy its token (starts with `ops_`).

- [ ] **Step 3: Place the token on polaris**

On polaris (`ssh mattias@192.168.1.50`):

```bash
sudo install -d -m 0700 /etc/op
# Pipe the token in via stdin so it is never passed as a visible argument:
printf '%s' 'ops_REPLACE_WITH_TOKEN' | sudo install -m 0600 /dev/stdin /etc/op/token
```

- [ ] **Step 4: Verify the token can read the vault**

On polaris, confirm `op` (already present or run via `nix run nixpkgs#_1password-cli`) can read a field with the token:

```bash
sudo sh -c 'OP_SERVICE_ACCOUNT_TOKEN="$(cat /etc/op/token)" op read "op://polaris/miniflux/username"'
```

Expected: prints the miniflux admin username. If it errors, fix the vault/field names or the token scope before proceeding.

- [ ] **Step 5: No commit** (nothing in-repo changed).

---

### Task 2: The engine — `modules/server/op-secrets.nix`

The reusable option + activation renderer, imported by polaris with **zero** secrets declared yet. Independently testable: it must build and be a clean no-op (create the dir, render nothing) when no `opSecrets` are defined.

**Files:**
- Create: `modules/server/op-secrets.nix`
- Modify: `machines/polaris.nix` (add to `imports`)

**Interfaces:**
- Consumes: `pkgs._1password-cli`; token at `/etc/op/token`.
- Produces: the NixOS option
  `opSecrets.<name> = { template : path; path : str; owner : str; group : str = owner; mode : str = "0600"; }`
  and a `system.activationScripts.opSecrets` step that renders every declared entry into its `path`. Later tasks rely on setting `opSecrets.<name>` and reading `opSecrets.<name>.path`.

- [ ] **Step 1: Write the engine module**

Create `modules/server/op-secrets.nix`:

```nix
# op-secrets — render 1Password-backed secrets onto the host at deploy time.
#
# Each service declares `opSecrets.<name>` with a git-committed `.env.tpl`
# template (holding only `{{ op://vault/item/field }}` references) and an output
# path under /var/lib/secrets. A single service-account token at /etc/op/token
# unlocks 1Password; `op inject` renders each template during `nixos-rebuild
# switch`. Rendering is atomic (temp + mv) and last-good-preserving: any failure
# (no token, 1P unreachable, timeout, bad reference) warns and leaves the
# existing file untouched, so a deploy or boot never blocks on 1Password.
#
# Chosen over sops-nix/agenix: no ciphertext in git, rotate in 1Password with no
# commit, no age/host keys. See docs/superpowers/specs/2026-08-17-polaris-op-secrets-design.md
{ pkgs, lib, config, ... }:
let
  cfg = config.opSecrets;
  op = "${pkgs._1password-cli}/bin/op";
  secretsDir = "/var/lib/secrets";
  tokenFile = "/etc/op/token";

  renderOne = name: s: ''
    tmp="$(${pkgs.coreutils}/bin/mktemp)"
    if ${pkgs.coreutils}/bin/timeout 15 ${op} inject -i ${s.template} -o "$tmp"; then
      ${pkgs.coreutils}/bin/chown ${s.owner}:${s.group} "$tmp"
      ${pkgs.coreutils}/bin/chmod ${s.mode} "$tmp"
      ${pkgs.coreutils}/bin/mv -f "$tmp" ${lib.escapeShellArg s.path}
      echo "op-secrets: rendered ${name} -> ${s.path}"
    else
      echo "op-secrets: WARNING ${name} render failed; keeping last-good ${s.path}" >&2
      ${pkgs.coreutils}/bin/rm -f "$tmp"
    fi
  '';
in
{
  options.opSecrets = lib.mkOption {
    description = "1Password-backed secrets rendered to files at deploy time.";
    default = { };
    type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
      options = {
        template = lib.mkOption {
          type = lib.types.path;
          description = "Path to a .env.tpl containing only {{ op://... }} references.";
        };
        path = lib.mkOption {
          type = lib.types.str;
          description = "Absolute output path (must live under ${secretsDir}).";
        };
        owner = lib.mkOption {
          type = lib.types.str;
          description = "Owner of the rendered file (the consuming service's user).";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = config.owner;
          description = "Group of the rendered file (defaults to owner).";
        };
        mode = lib.mkOption {
          type = lib.types.str;
          default = "0600";
          description = "Mode of the rendered file.";
        };
      };
    }));
  };

  config = {
    environment.systemPackages = [ pkgs._1password-cli ];

    # Runs during nixos-rebuild switch (and boot activation). deps = [ "users" ]
    # so the file owners exist before chown (the "users" script creates users
    # and groups). The dir is created here (not via tmpfiles) to avoid
    # activation-ordering races on a fresh switch.
    system.activationScripts.opSecrets = {
      deps = [ "users" ];
      text = ''
        ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root ${secretsDir}
        if [ ! -r ${tokenFile} ]; then
          echo "op-secrets: no token at ${tokenFile}; skipping (services use last-good if present)" >&2
        else
          export OP_SERVICE_ACCOUNT_TOKEN="$(${pkgs.coreutils}/bin/cat ${tokenFile})"
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList renderOne cfg)}
        fi
      '';
    };
  };
}
```

- [ ] **Step 2: Import the engine in `machines/polaris.nix`**

Add `../modules/server/op-secrets.nix` to the `imports` list in `machines/polaris.nix` (alongside the other `../modules/server/*` imports).

- [ ] **Step 3: Build the polaris toplevel (compile gate)**

On polaris (`ssh mattias@192.168.1.50`, repo `/home/mattias/git/nixos-config`):

```bash
cd /home/mattias/git/nixos-config
NIX_CONFIG="experimental-features = nix-command flakes" \
  nix build --impure .#nixosConfigurations.polaris.config.system.build.toplevel
```

Expected: builds successfully. (With no `opSecrets` declared, `mapAttrsToList` over `{}` yields an empty renderer — a valid no-op activation step.)

- [ ] **Step 4: Switch and verify the no-op behavior (on polaris)**

Operator runs on polaris:

```bash
make switch NIXNAME=polaris
ls -ld /var/lib/secrets      # expect: drwx------ root root
sudo journalctl -b | grep op-secrets   # expect: token found or "skipping"; no renders yet
```

Expected: `/var/lib/secrets` exists `0700 root:root`; no secrets rendered (none declared); no activation errors.

- [ ] **Step 5: Commit**

```bash
git add modules/server/op-secrets.nix machines/polaris.nix
git commit -m "feat(polaris): op-secrets engine — render 1Password secrets at deploy"
```

---

### Task 3: Migrate miniflux admin secret

First real consumer — lowest risk (the admin creds are a break-glass file; the `miniflux` admin already exists in the DB, so `CREATE_ADMIN` is a no-op). Proves the engine end-to-end.

**Files:**
- Create: `modules/media/miniflux.admin.env.tpl`
- Modify: `modules/media/miniflux.nix`
- Host cleanup: remove `/etc/miniflux/admin.env` after verification.

**Interfaces:**
- Consumes: `opSecrets` option (Task 2); 1P item `miniflux` fields `username`, `password` (Task 1).
- Produces: rendered file `/var/lib/secrets/miniflux-admin.env` (owner `miniflux`, `0600`).

- [ ] **Step 1: Create the template**

Create `modules/media/miniflux.admin.env.tpl`:

```
ADMIN_USERNAME={{ op://polaris/miniflux/username }}
ADMIN_PASSWORD={{ op://polaris/miniflux/password }}
```

- [ ] **Step 2: Declare the secret and repoint the consumer**

In `modules/media/miniflux.nix`, add the `opSecrets` entry and change `adminCredentialsFile`. Replace the module body so it reads:

```nix
{ ... }:
{
  opSecrets.miniflux-admin = {
    template = ./miniflux.admin.env.tpl;
    path = "/var/lib/secrets/miniflux-admin.env";
    owner = "miniflux";
  };

  services.miniflux = {
    enable = true;
    adminCredentialsFile = "/var/lib/secrets/miniflux-admin.env";
    config = {
      LISTEN_ADDR = "localhost:8080";
      BASE_URL = "https://miniflux.polaris.mattiasgees.be";
    };
  };
}
```

Also update the secret comment block at the top of `miniflux.nix`: replace the "hand-placed at /etc/miniflux/admin.env … Moving this secret into sops-nix is a queued follow-up" paragraph with a one-line note that the file is rendered from `op://polaris/miniflux/*` by op-secrets.

- [ ] **Step 3: Build the polaris toplevel (compile gate)**

On polaris:

```bash
cd /home/mattias/git/nixos-config
NIX_CONFIG="experimental-features = nix-command flakes" \
  nix build --impure .#nixosConfigurations.polaris.config.system.build.toplevel
```

Expected: builds successfully.

- [ ] **Step 4: Switch and verify (on polaris)**

Operator runs on polaris:

```bash
make switch NIXNAME=polaris
sudo ls -l /var/lib/secrets/miniflux-admin.env    # -rw------- root root
sudo journalctl -b | grep 'op-secrets: rendered miniflux-admin'
systemctl status miniflux                          # active (running)
```

Then confirm login still works at `https://miniflux.polaris.mattiasgees.be` with the migrated admin credentials.

- [ ] **Step 5: Remove the stale hand-placed file**

On polaris, only after Step 4 passes:

```bash
sudo rm /etc/miniflux/admin.env
sudo rmdir /etc/miniflux 2>/dev/null || true
```

- [ ] **Step 6: Commit**

```bash
git add modules/media/miniflux.admin.env.tpl modules/media/miniflux.nix
git commit -m "feat(polaris): render miniflux admin secret from 1Password"
```

---

### Task 4: Migrate caddy Route53 secret

Route53 DNS-01 creds for ACME. `AWS_DEFAULT_REGION` is a non-secret literal kept in the template; only the two keys are references.

**Files:**
- Create: `modules/media/caddy.route53.env.tpl`
- Modify: `modules/media/caddy.nix`
- Host cleanup: remove `/etc/caddy/route53.env` after verification.

**Interfaces:**
- Consumes: `opSecrets` option (Task 2); 1P item `caddy-route53` fields `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (Task 1).
- Produces: rendered file `/var/lib/secrets/caddy-route53.env` (owner `caddy`, `0600`).

- [ ] **Step 1: Create the template**

Create `modules/media/caddy.route53.env.tpl` (note the literal region — `op inject` passes non-reference lines through unchanged):

```
AWS_ACCESS_KEY_ID={{ op://polaris/caddy-route53/AWS_ACCESS_KEY_ID }}
AWS_SECRET_ACCESS_KEY={{ op://polaris/caddy-route53/AWS_SECRET_ACCESS_KEY }}
AWS_DEFAULT_REGION=us-east-1
```

- [ ] **Step 2: Declare the secret and repoint the EnvironmentFile**

In `modules/media/caddy.nix`, add the `opSecrets` entry and repoint the caddy `EnvironmentFile`. Replace the current secret block:

```nix
  systemd.services.caddy.serviceConfig.EnvironmentFile = "/etc/caddy/route53.env";
```

with:

```nix
  opSecrets.caddy-route53 = {
    template = ./caddy.route53.env.tpl;
    path = "/var/lib/secrets/caddy-route53.env";
    owner = "caddy";
  };
  systemd.services.caddy.serviceConfig.EnvironmentFile = "/var/lib/secrets/caddy-route53.env";
```

Update the adjacent comment (`placed by hand at /etc/caddy/route53.env`) to note it is rendered from `op://polaris/caddy-route53/*` by op-secrets.

- [ ] **Step 3: Build the polaris toplevel (compile gate)**

On polaris:

```bash
cd /home/mattias/git/nixos-config
NIX_CONFIG="experimental-features = nix-command flakes" \
  nix build --impure .#nixosConfigurations.polaris.config.system.build.toplevel
```

Expected: builds successfully.

- [ ] **Step 4: Switch and verify (on polaris)**

Operator runs on polaris:

```bash
make switch NIXNAME=polaris
sudo ls -l /var/lib/secrets/caddy-route53.env      # -rw------- caddy caddy
sudo journalctl -b | grep 'op-secrets: rendered caddy-route53'
systemctl status caddy                             # active (running)
```

Confirm an existing vhost still serves over TLS (e.g. `curl -I https://miniflux.polaris.mattiasgees.be`). To exercise the DNS-01 path without waiting for renewal, tail caddy logs on next cert activity; a functional serve check is sufficient for this task.

- [ ] **Step 5: Remove the stale hand-placed file**

On polaris, only after Step 4 passes:

```bash
sudo rm /etc/caddy/route53.env
```

- [ ] **Step 6: Commit**

```bash
git add modules/media/caddy.route53.env.tpl modules/media/caddy.nix
git commit -m "feat(polaris): render caddy Route53 creds from 1Password"
```

---

### Task 5: Migrate restic secrets (repo password + S3 backend env)

Two secrets in one service. The repo password is a single-value file (matching `passwordFile` semantics — the template is one bare reference line). The backend env carries the two S3 keys plus the literal region.

**Files:**
- Create: `modules/server/restic.pass.tpl`
- Create: `modules/server/restic.backend.env.tpl`
- Modify: `modules/server/restic.nix`
- Host cleanup: remove `/etc/restic/polaris.pass` and `/etc/restic/hetzner.env` after verification.

**Interfaces:**
- Consumes: `opSecrets` option (Task 2); 1P items `restic` field `repo-password` and `restic-backend` fields `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (Task 1).
- Produces: rendered files `/var/lib/secrets/restic-repo.pass` and `/var/lib/secrets/restic-backend.env` (owner `root`, `0600`).

- [ ] **Step 1: Create the templates**

Create `modules/server/restic.pass.tpl` (single value — one bare reference, no `key=`):

```
{{ op://polaris/restic/repo-password }}
```

Create `modules/server/restic.backend.env.tpl`:

```
AWS_ACCESS_KEY_ID={{ op://polaris/restic-backend/AWS_ACCESS_KEY_ID }}
AWS_SECRET_ACCESS_KEY={{ op://polaris/restic-backend/AWS_SECRET_ACCESS_KEY }}
AWS_DEFAULT_REGION=nbg1
```

- [ ] **Step 2: Declare the secrets and repoint the consumer**

In `modules/server/restic.nix`, change the module signature to `{ ... }:` (unchanged) and add the two `opSecrets` entries plus repoint `passwordFile`/`environmentFile`:

```nix
{ ... }:
{
  opSecrets.restic-repo = {
    template = ./restic.pass.tpl;
    path = "/var/lib/secrets/restic-repo.pass";
    owner = "root";
  };
  opSecrets.restic-backend = {
    template = ./restic.backend.env.tpl;
    path = "/var/lib/secrets/restic-backend.env";
    owner = "root";
  };

  services.restic.backups.polaris = {
    repository = "s3:https://nbg1.your-objectstorage.com/backups-polaris";
    passwordFile = "/var/lib/secrets/restic-repo.pass";
    environmentFile = "/var/lib/secrets/restic-backend.env";
    paths = [ "/srv/data" ];
    exclude = [
      "/srv/data/immich/thumbs"
      "/srv/data/immich/encoded-video"
    ];
    initialize = true;
    pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 6" ];
    timerConfig = {
      OnCalendar = "03:00";
      Persistent = true;
    };
  };
}
```

Update the `Secrets:` comment block at the top of `restic.nix` to say the two files are rendered from `op://polaris/restic/*` and `op://polaris/restic-backend/*` by op-secrets, and drop the "hand-placed … see restic-backup-runbook.md" wording (or repoint the runbook note).

- [ ] **Step 3: Build the polaris toplevel (compile gate)**

On polaris:

```bash
cd /home/mattias/git/nixos-config
NIX_CONFIG="experimental-features = nix-command flakes" \
  nix build --impure .#nixosConfigurations.polaris.config.system.build.toplevel
```

Expected: builds successfully.

- [ ] **Step 4: Switch and verify (on polaris)**

Operator runs on polaris:

```bash
make switch NIXNAME=polaris
sudo ls -l /var/lib/secrets/restic-repo.pass /var/lib/secrets/restic-backend.env  # -rw------- root root
sudo journalctl -b | grep -E 'op-secrets: rendered restic-(repo|backend)'
# Functional check: restic can auth to the repo with rendered creds
sudo systemctl start restic-backups-polaris.service
systemctl status restic-backups-polaris.service                 # succeeds
sudo sh -c 'set -a; . /var/lib/secrets/restic-backend.env; \
  restic -r s3:https://nbg1.your-objectstorage.com/backups-polaris \
  --password-file /var/lib/secrets/restic-repo.pass snapshots' | tail
```

Expected: `restic snapshots` lists existing snapshots (repo password + S3 creds both valid).

- [ ] **Step 5: Remove the stale hand-placed files**

On polaris, only after Step 4 passes:

```bash
sudo rm /etc/restic/polaris.pass /etc/restic/hetzner.env
sudo rmdir /etc/restic 2>/dev/null || true
```

- [ ] **Step 6: Commit**

```bash
git add modules/server/restic.pass.tpl modules/server/restic.backend.env.tpl modules/server/restic.nix
git commit -m "feat(polaris): render restic repo password + S3 creds from 1Password"
```

---

### Task 6: Outage-independence check and runbook note

Proves the last-good guarantee and documents rotation for future-you.

**Files:**
- Modify: `docs/polaris/restic-backup-runbook.md` (and any other runbook that referenced a hand-placed `/etc/*` secret) — repoint to the op-secrets flow. If a general secrets runbook is wanted, create `docs/polaris/secrets-runbook.md`.

**Interfaces:**
- Consumes: everything from Tasks 2–5.
- Produces: documented rotation procedure; verified outage behavior.

- [ ] **Step 1: Simulate a 1Password outage (on polaris)**

Temporarily hide the token and switch; confirm rendering is skipped and services keep running on last-good files:

```bash
sudo mv /etc/op/token /etc/op/token.bak
make switch NIXNAME=polaris
sudo journalctl -b | grep 'op-secrets: no token'    # skip message present
systemctl status miniflux caddy                      # still active
sudo ls -l /var/lib/secrets/                          # files still present, untouched
sudo mv /etc/op/token.bak /etc/op/token
```

Expected: switch succeeds, warning logged, no service disrupted, secret files intact.

- [ ] **Step 2: Write/repoint the runbook**

Update the runbook(s) to document the rotation flow: edit the value in 1Password → `make switch NIXNAME=polaris` (re-renders) → `sudo systemctl restart <service>`. Note the bootstrap (`/etc/op/token`) and that `EnvironmentFile`/`passwordFile` changes do not auto-restart the consuming unit.

- [ ] **Step 3: Commit**

```bash
git add docs/polaris/
git commit -m "docs(polaris): document 1Password secret rotation + outage behavior"
```

---

## Notes for the executor

- Tasks 3/4/5 each end with removing a hand-placed `/etc` file. Do this **only after** the functional check in that task passes — the rendered file is the new source of truth, and the old file is your rollback if a render is wrong.
- If a render fails on switch, the activation log line `op-secrets: WARNING <name> render failed; keeping last-good` tells you which template/1P field to fix. The most common cause is a field-name mismatch between the `.tpl` reference and the 1P item.
- `op inject` reference syntax is `{{ op://vault/item/field }}` (double braces). Lines without a reference (like `AWS_DEFAULT_REGION=nbg1`) pass through verbatim.

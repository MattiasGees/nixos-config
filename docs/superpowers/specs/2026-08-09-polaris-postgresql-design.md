# PostgreSQL on polaris — Design (shared DB instance + management model)

**Status:** Draft for review
**Date:** 2026-08-09
**Host:** `polaris`

## 1. Purpose & scope

Stand up a **shared, self-managed PostgreSQL** on polaris: a general-purpose
database host for current and future services. **Immich is the driving first
consumer**, but the instance is deliberately *not* Immich-specific — future apps
that need a DB become tenants of this one instance.

**Scope is the Postgres instance + the repeatable "add a database/user"
workflow.** Two things are explicitly *out* of this spec and become their own
follow-up specs (same as any other feature here):

- **Immich itself** (§8).
- **Offsite backups** (restic → S3-compatible) + ZFS snapshot policy (§8).

## 2. Decisions (locked)

- **Shared, self-managed `services.postgresql`** — *not* the per-service DB that
  `services.immich` could auto-provision. We want one instance whose users/DBs
  we manage centrally, because multiple services will live here.
- **PostgreSQL 18** (`pkgs.postgresql_18`). VectorChord `1.1.1` in the pinned
  nixpkgs supports pg18 (marked broken only for ≥19), and Immich's module talks
  to whatever instance exists over the socket. *(17 is the more CI-exercised
  combo for the Immich module — swap to `postgresql_17` if we want maximum
  conservatism; greenfield, so the choice is free to make now.)*
- **Data on the `fast` pool as a directory in the existing `fast/db` dataset** —
  `dataDir = /srv/fast/db/postgres/18`. **No new `zfs create`.** This mirrors the
  established repo convention (Plex's DB lives at `/srv/fast/appdata/plex`, a
  directory inside the existing `fast/appdata` dataset — see the Plex spec).
- **Local peer auth over the unix socket. No passwords, no secrets.** Postgres
  stays on `localhost` + the unix socket only — no `listen_addresses` change and
  **no firewall opening**.
- **Databases/roles are declared declaratively** (`ensureDatabases` /
  `ensureUsers`). None are created in this spec — the instance ships empty; the
  first real tenant (Immich) adds its own in its own spec.
- **Backups deferred** to a follow-up (§8).

## 3. Storage

| What | Location | Pool | Notes |
|------|----------|------|-------|
| PG data dir | **`/srv/fast/db/postgres/18`** | `fast` (NVMe mirror, encrypted) | A **directory inside the existing `fast/db` dataset** — no new dataset, exactly like `fast/appdata/plex`. The `/18` version subdir mirrors NixOS's own default (`/var/lib/postgresql/${psqlSchema}`) and keeps a future major upgrade sane (`pg_upgrade` wants `17/` and `18/` side by side). |

**`recordsize`:** `fast/db` is the database-purpose dataset, so DB tuning is a
property of *that dataset*, not of a per-service child. Postgres does 8k random
IO, so `fast/db` should be `recordsize=16k`. If it isn't already, run once on the
box: `zfs set recordsize=16k fast/db` (applies to newly-written files, which is
all the fresh Postgres data). This is a property check, **not** a new dataset and
**not** a blocker.

**Non-default `dataDir` caveat (handled in the module):** when `dataDir` is not
the default, NixOS does **not** auto-create it — *"the sysadmin is responsible
for ensuring the directory exists with appropriate ownership and permissions."*
The module therefore provisions it via `systemd.tmpfiles` before `initdb` runs
(§4), so there is no manual `mkdir`/`chown`.

## 4. The PostgreSQL service (`modules/server/postgresql.nix`)

A new reusable server module, imported by `machines/polaris.nix`:

- `services.postgresql.enable = true;`
- `services.postgresql.package = pkgs.postgresql_18;`
- `services.postgresql.dataDir = "/srv/fast/db/postgres/18";`
- **No `extensions` declared** — the Immich module injects `pgvector` +
  `vectorchord` itself when it's added later. The base instance stays minimal.
- **No `listen_addresses` / `enableTCPIP`** → localhost + unix socket only.
  **No firewall change.**
- **tmpfiles** to satisfy the non-default `dataDir` ownership requirement:
  ```nix
  systemd.tmpfiles.rules = [
    "d /srv/fast/db/postgres    0755 root     root     - -"
    "d /srv/fast/db/postgres/18 0700 postgres postgres - -"
  ];
  ```
  (`fast/db` itself already exists as the ZFS mount; we only create the
  `postgres/` grouping dir and the `18/` datadir with the ownership/mode
  `initdb` requires.)

## 5. Database / user management model (the reusable workflow)

This is the answer to *"how do we manage databases and users on this server."*

**Declarative — add a DB + role in Nix:**
```nix
services.postgresql = {
  ensureDatabases = [ "myapp" ];
  ensureUsers = [
    { name = "myapp"; ensureDBOwnership = true; }
  ];
};
```
A rebuild creates them if missing. **Nix never drops** — destructive changes
(drop/rename a DB or role) are done by hand via `psql`, on purpose.

**Auth = peer over the unix socket, no passwords.** The NixOS default
`local all all peer` maps an OS uid to the same-named role: a service running as
system user `myapp` connects to database `myapp` as role `myapp` with **zero
credentials**. The rule of thumb: **prefer services whose system username equals
their DB role name** — that keeps every secret out of git. (Immich fits this: it
runs as user `immich`, role `immich`, db `immich`, over the socket.)

**Admin entrypoint:** `sudo -u postgres psql` (the `postgres` superuser).

**Escape hatch — not built now (YAGNI):** a client that *must* use TCP or a
password (a container, or a `DynamicUser` whose name ≠ its role) needs a password
set out-of-band (`\password` in psql) plus a **hand-placed secret file**, matching
the existing `/etc/caddy/route53.env` convention — or we adopt `sops-nix` /
`agenix` at that point. `ensureUsers` intentionally cannot set passwords, which is
why peer-over-socket is the default path. We only reach for this if something
concrete needs it.

## 6. Repo structure

| File | Responsibility |
|------|----------------|
| `modules/server/postgresql.nix` | `services.postgresql` (pg18, `dataDir` on `fast/db`, tmpfiles ownership). The single reusable Postgres module. |
| `machines/polaris.nix` | adds `../modules/server/postgresql.nix` to `imports`. |

**Manual prerequisites:** none new. `fast/db` already exists. Optional one-time
`zfs set recordsize=16k fast/db` if it isn't already 16k (§3).

## 7. Post-deploy & verification

1. `make switch NIXNAME=polaris`.
2. `systemctl status postgresql` → **active**.
3. `sudo -u postgres psql -c 'SHOW data_directory;'` → `/srv/fast/db/postgres/18`
   (confirms data landed on the `fast` pool, not the root disk).
4. `sudo -u postgres psql -c '\l'` lists the (empty-of-tenants) cluster.
5. **Not network-exposed:** `ss -tlnp | grep 5432` shows localhost only (or
   nothing bound to an external interface).
6. **Peer-auth smoke test** (optional; or defer to the first real tenant): add a
   throwaway `ensureDatabases`/`ensureUsers` pair + a matching system user,
   rebuild, and confirm `sudo -u <user> psql <db>` connects with no password.

## 8. Deferred / future (each its own spec → plan)

- **Immich** — `services.immich` pointed at this instance over the socket
  (`database.host = "/run/postgresql"`, `database.createDB = true`,
  `redis.enable = true`). The module **layers `pgvector` + `vectorchord`** and
  creates the `immich` DB/role/extensions on top of this cluster. Library on a
  `tank` location via `mediaLocation`; Caddy vhost
  `immich.polaris.mattiasgees.be` → `localhost:2283`; optional NVENC / ML GPU
  acceleration (RTX 3080) as a further follow-up.
- **Backups** — `restic` → S3-compatible bucket (encrypted, deduped, retention)
  of a nightly `pg_dumpall` (the Immich-blessed, extension-safe logical format),
  plus **local ZFS snapshots** of the DB directory as the fast-rollback tier.
  AWS S3 reuses the existing Route53 creds pattern; provider TBD in that spec.

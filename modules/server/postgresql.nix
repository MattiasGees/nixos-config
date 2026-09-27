# Shared PostgreSQL 18 for polaris — one cluster, many tenants (immich,
# miniflux, outline). Deliberately tenant-agnostic: no `extensions` or
# `ensureDatabases`/`ensureUsers` here. Each tenant's own module adds its
# role/DB (and any extensions, which merge) so this file never changes.
#
# Auth: unix socket only (no TCP, no firewall hole). NixOS's default
# `local all all peer` maps OS user `foo` to DB role `foo`, so tenants need no
# passwords. Admin access: `sudo -u postgres psql`.
#
# Data: /srv/fast/db/postgres/18, a plain dir inside the existing `fast/db`
# dataset. The `18/` suffix mirrors NixOS's default dataDir naming so a future
# major upgrade can run old and new side by side for `pg_upgrade`. NixOS only
# creates the *default* dataDir, so the tmpfiles rules below provision this
# one (postgres:postgres 0700, as initdb requires).
#
# Backup: a nightly `pg_dumpall` (backupAll) of every database plus globals
# (roles, grants), so new tenants are covered automatically. It lands on
# tank/data (/srv/data/postgres-backup, not the live fast pool) at 02:30,
# ahead of restic's 03:00 sweep (restic.nix), which provides the history —
# on disk only the latest dump (+ one `.prev`) is kept. The backup module
# creates that directory itself.
{ pkgs, ... }:
{
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_18;
    dataDir = "/srv/fast/db/postgres/18";
  };

  services.postgresqlBackup = {
    enable = true;
    backupAll = true;
    location = "/srv/data/postgres-backup";
    startAt = "02:30";
  };

  systemd.tmpfiles.rules = [
    "d /srv/fast/db/postgres    0755 root     root     - -"
    "d /srv/fast/db/postgres/18 0700 postgres postgres - -"
  ];
}

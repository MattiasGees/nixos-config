# Shared, self-managed PostgreSQL for polaris — one instance, multiple future
# tenants. Immich is the driving first consumer but this module stays
# Immich-agnostic on purpose: it ships the bare `services.postgresql` (pg18,
# data on the fast pool) and nothing else. No `extensions`, no
# `ensureDatabases`/`ensureUsers` here — Immich's own module layers pgvector +
# vectorchord and creates its DB/role when that spec lands; keeping this
# module empty means every future tenant adds itself declaratively without
# touching this file.
#
# Auth model: localhost + unix socket only (no `listen_addresses`/
# `enableTCPIP` change, no firewall opening). NixOS's default
# `local all all peer` maps an OS uid to the same-named DB role, so a service
# running as system user `foo` connects to database `foo` as role `foo` with
# zero passwords/secrets — see the design doc for the full workflow. Admin
# access is `sudo -u postgres psql`.
#
# Data lives at /srv/fast/db/postgres/18 — a directory *inside* the existing
# `fast/db` ZFS dataset, not a new dataset (same pattern as Plex's DB at
# /srv/fast/appdata/plex). The `18/` subdir mirrors NixOS's own default
# dataDir naming (/var/lib/postgresql/${psqlSchema}) so a future major
# upgrade can run `17/` and `18/` side by side under `pg_upgrade`.
#
# tmpfiles: NixOS only auto-creates the *default* dataDir. Point
# `services.postgresql.dataDir` anywhere else and "the sysadmin is
# responsible for ensuring the directory exists with appropriate ownership
# and permissions" — so we provision it here before initdb runs. `fast/db`
# already exists as the ZFS mount; these rules just create the `postgres/`
# grouping dir and the `18/` datadir with the postgres:postgres 0700
# ownership initdb requires.
#
# Backup: `services.postgresqlBackup` is the cluster's whole backup story — a
# nightly `pg_dumpall` (`backupAll = true`) of *every* database plus the
# cluster globals (roles, grants, passwords), not a per-DB list. That keeps
# it tenant-agnostic: a new tenant's database is captured the moment it
# exists, with nothing to add here. The dump lands under `tank/data` at
# /srv/data/postgres-backup — deliberately *not* the fast pool holding the
# live data dir — so it rides the restic sweep of /srv/data (see
# modules/server/restic.nix) offsite. It runs at 02:30, ahead of restic's
# 03:00, so restic always finds a fresh dump. The module's own tmpfiles rule
# creates the location (postgres:postgres 0700), so — unlike the dataDir
# above — we add no rule for it here. On disk it keeps only the latest dump
# (plus one `.prev`); the restic snapshots are what provide the history.
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

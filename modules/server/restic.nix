# Offsite backup (Hetzner object storage) of polaris' irreplaceable data. One
# sweep covers everything under /srv/data (Immich library + its built-in DB
# dumps, the cluster pg_dumpall, filebrowser files, …) and /srv/fast/appdata,
# so new tenants storing there are covered with no wiring here.
#
# Ordering: nightly dumps land first — ~02:00 Immich, 02:30 pg_dumpall, 02:45
# karakeep SQLite — then restic at 03:00. Restic only copies whatever dump is
# on disk, so keep Immich's built-in DB backup enabled (Admin → Settings →
# Backup).
#
# Excludes: Immich's thumbs/ and encoded-video/ are regenerated on demand from
# the originals; skipping them roughly halves size/egress.
#
# Secrets are rendered by op-secrets from op://polaris/restic/* and
# op://polaris/restic-backend/*.
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
    # /srv/fast/appdata = per-service config/SQLite (the *arrs, plex, karakeep,
    # outline, …): small but tedious to recreate. NOTE: those DBs are copied
    # live; only karakeep has a consistent export (karakeep.nix). Per-app
    # SQLite dumps for the *arr stack would be a possible improvement.
    paths = [ "/srv/data" "/srv/fast/appdata" ];
    exclude = [
      "/srv/data/immich/thumbs"
      "/srv/data/immich/encoded-video"
    ];
    initialize = true;
    pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 6" ];
    timerConfig = {
      OnCalendar = "03:00";
      Persistent = true; # run at next boot if polaris was off at 03:00
    };
  };
}

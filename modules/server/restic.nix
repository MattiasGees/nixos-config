# Offsite backup of the irreplaceable data on polaris: the whole /srv/data
# dataset, swept in one pass. That covers the Immich photo/video library and
# its own built-in DB dumps (/srv/data/immich/backups/), the cluster-wide
# pg_dumpall (/srv/data/postgres-backup/, see modules/server/postgresql.nix),
# and any future tenant that stores its data under /srv/data — each rides this
# same sweep offsite for free, with no per-service wiring here.
#
# Ordering: the nightly dumps land before restic runs — ~02:00 Immich dump →
# 02:30 pg_dumpall → 03:00 restic — so restic always sweeps fresh dumps rather
# than racing them. Confirm in Immich → Admin → Settings → Backup that its
# built-in dump stays enabled — restic has no opinion on the DB itself, it
# just backs up whatever dump is on disk when it runs.
#
# Excludes: `thumbs/` and `encoded-video/` are derived from the originals —
# Immich regenerates both on demand — so skipping them keeps the offsite copy
# to the irreplaceable `library/`, `upload/`, `profile/`, and `backups/`
# (roughly halving size/egress against Hetzner).
#
# `Persistent = true`: if polaris is off at 03:00, the missed run fires at
# next boot instead of silently being skipped until the following day.
#
# Secrets: `passwordFile` and `environmentFile` below are rendered at deploy
# time by op-secrets from op://polaris/restic/* and op://polaris/restic-backend/*
# in 1Password — see modules/server/op-secrets.nix; this module only ever
# references their rendered paths.
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

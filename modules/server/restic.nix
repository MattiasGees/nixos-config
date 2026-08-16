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
# Secrets: `passwordFile` and `environmentFile` below are hand-placed on the
# box, 0600, root-owned, out of git — the same convention as
# /etc/caddy/route53.env in modules/media/caddy.nix. See
# docs/polaris/restic-backup-runbook.md for exact contents and how to place
# them; this module only ever references their paths.
{ ... }:
{
  services.restic.backups.polaris = {
    repository = "s3:https://nbg1.your-objectstorage.com/backups-polaris";
    passwordFile = "/etc/restic/polaris.pass";
    environmentFile = "/etc/restic/hetzner.env";
    # /srv/data = the irreplaceable data dataset (Immich + DB dumps + any tenant
    # storing under it). /srv/fast/appdata = every service's config/SQLite DB on
    # the fast mirror (the *arr stack, bazarr, plex, karakeep, …) — small, awkward
    # to recreate by hand, so it rides the same offsite sweep. NOTE: those app DBs
    # are copied live; the only one with a point-in-time-consistent export is
    # karakeep (its 02:45 .backup/.dump in modules/media/karakeep.nix). Adding
    # per-app SQLite dumps for the *arr stack is a possible future improvement.
    paths = [ "/srv/data" "/srv/fast/appdata" ];
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

# Offsite backup of the one irreplaceable dataset on polaris: the Immich
# photo/video library at /srv/data/immich. That path also holds Immich's own
# built-in DB dumps (written to /srv/data/immich/backups/), so a single restic
# sweep captures both the originals and the database — no separate
# `pg_dumpall` needed here (see the design doc for why that's deferred).
#
# Ordering: Immich's built-in backup runs nightly around 02:00; the timer
# below fires at 03:00 so restic always sweeps a fresh DB dump rather than
# racing it. Confirm in Immich → Admin → Settings → Backup that it stays
# enabled — restic has no opinion on the DB itself, it just backs up whatever
# dump is on disk when it runs.
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
    paths = [ "/srv/data/immich" ];
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

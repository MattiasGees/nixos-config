# On-LAN second copy of the whole tank/data dataset (/srv/data), mirrored
# every 12 hours to the house NAS over NFS. This complements — does not replace — the
# encrypted restic→Hetzner tier in modules/server/restic.nix: restic is the
# offsite, encrypted, deduplicated backup of the irreplaceable Immich subset;
# this is a fast, browsable 1:1 rsync mirror of the entire data dir on the NAS
# at 192.168.1.88. tank/media (/srv/media) is deliberately not synced — bulk
# and re-downloadable.
#
# Automount: the share is mounted on demand at /mnt/polaris-nfs with
# `noauto` + `nofail`, so an offline NAS never blocks boot or wedges other
# units. `x-systemd.automount` mounts it on first access and the
# idle-timeout unmounts it 10 min after each run finishes, so the mount
# only exists while it's actually being written to. `nfsvers=4.0` is pinned so
# the client does not negotiate up to 4.1/4.2 (NFSv4 needs no rpcbind here).
#
# RequiresMountsFor ties the sync service to that automount: touching the path
# triggers the mount, and the service fails cleanly (a real error in
# journalctl) if the NAS is unreachable, rather than silently mirroring into an
# empty /mnt/polaris-nfs on the root disk.
#
# Trade-off: plaintext on the wire and at rest. tank/data is encrypted at rest
# on ZFS, but rsync reads it decrypted and NFSv4.0 here is unencrypted over the
# LAN, so the copy lands as plaintext on the NAS. Accepted — this is a
# trusted-LAN mirror; the encrypted end-to-end tier stays restic→Hetzner.
#
# The `/volume1/polaris` export (a Synology shared folder — shares live under
# /volume1, so the NFS path is /volume1/polaris, not /polaris), its host
# allow-list, and the root_squash decision are manual NAS-side steps out of
# git — see
# docs/polaris/nfs-data-backup-runbook.md for those and the verify checklist;
# this module only ever references the mountpoint and share path.
{ pkgs, ... }:
{
  # On-demand NFS automount of the house NAS share. noauto + nofail so an
  # offline NAS never blocks boot; idle-timeout unmounts it between runs.
  fileSystems."/mnt/polaris-nfs" = {
    device = "192.168.1.88:/volume1/polaris";
    fsType = "nfs";
    options = [
      "nfsvers=4.0"
      "noauto"
      "nofail"
      "_netdev"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
    ];
  };

  systemd.services.polaris-data-nfs-sync = {
    description = "Mirror /srv/data to NFS share on 192.168.1.88";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    # Pull in (and thus trigger) the automount; fail cleanly if the NAS is down.
    unitConfig.RequiresMountsFor = "/mnt/polaris-nfs";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = ''
        ${pkgs.rsync}/bin/rsync -a --delete --numeric-ids \
          --exclude=/immich/thumbs \
          --exclude=/immich/encoded-video \
          /srv/data/ /mnt/polaris-nfs/
      '';
    };
  };

  systemd.timers.polaris-data-nfs-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # Every 12 hours, at 00:00 and 12:00.
      OnCalendar = "0/12:00:00";
      Persistent = true;
    };
  };
}

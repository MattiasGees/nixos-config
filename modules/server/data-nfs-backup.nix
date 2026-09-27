# On-LAN second copy of tank/data (/srv/data): a browsable rsync mirror to the
# house NAS (192.168.1.88) every 12 hours. Complements, not replaces, the
# encrypted offsite restic→Hetzner tier (restic.nix). Immich's regenerable
# thumbs/encoded-video are skipped (same excludes as restic); tank/media is not
# synced at all — bulk and re-downloadable.
#
# Mount: on-demand automount with noauto + nofail, so an offline NAS never
# blocks boot; the idle-timeout unmounts it 10 min after each run. nfsvers=4.0
# is pinned so the client doesn't negotiate up to 4.1/4.2 (and v4 needs no
# rpcbind). The sync unit's RequiresMountsFor triggers the mount and makes the
# run fail loudly if the NAS is down, instead of mirroring into an empty
# /mnt/polaris-nfs on the root disk.
#
# Trade-off: plaintext on the wire and at rest. rsync reads the encrypted
# dataset decrypted and NFSv4.0 is unencrypted, so the NAS copy is plaintext.
# Accepted for a trusted-LAN mirror; restic stays the encrypted tier.
#
# NAS side (manual, out of git): the `/volume1/polaris` Synology export (shares
# live under /volume1, hence not /polaris), its host allow-list and
# root_squash — see docs/polaris/nfs-data-backup-runbook.md.
{ pkgs, ... }:
{
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
    # Triggers the automount; fails the run if the NAS is down (see header).
    unitConfig.RequiresMountsFor = "/mnt/polaris-nfs";
    serviceConfig = {
      Type = "oneshot";
      # --no-owner/--no-group: the export runs root_squash, so every chown is
      # rejected and plain `-a` exits 23 on every run (data still copies, but
      # the unit is permanently red and useless as a health signal). Ownership
      # doesn't matter on a browse-only mirror, so skip it and let a non-zero
      # exit mean a real failure.
      ExecStart = ''
        ${pkgs.rsync}/bin/rsync -a --delete --no-owner --no-group \
          --exclude=/immich/thumbs \
          --exclude=/immich/encoded-video \
          /srv/data/ /mnt/polaris-nfs/
      '';
    };
  };

  systemd.timers.polaris-data-nfs-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      # 00:00 and 12:00.
      OnCalendar = "0/12:00:00";
      Persistent = true;
    };
  };
}

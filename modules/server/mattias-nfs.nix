# On-demand NFS automount of the `mattias` shared folder on the house NAS
# (192.168.1.88) — a plain browse/use mount. Same options and rationale as the
# backup mount in data-nfs-backup.nix. The `/volume1/mattias` export, its host
# allow-list and squash settings are manual NAS-side steps, out of git.
{ ... }:
{
  fileSystems."/srv/mattias" = {
    device = "192.168.1.88:/volume1/mattias";
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
}

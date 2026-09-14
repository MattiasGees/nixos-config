# On-demand NFS automount of the `mattias` shared folder on the house NAS
# (192.168.1.88). Same format as the polaris backup mount in
# data-nfs-backup.nix, but this is a plain browse/use mount — no rsync, no
# filebrowser wiring. noauto + nofail so an offline NAS never blocks boot;
# x-systemd.automount mounts it on first access and the idle-timeout unmounts
# it 10 min after last use, so the mount only exists while it's in use.
# `nfsvers=4.0` is pinned so the client does not negotiate up to 4.1/4.2.
#
# The `/volume1/mattias` export (a Synology shared folder — shares live under
# /volume1), its host allow-list, and squash settings are manual NAS-side
# steps out of git; this module only references the mountpoint and share path.
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

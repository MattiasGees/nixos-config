# Read-only NFS mount of the seedbox's completed-downloads dir, over the tailnet.
# Sonarr/Radarr import (copy) from here into /srv/media. Mounted at the SAME path
# the qBittorrent container reports (/mnt/media-downloads) so the *arr need no
# Remote Path Mapping. automount + soft + nofail: a seedbox/tailnet blip degrades
# imports gracefully instead of hanging polaris.
{ ... }:
let
  seedboxTailnetIp = "SEEDBOX_TAILNET_IP";  # BUILD-TIME: `tailscale ip -4` on the seedbox
in
{
  fileSystems."/mnt/media-downloads" = {
    device = "${seedboxTailnetIp}:/mnt/media-downloads";
    fsType = "nfs";
    options = [
      "ro" "nfsvers=4" "soft" "nofail"
      "x-systemd.automount" "x-systemd.idle-timeout=600"
      "timeo=50" "retrans=2"
    ];
  };
}

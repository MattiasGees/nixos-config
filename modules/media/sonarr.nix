# Sonarr (TV series automation). Config on the fast pool (SQLite DB worth
# keeping on the redundant NVMe mirror), library access via the shared
# `media` group. No openFirewall — localhost only, Caddy is the only ingress
# (port 8989).
{ pkgs, lib, ... }:
{
  services.sonarr = {
    enable = true;
    dataDir = "/srv/fast/appdata/sonarr";
  };

  # media = read/write /srv/media (root folder: /srv/media/Series).
  users.users.sonarr.extraGroups = [ "media" ];

  # Create library dirs group-writable (2775) so other media-group members
  # (e.g. Bazarr writing sidecar subtitles) can add files next to the video.
  # The default systemd UMask=0022 strips the group-write bit, leaving 2755;
  # setgid then propagates the media group but not write permission, so a
  # non-owner in the group gets PermissionError on write. 0002 keeps group write.
  # mkForce: the upstream servarr module pins UMask="0022"; override it.
  systemd.services.sonarr.serviceConfig.UMask = lib.mkForce "0002";

  # The nixpkgs module does not create a custom dataDir, and the parent
  # /srv/fast/appdata is root-owned, so Sonarr (running as `sonarr`) cannot
  # create it itself ("Access to the path /srv/fast/appdata/sonarr is denied").
  # Create + chown it as root before start. The `+` prefix runs as root despite
  # User=sonarr; the unit's RequiresMountsFor=/srv/fast/appdata/sonarr guarantees
  # the ZFS dataset is mounted first, so this never writes under the mountpoint.
  systemd.services.sonarr.serviceConfig.ExecStartPre = lib.mkBefore [
    "+${pkgs.coreutils}/bin/install -d -o sonarr -g sonarr -m 0700 /srv/fast/appdata/sonarr"
  ];
}

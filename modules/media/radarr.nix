# Radarr (movie automation). Config on the fast pool (SQLite DB worth
# keeping on the redundant NVMe mirror), library access via the shared
# `media` group. No openFirewall — localhost only, Caddy is the only ingress
# (port 7878).
{ pkgs, lib, ... }:
{
  services.radarr = {
    enable = true;
    dataDir = "/srv/fast/appdata/radarr";
  };

  # media = read/write /srv/media (root folder: /srv/media/Movies).
  users.users.radarr.extraGroups = [ "media" ];

  # Create library dirs group-writable (2775) so other media-group members
  # (e.g. Bazarr writing sidecar subtitles) can add files next to the video.
  # The default systemd UMask=0022 strips the group-write bit, leaving 2755;
  # setgid then propagates the media group but not write permission, so a
  # non-owner in the group gets PermissionError on write. 0002 keeps group write.
  # mkForce: the upstream servarr module pins UMask="0022"; override it.
  systemd.services.radarr.serviceConfig.UMask = lib.mkForce "0002";

  # Same as Sonarr: the module does not create a custom dataDir and the parent
  # is root-owned. Radarr's dir currently exists only as a leftover from an
  # earlier deploy — create it declaratively so a fresh pool works too. `+` runs
  # as root; RequiresMountsFor guarantees the dataset is mounted first.
  systemd.services.radarr.serviceConfig.ExecStartPre = lib.mkBefore [
    "+${pkgs.coreutils}/bin/install -d -o radarr -g radarr -m 0700 /srv/fast/appdata/radarr"
  ];
}

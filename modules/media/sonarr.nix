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
  # (e.g. Bazarr's sidecar subtitles) can write next to the video. Under the
  # upstream-pinned UMask=0022 they'd be 2755: setgid passes on the group but
  # not write permission. mkForce overrides that pin.
  systemd.services.sonarr.serviceConfig.UMask = lib.mkForce "0002";

  # The module doesn't create a custom dataDir and /srv/fast/appdata is
  # root-owned, so Sonarr fails with "Access to the path ... is denied".
  # `+` runs this as root; the module's RequiresMountsFor on dataDir ensures
  # the dataset is mounted first, so it never writes under the mountpoint.
  systemd.services.sonarr.serviceConfig.ExecStartPre = lib.mkBefore [
    "+${pkgs.coreutils}/bin/install -d -o sonarr -g sonarr -m 0700 /srv/fast/appdata/sonarr"
  ];
}

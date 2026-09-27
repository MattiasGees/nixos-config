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

  # Group-writable library dirs; see sonarr.nix.
  systemd.services.radarr.serviceConfig.UMask = lib.mkForce "0002";

  # Same root-create step as sonarr.nix. Current upstream radarr also creates
  # dataDir via tmpfiles, so this is belt-and-braces on a fresh pool.
  systemd.services.radarr.serviceConfig.ExecStartPre = lib.mkBefore [
    "+${pkgs.coreutils}/bin/install -d -o radarr -g radarr -m 0700 /srv/fast/appdata/radarr"
  ];
}

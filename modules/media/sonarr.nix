# Sonarr (TV series automation). Config on the fast pool (SQLite DB worth
# keeping on the redundant NVMe mirror), library access via the shared
# `media` group. No openFirewall — localhost only, Caddy is the only ingress
# (port 8989).
{ ... }:
{
  services.sonarr = {
    enable = true;
    dataDir = "/srv/fast/appdata/sonarr";
  };

  # media = read/write /srv/media (root folder: /srv/media/Series).
  users.users.sonarr.extraGroups = [ "media" ];
}

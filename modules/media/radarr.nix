# Radarr (movie automation). Config on the fast pool (SQLite DB worth
# keeping on the redundant NVMe mirror), library access via the shared
# `media` group. No openFirewall — localhost only, Caddy is the only ingress
# (port 7878).
{ ... }:
{
  services.radarr = {
    enable = true;
    dataDir = "/srv/fast/appdata/radarr";
  };

  # media = read/write /srv/media (root folder: /srv/media/Movies).
  users.users.radarr.extraGroups = [ "media" ];
}

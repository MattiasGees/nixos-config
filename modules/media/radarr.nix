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

  # Same as Sonarr: the module does not create a custom dataDir and the parent
  # is root-owned. Radarr's dir currently exists only as a leftover from an
  # earlier deploy — create it declaratively so a fresh pool works too. `+` runs
  # as root; RequiresMountsFor guarantees the dataset is mounted first.
  systemd.services.radarr.serviceConfig.ExecStartPre = lib.mkBefore [
    "+${pkgs.coreutils}/bin/install -d -o radarr -g radarr -m 0700 /srv/fast/appdata/radarr"
  ];
}

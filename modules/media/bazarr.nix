# Bazarr — subtitle automation for Sonarr/Radarr. Downloads sidecar .srt files
# next to each video; Plex's Local Media Assets agent picks them up (no Plex
# Pass needed). Config on the fast pool (SQLite DB worth keeping on the redundant
# NVMe mirror), library access via the shared `media` group. No openFirewall —
# localhost only, Caddy is the only ingress (port 6767).
{ ... }:
{
  services.bazarr = {
    enable = true;
    dataDir = "/srv/fast/appdata/bazarr";
    listenPort = 6767;
  };

  # media = read /srv/media and write sidecar subtitles next to each video.
  # Unlike the *arr modules, the bazarr module creates its dataDir itself (via
  # systemd.tmpfiles, owned bazarr:bazarr) and sets RequiresMountsFor, so no
  # ExecStartPre root-create step is needed here.
  users.users.bazarr.extraGroups = [ "media" ];

  # Write sidecar subtitles group-writable/readable (0664) so other media-group
  # members (Plex, the *arrs) can manage them, matching the 0002 umask used by
  # Sonarr/Radarr when creating the library directories these files land in.
  systemd.services.bazarr.serviceConfig.UMask = "0002";
}

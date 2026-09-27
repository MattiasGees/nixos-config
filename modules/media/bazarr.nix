# Bazarr — subtitle automation for Sonarr/Radarr. Downloads sidecar .srt files
# next to each video; Plex's Local Media Assets agent picks them up (no Plex
# Pass needed). Config on the fast pool (SQLite DB worth keeping on the redundant
# NVMe mirror), library access via the shared `media` group. No openFirewall —
# localhost only, Caddy is the only ingress (port 6767).
{ lib, ... }:
{
  services.bazarr = {
    enable = true;
    dataDir = "/srv/fast/appdata/bazarr";
    listenPort = 6767;
  };

  # media = read /srv/media and write sidecar subtitles next to each video.
  # The upstream module creates dataDir itself (tmpfiles) and sets
  # RequiresMountsFor, so no ExecStartPre create step like sonarr.nix.
  users.users.bazarr.extraGroups = [ "media" ];

  # Subtitles group-writable (0664) so other media-group members can manage
  # them; same 0002 UMask as sonarr.nix (see there), mkForce for parity.
  systemd.services.bazarr.serviceConfig.UMask = lib.mkForce "0002";
}

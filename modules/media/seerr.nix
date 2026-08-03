# Seerr (seerr.dev) — media request manager, the merged successor of
# Overseerr + Jellyseerr. Talks to Plex and the *arr APIs over the network; it
# needs no access to /srv/media, so — like Prowlarr — no `media` group.
#
# Like Prowlarr, this only turns the service on and keeps the module's default
# state dir (/var/lib/seerr). The module runs Seerr as a systemd DynamicUser
# with ProtectSystem=strict, so relocating configDir onto the fast pool would
# need ReadWritePaths + tmpfiles ownership workarounds for little gain: the DB
# holds only reconstructible config, user accounts (re-imported from Plex) and
# request history — no media, and nothing as costly to lose as the *arr state.
#
# No openFirewall — localhost only, Caddy is the only ingress (port 5055).
# `services.jellyseerr` was renamed to `services.seerr` upstream (the alias
# still works); use the current name.
{ ... }:
{
  services.seerr.enable = true;
}

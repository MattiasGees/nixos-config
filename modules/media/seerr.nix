# Seerr (seerr.dev) — media request manager, successor of Overseerr +
# Jellyseerr (`services.jellyseerr` is now an alias). Talks to Plex and the
# *arrs over their APIs, so no `media` group.
#
# Keeps the default state dir (/var/lib/seerr): the module runs a DynamicUser
# with ProtectSystem=strict, so moving configDir to the fast pool would need
# ReadWritePaths + ownership workarounds for little gain — the DB only holds
# reconstructible config, Plex-imported accounts and request history.
#
# No openFirewall. Ingress: Caddy (tailnet) and the public Cloudflare tunnel
# (requests.gees.dev), both to port 5055.
{ ... }:
{
  services.seerr.enable = true;
}

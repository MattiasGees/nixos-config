# Prowlarr (indexer manager). Unlike sonarr/radarr this only turns the
# service on — the prowlarr module may not expose dataDir/user like the
# others, and setting an option it doesn't support would fail the build. It
# keeps its module default state dir (/var/lib/prowlarr); fine since it's an
# indexer manager with no media access, so no `media` group membership
# either. No openFirewall — localhost only, Caddy is the only ingress
# (port 9696).
{ ... }:
{
  services.prowlarr.enable = true;
}

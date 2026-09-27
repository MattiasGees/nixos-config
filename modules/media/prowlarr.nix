# Prowlarr (indexer manager). Keeps the module's default state dir
# (/var/lib/prowlarr, on the OS disk — outside restic's paths) and needs no
# `media` group: it never touches the library. No openFirewall — Caddy is the
# only ingress (port 9696).
{ ... }:
{
  services.prowlarr.enable = true;
}

# Recyclarr — syncs TRaSH-Guides quality profiles + custom formats into Sonarr.
# CLI only, NO timer (by choice): run `recyclarr sync` by hand. The config is
# declarative (./recyclarr.yml → /etc/recyclarr/recyclarr.yml); API keys stay OUT
# of the Nix store via !env_var, provided at sync time:
#   SONARR_API_KEY=<key> recyclarr sync --config /etc/recyclarr/recyclarr.yml --preview
# Promote to services.recyclarr (timer + config as a Nix attrset) later if wanted.
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.recyclarr ];
  environment.etc."recyclarr/recyclarr.yml".source = ./recyclarr.yml;
}

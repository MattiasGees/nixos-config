# Recyclarr — syncs TRaSH-Guides quality profiles + custom formats into Sonarr
# and Radarr. CLI only, no timer (by choice); usage is in the header of
# ./recyclarr.yml. Could be promoted to services.recyclarr (timer + Nix-attrset
# config) later.
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.recyclarr ];
  environment.etc."recyclarr/recyclarr.yml".source = ./recyclarr.yml;
}

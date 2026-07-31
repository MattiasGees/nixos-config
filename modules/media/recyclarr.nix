# Recyclarr CLI — syncs TRaSH-Guides custom formats and quality-profile scores
# into Sonarr/Radarr. Installed as a CLI for now: author ~/.config/recyclarr/
# recyclarr.yml and run `recyclarr sync` by hand (SONARR_API_KEY / RADARR_API_KEY
# come from the env or the config). Can be promoted to services.recyclarr
# (systemd timer + declarative config) once the config is dialed in.
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.recyclarr ];
}

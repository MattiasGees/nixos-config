# conductor — the home dashboard (github.com/MattiasGees/conductor, private):
# trains, tube, room climate, lights, plugs and Sonos, on the phones, laptops
# and the wall tablet. Runbook: docs/polaris/conductor.md.
#
# The service itself comes from the conductor flake's module, wired in
# flake.nix for polaris only (like vmctl). It runs as the static user
# `conductor` on 127.0.0.1:8420; Caddy fronts it at
# conductor.polaris.mattiasgees.be for LAN and tailnet clients only
# (caddy.nix). No login, so never add it to the public tunnel.
#
# Config: one YAML file, rendered by op-secrets from the 1Password item
# `conductor` (fields ha_token, rail_api_key, tfl_app_key) to
# /var/lib/secrets/conductor.yaml, 0600 owned by conductor. The template is
# deploy/polaris.config.yaml.tpl in the conductor repo (private: it describes
# the house), taken from the pinned input, so a config change ships with a
# conductor release. After changing a secret in 1Password, `make switch` and
# then `sudo systemctl restart conductor`.
#
# Postgres: a tenant of the shared cluster (postgresql.nix). createLocally adds
# the `conductor` database owned by the `conductor` role (ensureDBOwnership,
# needed on PG >= 15 for the migrations); conductor connects over the unix
# socket with peer auth. The command log is best effort: conductor keeps
# working while Postgres is down.
{ conductorSrc, ... }:
let
  template = "${conductorSrc}/deploy/polaris.config.yaml.tpl";
in
{
  opSecrets.conductor-config = {
    inherit template;
    path = "/var/lib/secrets/conductor.yaml";
    owner = "conductor";
  };

  services.conductor = {
    enable = true;
    configFile = "/var/lib/secrets/conductor.yaml";
    database.createLocally = true;
  };

  # Restart when the template's content changes. The content, not the path:
  # the path is the whole conductor source, which changes with every commit.
  systemd.services.conductor.restartTriggers = [
    (builtins.hashFile "sha256" template)
  ];
}

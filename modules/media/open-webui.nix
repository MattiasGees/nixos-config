# Open WebUI — chat frontend for the local Ollama (ollama.nix), at
# https://chat.polaris.mattiasgees.be via Caddy.
#
# ⚠️ Port 3001, NOT the module default 8080 (miniflux owns 8080). Binds
# 127.0.0.1 (default), no firewall hole — Caddy is the only ingress.
#
# Setting `environment` REPLACES the module default (which only holds the
# telemetry-off flags) rather than merging, so those are restated below.
#
# Auth: the first account registered becomes admin; sign up once, then
# restrict signups in the admin panel if desired.
#
# State (SQLite) stays at the default /var/lib/open-webui on the OS disk:
# deliberately not in the shared Postgres and NOT backed up (outside restic's
# paths). Revisit if this grows into a real multi-user setup.
{ ... }:
{
  services.open-webui = {
    enable = true;
    port = 3001;
    environment = {
      OLLAMA_BASE_URL = "http://127.0.0.1:11434";
      # Restated module defaults (see header).
      ANONYMIZED_TELEMETRY = "False";
      DO_NOT_TRACK = "True";
      SCARF_NO_ANALYTICS = "True";
    };
  };
}

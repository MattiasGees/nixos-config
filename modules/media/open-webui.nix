# Open WebUI — ChatGPT-style web frontend for the local Ollama (ollama.nix).
# Reached at https://chat.polaris.mattiasgees.be via Caddy (caddy.nix).
#
# ⚠️ Port 3001, NOT the module default 8080 — miniflux already owns 8080 in
# caddy.nix, so leaving the default would collide. Binds 127.0.0.1 (module
# default): Caddy is the only ingress, no firewall hole (openFirewall stays
# false). Same posture as every other app on this box.
#
# Talks to Ollama over localhost:11434. The module's default `environment` only
# sets telemetry-off flags, and assigning `environment` REPLACES that default
# (attrset definitions don't deep-merge with an option default), so the
# telemetry keys are restated here alongside OLLAMA_BASE_URL.
#
# Auth: Open WebUI defaults to WEBUI_AUTH=on — the first account registered
# becomes the admin. That's fine behind Caddy + the tailnet; sign up once, then
# tighten signups from the admin panel if desired.
#
# State (SQLite user/chat DB) stays at the default /var/lib/open-webui on the OS
# disk — low-value, single-household, self-contained. Deliberately NOT wired
# into the shared Postgres and NOT backed up (it lives outside /srv, so restic
# never sees it). Revisit both if this ever grows into a real multi-user setup.
{ ... }:
{
  services.open-webui = {
    enable = true;
    port = 3001;
    environment = {
      # Point the UI at the local Ollama daemon.
      OLLAMA_BASE_URL = "http://127.0.0.1:11434";
      # Restated module defaults (see header — assignment replaces, not merges).
      ANONYMIZED_TELEMETRY = "False";
      DO_NOT_TRACK = "True";
      SCARF_NO_ANALYTICS = "True";
    };
  };
}

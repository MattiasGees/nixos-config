# cloudflared — Cloudflare Tunnel infra for exposing a polaris service to the
# *public* internet from behind CGNAT, without a port-forward. Complements
# tailscale.nix: Tailscale reaches polaris privately over the tailnet; a
# Cloudflare tunnel makes a chosen host public, with Cloudflare terminating TLS
# at the edge, so no inbound port and no cert on polaris.
#
# One named tunnel for the whole host ("polaris"). The `ingress` map below is the
# central, git-committed routing table — the cloudflared equivalent of caddy.nix's
# virtualHosts list: every public service adds one line here plus one
# `cloudflared tunnel route dns` record, nothing else. First service: Seerr
# (media requests) at requests.gees.dev.
#
# Out-of-band bootstrap (once, documented in docs/polaris/setup.md §4):
#   1. `cloudflared tunnel create polaris`  — prints the tunnel UUID + writes the
#      credentials JSON. Put the UUID in `tunnelId` below; store the credentials
#      JSON in op://polaris/cloudflared-polaris/credentials-json.
#   2. `cloudflared tunnel route dns polaris requests.gees.dev`  — CNAME per host.
#
# The credentials JSON is rendered by op-secrets to /var/lib/secrets. The upstream
# module runs each tunnel as a **DynamicUser** service (there is no static
# `cloudflared` user) and hands the file to systemd `LoadCredential`, which reads
# it as **root** at start and copies it into the unit's private /run/credentials.
# So the rendered file is owned root:root 0600 (a `cloudflared` owner would fail
# op-secrets' chown — no such user — and root can read it for LoadCredential).
{ ... }:
let
  # The polaris tunnel's ID from `cloudflared tunnel create polaris` (see header /
  # docs/polaris/setup.md §4). Not a secret — it's public in the
  # <id>.cfargotunnel.com hostname; the secret is the credentials JSON.
  tunnelId = "36de13f7-382b-4562-ac1c-15b521aef569";
in
{
  opSecrets.cloudflared-polaris = {
    template = ./cloudflared-polaris.json.tpl;
    path = "/var/lib/secrets/cloudflared-polaris.json";
    # DynamicUser tunnel: LoadCredential reads this as root (see header).
    owner = "root";
  };

  services.cloudflared = {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = "/var/lib/secrets/cloudflared-polaris.json";
      default = "http_status:404";
      # Central public-ingress map — add one line per new public service.
      ingress = {
        "requests.gees.dev" = "http://localhost:5055"; # Seerr (media/seerr.nix)
      };
    };
  };
}

# cloudflared — Cloudflare Tunnel exposing chosen polaris services to the
# *public* internet from behind CGNAT: no port-forward, no inbound port, and
# Cloudflare terminates TLS at the edge. (tailscale.nix is the private path.)
#
# One named tunnel ("polaris") for the whole host. `ingress` below is the
# public routing table — the counterpart of caddy.nix's virtualHosts: each
# public service adds one line here plus one `cloudflared tunnel route dns`.
#
# Out-of-band bootstrap (once; see docs/polaris/setup.md §4 and the Cloudflare
# Tunnel service doc in the Homecluster/NixOS wiki):
#   1. `cloudflared tunnel create polaris` — prints the tunnel UUID (→ `tunnelId`)
#      and writes the credentials JSON (→ op://polaris/cloudflared-polaris/...).
#   2. `cloudflared tunnel route dns polaris <host>` — one CNAME per host.
#
# Credentials owner is root: the upstream module runs each tunnel as a
# DynamicUser (no static `cloudflared` user, so op-secrets' chown to one would
# fail) and passes the file via LoadCredential, which systemd reads as root.
{ ... }:
let
  # Not a secret — it's public in the <id>.cfargotunnel.com hostname; the
  # secret is the credentials JSON.
  tunnelId = "36de13f7-382b-4562-ac1c-15b521aef569";
in
{
  opSecrets.cloudflared-polaris = {
    template = ./cloudflared-polaris.json.tpl;
    path = "/var/lib/secrets/cloudflared-polaris.json";
    # See header: DynamicUser + LoadCredential.
    owner = "root";
  };

  services.cloudflared = {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = "/var/lib/secrets/cloudflared-polaris.json";
      default = "http_status:404";
      ingress = {
        "requests.gees.dev" = "http://localhost:5055"; # Seerr (media/seerr.nix)
        "wiki.gees.dev"     = "http://localhost:3002"; # Outline (services/outline.nix)
      };
    };
  };
}

# Reverse proxy for the *arr stack, with automatic TLS via ACME DNS-01 on
# Route53. Polaris is behind CGNAT so HTTP-01 can't work; DNS-01 doesn't
# require inbound access from the CA. Listens on all interfaces, reachable
# on the LAN and the tailnet (wildcard *.polaris.mattiasgees.be -> tailnet
# IP, set up out-of-band in Route53).
{ pkgs, lib, ... }:
let
  # Per-site TLS using the Route53 DNS-01 challenge.
  #
  # Why the custom resolvers + delay: polaris resolves DNS only through the LAN
  # router, and the mattiasgees.be zone has Route53's default 24h SOA negative
  # TTL. A lookup of _acme-challenge.<app> before the record exists poisons the
  # router's cache with NXDOMAIN for 24h, so certmagic's propagation check never
  # sees the record it just created ("timed out ... last error: <nil>"). Point
  # the check at fresh public resolvers (which never cached that NXDOMAIN) and
  # give Route53 a moment to settle, bypassing the router cache entirely.
  acmeTls = ''
    tls {
      dns route53
      resolvers 1.1.1.1 8.8.8.8
      propagation_delay 30s
      propagation_timeout 5m
    }
  '';
  proxy = port: ''
    reverse_proxy localhost:${toString port}
    ${acmeTls}
  '';
in
{
  services.caddy = {
    enable = true;
    # Caddy built with the Route53 DNS plugin. v1.6.2+ targets libdns v1 (matches
    # Caddy 2.11); older tags (e.g. v1.5.0) use the old struct API and fail to
    # compile with "invalid composite literal type libdns.Record".
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/caddy-dns/route53@v1.6.2" ];
      # FOD hash of the Caddy source with the route53 plugin vendored. Emitted by
      # the first build (with lib.fakeHash) as "got: sha256-...". Bumping the
      # plugin/Caddy version invalidates this — reset to lib.fakeHash to re-derive.
      hash = "sha256-/9c9b+S98V+eDj6mzb6KfAWWSBCrZoUzA1JDrMxuKQ0=";
    };
    # ACME account email (was in globalConfig alongside acme_dns; the DNS
    # challenge now lives per-site in the tls block so it can set resolvers).
    email = "mattias@gees.dev";
    virtualHosts."sonarr.polaris.mattiasgees.be".extraConfig = proxy 8989;
    virtualHosts."radarr.polaris.mattiasgees.be".extraConfig = proxy 7878;
    virtualHosts."prowlarr.polaris.mattiasgees.be".extraConfig = proxy 9696;
    virtualHosts."bazarr.polaris.mattiasgees.be".extraConfig = proxy 6767;
    virtualHosts."seerr.polaris.mattiasgees.be".extraConfig = proxy 5055;
    virtualHosts."immich.polaris.mattiasgees.be".extraConfig = proxy 2283;
    virtualHosts."miniflux.polaris.mattiasgees.be".extraConfig = proxy 8080;
    virtualHosts."karakeep.polaris.mattiasgees.be".extraConfig = proxy 3000;
    # Open WebUI (open-webui.nix) — chat frontend for local Ollama. Port 3001,
    # not 8080, to avoid the miniflux collision above.
    virtualHosts."chat.polaris.mattiasgees.be".extraConfig = proxy 3001;
    # Pi-hole (pihole.nix) — DNS ad-blocker admin UI. Its web server is moved to
    # :8081 (FTLCONF_webserver_port) so it doesn't collide with Caddy's :80/:443.
    virtualHosts."pihole.polaris.mattiasgees.be".extraConfig = proxy 8081;
    # Outline wiki (outline.nix) — tailnet front door. Also public at wiki.gees.dev
    # via the shared Cloudflare tunnel (cloudflared.nix). Port 3002 (3000/3001
    # taken by karakeep/open-webui).
    virtualHosts."wiki.polaris.mattiasgees.be".extraConfig = proxy 3002;
  };

  # AWS creds for Route53 (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_DEFAULT_REGION),
  # rendered from op://polaris/caddy-route53/* by op-secrets (modules/server/op-secrets.nix)
  # at deploy time, kept out of git.
  opSecrets.caddy-route53 = {
    template = ./caddy.route53.env.tpl;
    path = "/var/lib/secrets/caddy-route53.env";
    owner = "caddy";
  };
  systemd.services.caddy.serviceConfig.EnvironmentFile = "/var/lib/secrets/caddy-route53.env";

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}

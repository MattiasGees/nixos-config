# Reverse proxy for every polaris web app, with automatic TLS via ACME DNS-01
# on Route53 (behind CGNAT, so HTTP-01 can't work). Listens on all interfaces,
# reachable on the LAN and the tailnet (wildcard *.polaris.mattiasgees.be ->
# tailnet IP, set up out-of-band in Route53). Public exposure is separate:
# see modules/server/cloudflared.nix.
{ pkgs, lib, ... }:
let
  # Per-site TLS using the Route53 DNS-01 challenge.
  #
  # Why the custom resolvers + delay: the mattiasgees.be zone has Route53's
  # default 24h SOA negative TTL, so a lookup of _acme-challenge.<app> before
  # the record exists poisons the LAN resolver's cache with NXDOMAIN for 24h and
  # certmagic's propagation check never sees the new record ("timed out ...
  # last error: <nil>"). Checking against public resolvers bypasses that cache;
  # the delay lets Route53 settle.
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
    # Route53 DNS plugin. Needs v1.6.2+ (libdns v1, matching Caddy 2.11); older
    # tags fail with "invalid composite literal type libdns.Record".
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/caddy-dns/route53@v1.6.2" ];
      # FOD hash of Caddy + vendored plugin. Bumping either invalidates it:
      # set lib.fakeHash, build, and copy the "got: sha256-..." value.
      hash = "sha256-Vzp4Y9mARJrAHZ1C3x6+5zTSGiYY1l3FxIPkqK1RI30=";
    };
    # ACME account email. The DNS challenge is per-site (acmeTls) rather than a
    # global acme_dns, because only the per-site tls block can set resolvers.
    email = "mattias@gees.dev";
    virtualHosts."sonarr.polaris.mattiasgees.be".extraConfig = proxy 8989;
    virtualHosts."radarr.polaris.mattiasgees.be".extraConfig = proxy 7878;
    virtualHosts."prowlarr.polaris.mattiasgees.be".extraConfig = proxy 9696;
    virtualHosts."bazarr.polaris.mattiasgees.be".extraConfig = proxy 6767;
    virtualHosts."seerr.polaris.mattiasgees.be".extraConfig = proxy 5055;
    virtualHosts."immich.polaris.mattiasgees.be".extraConfig = proxy 2283;
    virtualHosts."miniflux.polaris.mattiasgees.be".extraConfig = proxy 8080;
    virtualHosts."karakeep.polaris.mattiasgees.be".extraConfig = proxy 3000;
    # Open WebUI (open-webui.nix).
    virtualHosts."chat.polaris.mattiasgees.be".extraConfig = proxy 3001;
    # Pi-hole admin UI (pihole.nix), moved off :80/:443 to :8081.
    virtualHosts."pihole.polaris.mattiasgees.be".extraConfig = proxy 8081;
    # Outline (outline.nix); also public at wiki.gees.dev via cloudflared.nix.
    virtualHosts."wiki.polaris.mattiasgees.be".extraConfig = proxy 3002;
    # Filebrowser (filebrowser.nix); LAN/tailnet only, no public tunnel.
    virtualHosts."files.polaris.mattiasgees.be".extraConfig = proxy 8083;
    # conductor (services/conductor.nix): the home dashboard, its WebSocket and
    # /metrics. It has no login and controls the house, so only LAN and tailnet
    # clients (private ranges, Tailscale's 100.64.0.0/10 and fd7a:115c:a1e0::/48)
    # get through; anything else gets a 403. Never on the public tunnel.
    virtualHosts."conductor.polaris.mattiasgees.be".extraConfig = ''
      @outside not remote_ip private_ranges 100.64.0.0/10 fd7a:115c:a1e0::/48
      respond @outside 403
      ${proxy 8420}
    '';
  };

  # Route53 AWS credentials, rendered from op://polaris/caddy-route53/* by
  # op-secrets.
  opSecrets.caddy-route53 = {
    template = ./caddy.route53.env.tpl;
    path = "/var/lib/secrets/caddy-route53.env";
    owner = "caddy";
  };
  systemd.services.caddy.serviceConfig.EnvironmentFile = "/var/lib/secrets/caddy-route53.env";

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}

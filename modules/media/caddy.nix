# Reverse proxy for the *arr stack, with automatic TLS via ACME DNS-01 on
# Route53. Polaris is behind CGNAT so HTTP-01 can't work; DNS-01 doesn't
# require inbound access from the CA. Listens on all interfaces, reachable
# on the LAN and the tailnet (wildcard *.polaris.mattiasgees.be -> tailnet
# IP, set up out-of-band in Route53).
{ pkgs, lib, ... }:
{
  services.caddy = {
    enable = true;
    # Caddy built with the Route53 DNS plugin for the ACME DNS-01 challenge
    # (polaris is behind CGNAT, so HTTP-01 can't work).
    package = pkgs.caddy.withPlugins {
      plugins = [ "github.com/caddy-dns/route53@v1.5.0" ];
      # BUILD-TIME: replace with the hash the first build prints (use lib.fakeHash
      # so the error reports the correct sha256 to paste here).
      hash = lib.fakeHash;
    };
    globalConfig = ''
      acme_dns route53
      email mattias@gees.dev
    '';
    virtualHosts."sonarr.polaris.mattiasgees.be".extraConfig = "reverse_proxy localhost:8989";
    virtualHosts."radarr.polaris.mattiasgees.be".extraConfig = "reverse_proxy localhost:7878";
    virtualHosts."prowlarr.polaris.mattiasgees.be".extraConfig = "reverse_proxy localhost:9696";
  };

  # AWS creds for Route53 (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION),
  # placed by hand at /etc/caddy/route53.env (0600), kept out of git.
  systemd.services.caddy.serviceConfig.EnvironmentFile = "/etc/caddy/route53.env";

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}

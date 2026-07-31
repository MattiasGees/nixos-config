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
      # FOD hash of the Caddy source with the route53 plugin vendored. Emitted by
      # the first build (with lib.fakeHash) as "got: sha256-...". Bumping the
      # plugin/Caddy version invalidates this — reset to lib.fakeHash to re-derive.
      hash = "sha256-ufH4svaXadboK4OimfcYxwe0vaPtcukhHEH5kuWf7ZA=";
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

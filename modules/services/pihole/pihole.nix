# Pi-hole — LAN-wide ad-blocking DNS on polaris, a redundant HA *secondary* to
# the Raspberry Pi Pi-hole (192.168.1.86, which stays primary). Mirrors the Pi's
# Ansible roles (roles/pihole + roles/dnsproxy): Pi-hole forwards to a local
# dnsproxy DoH forwarder so upstream resolution leaves over 443 (DoH) instead of
# plaintext :53, which the ISP transparently intercepts.
#
# Pi-hole is not packaged in nixpkgs (it's an FTL + lighttpd + PHP installer
# bundle), so it runs as a container via virtualisation.oci-containers on the
# Docker backend modules/server/virtualisation.nix already enables.
#
# Networking: BOTH containers use host networking, exactly like the Pi. A Docker
# bridge would SNAT inbound queries to the docker0 gateway, so Pi-hole would log
# every LAN client as 172.x.0.1 and lose per-client stats/rules — the well-known
# Pi-hole-in-Docker caveat. Host networking preserves real client IPs. The only
# wrinkle vs the Pi is that Caddy already owns :80/:443 here, so Pi-hole's web UI
# moves to :8081 (FTLCONF_webserver_port) and is fronted by Caddy for TLS.
#
# NOT declarative: adlists + custom DNS records live in the persisted gravity DB
# (/var/lib/pihole/pihole), added via the UI — same as the Pi (they were never in
# the Ansible repo either). Only the DoH upstreams, forwarder wiring and admin
# password are declared here.
#
# Secret: the web/API admin password is rendered from op://polaris/pihole by
# op-secrets to /var/lib/secrets/pihole.env and fed in as an env-file. Reuses the
# Pi's existing password value.
{ ... }:
let
  # DoH upstreams, mirrored from roles/dnsproxy: Cloudflare + Google, IP-literal
  # endpoints so dnsproxy has no hostname to resolve before DNS is up.
  dohUpstreams = [
    "https://1.1.1.1/dns-query"
    "https://1.0.0.1/dns-query"
    "https://8.8.8.8/dns-query"
    "https://8.8.4.4/dns-query"
  ];
in
{
  opSecrets.pihole = {
    template = ./pihole.env.tpl;
    path = "/var/lib/secrets/pihole.env";
    owner = "root";
  };

  # Docker, not the NixOS-default podman — matches virtualisation.docker.enable
  # in modules/server/virtualisation.nix. polaris is the only oci-containers user.
  virtualisation.oci-containers.backend = "docker";

  virtualisation.oci-containers.containers = {
    # DoH forwarder. Loopback-only bind (:5053) — Pi-hole reaches it via the
    # shared host net namespace; the LAN never sees it.
    dnsproxy = {
      image = "adguard/dnsproxy:v0.84.0";
      cmd = [ "--listen" "127.0.0.1" "--port" "5053" ]
        ++ map (u: "--upstream=${u}") dohUpstreams;
      extraOptions = [ "--network=host" ];
    };

    # Pi-hole resolver + web UI. Host networking → binds :53 directly and sees
    # real client IPs. Upstream is the local DoH forwarder above.
    pihole = {
      image = "pihole/pihole:2026.02.0";
      dependsOn = [ "dnsproxy" ];
      environment = {
        TZ = "UTC";
        FTLCONF_dns_upstreams = "127.0.0.1#5053";
        # Move the web server off :80/:443 (Caddy owns those). `o` = optional
        # bind; both stacks so Caddy's `localhost` (v4 or v6) reaches it. No TLS
        # port bound here — Caddy terminates TLS.
        FTLCONF_webserver_port = "8081o,[::]:8081o";
      };
      environmentFiles = [ "/var/lib/secrets/pihole.env" ];
      volumes = [
        "/var/lib/pihole/pihole:/etc/pihole"
        "/var/lib/pihole/dnsmasq.d:/etc/dnsmasq.d"
      ];
      extraOptions = [ "--network=host" ];
    };
  };

  # Persisted state dirs (gravity DB + dnsmasq config). Docker would auto-create
  # the bind-mount sources, but declaring them keeps it reproducible and in-repo
  # (same pattern as plex.nix/immich.nix).
  systemd.tmpfiles.rules = [
    "d /var/lib/pihole 0755 root root - -"
    "d /var/lib/pihole/pihole 0755 root root - -"
    "d /var/lib/pihole/dnsmasq.d 0755 root root - -"
  ];

  # LAN clients query polaris on :53. The UI (:8081) stays closed — only Caddy
  # (:443, already open) reaches it.
  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];
}

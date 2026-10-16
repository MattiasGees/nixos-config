# Prometheus exporters for polaris, scraped by the k8s cluster's Prometheus
# over Tailscale egress (k8s-config: config/bases/polaris, which also holds the
# alert rules).
#
# - node_exporter :9100: host metrics and systemd state. Backup monitoring
#   uses node_systemd_unit_state (failed runs, via the default
#   NodeSystemdServiceFailed alert) and node_systemd_timer_last_trigger_seconds
#   (runs that stop happening). The backup timers are Persistent, so the last
#   trigger survives a reboot.
# - restic exporter :9753: snapshot age/count/size read from the Hetzner repo
#   every 6h, an independent check that backups actually land offsite.
# - zfs exporter :9134: pool size/allocation/fragmentation/health and dataset
#   usage. node_exporter already has pool state, but not how full a pool is.
# - smartctl exporter :9633: SMART health, temperatures, wear and error
#   counters for the two NVMe and three HDD disks (autodiscovered).
# - pihole exporter :9617: stats for the Pi-hole in services/pihole, the same
#   exporter as the Raspberry Pi's, so one dashboard and rule set covers both.
# - blackbox exporter :9115: probes run *from* polaris, because the cluster
#   can't resolve or reach the LAN/tailnet-only *.polaris.mattiasgees.be names
#   or the Pi-holes' LAN addresses. The targets are k8s-config Probe resources;
#   only the modules are defined here.
# - Caddy :9180 (media/caddy.nix): per-site request metrics.
#
# The exporters listen on all interfaces; the firewall is what isolates them:
# the ports are open on tailscale0 only, not on the LAN, not behind Caddy.
# Overview of what is and isn't monitored: the Observability page in the
# Homecluster/NixOS wiki (Documentation).
{ config, lib, pkgs, ... }:
let
  # Blackbox modules, referenced by name from k8s-config Probes.
  blackboxConfig = {
    modules = {
      # App health endpoints behind Caddy. Follows redirects (Pi-hole's
      # /admin/ redirects to its login page); TLS expiry comes for free.
      http_2xx = {
        prober = "http";
        timeout = "5s";
        http.preferred_ip_protocol = "ip4";
      };
      # A Pi-hole resolves a normal name through its DoH upstream.
      dns_resolve = {
        prober = "dns";
        timeout = "5s";
        dns = {
          preferred_ip_protocol = "ip4";
          query_name = "google.com";
          query_type = "A";
          valid_rcodes = [ "NOERROR" ];
          validate_answer_rrs.fail_if_none_matches_regexp = [ ".*\\tIN\\tA\\t.*" ];
        };
      };
      # A Pi-hole blocks a known ad domain (answers 0.0.0.0).
      dns_blocked = {
        prober = "dns";
        timeout = "5s";
        dns = {
          preferred_ip_protocol = "ip4";
          query_name = "doubleclick.net";
          query_type = "A";
          valid_rcodes = [ "NOERROR" ];
          validate_answer_rrs.fail_if_none_matches_regexp = [ ".*\\tIN\\tA\\t0\\.0\\.0\\.0$" ];
        };
      };
    };
  };
in
{
  services.prometheus.exporters.node = {
    enable = true;
    port = 9100; # k8s-config ScrapeConfig polaris-node-exporter
    enabledCollectors = [ "systemd" ];
  };

  services.prometheus.exporters.restic = {
    enable = true;
    port = 9753; # k8s-config ScrapeConfig polaris-restic
    inherit (config.services.restic.backups.polaris) repository passwordFile environmentFile;
    refreshInterval = 6 * 3600;
  };
  # restic-exporter reads its switches as bool(os.environ.get(...)): any
  # non-empty value, even "False", means true. Unset a switch to turn it off.
  # NO_CHECK: `restic check` reads all repo metadata from S3 on every refresh.
  # NO_STATS stays unset (stats on) unless refreshes turn out slow.
  systemd.services.prometheus-restic-exporter = {
    environment.NO_CHECK = "1";
    # The upstream module sets this to "$CACHE_DIRECTORY", which systemd doesn't
    # expand, so the cache would land in a literal relative path lost on restart.
    environment.RESTIC_CACHE_DIR = lib.mkForce "/var/cache/restic-exporter";

    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # The first refresh runs at startup. If it fails (for example S3 is
    # unreachable during boot), exit so systemd retries instead of serving 500s
    # until the next 6h refresh.
    environment.EXIT_ON_ERROR = "1";
    # Default Restart=always retries every 100ms and would hit the start limit,
    # leaving a failed unit (NodeSystemdServiceFailed).
    serviceConfig.RestartSec = "1min";
  };

  services.prometheus.exporters.zfs = {
    enable = true;
    port = 9134; # k8s-config ScrapeConfig polaris-zfs
  };

  services.prometheus.exporters.smartctl = {
    enable = true;
    port = 9633; # k8s-config ScrapeConfig polaris-smartctl
  };

  # Pi-hole's web/API server is on :8081 (pihole.nix). Connecting via the LAN
  # address rather than localhost makes the exporter's `hostname` label
  # 192.168.1.50, matching the Pi's 192.168.1.86 in the shared dashboard.
  services.prometheus.exporters.pihole = {
    enable = true;
    port = 9617; # k8s-config ScrapeConfig polaris-pihole
    piholeHostname = "192.168.1.50";
    piholePort = 8081;
  };
  # The module's `password` option would put the password on the command line
  # and in the world-readable store; the exporter also reads PIHOLE_PASSWORD
  # from the environment, so pass it via an op-secrets env file instead.
  opSecrets.pihole-exporter = {
    template = ./pihole-exporter.env.tpl;
    path = "/var/lib/secrets/pihole-exporter.env";
    owner = "root";
  };
  systemd.services.prometheus-pihole-exporter = {
    serviceConfig.EnvironmentFile = "/var/lib/secrets/pihole-exporter.env";
    after = [ "docker-pihole.service" ];
  };

  services.prometheus.exporters.blackbox = {
    enable = true;
    port = 9115; # prober for the k8s-config Probes polaris-http, pihole-dns, pihole-blocking
    configFile = pkgs.writeText "blackbox.json" (builtins.toJSON blackboxConfig);
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    config.services.prometheus.exporters.node.port
    config.services.prometheus.exporters.restic.port
    config.services.prometheus.exporters.zfs.port
    config.services.prometheus.exporters.smartctl.port
    config.services.prometheus.exporters.pihole.port
    config.services.prometheus.exporters.blackbox.port
  ];
}

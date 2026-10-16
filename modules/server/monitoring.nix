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
# - Caddy :9180 (media/caddy.nix): per-site request metrics.
# - exportarr :9707 sonarr, :9708 radarr, :9710 prowlarr, :9712 bazarr: library,
#   queue, health-check and indexer stats from each app's API.
# - postgres exporter :9187: the shared PostgreSQL cluster (postgresql.nix).
# - App metrics enabled in the apps' own modules: Immich :9283/:9284
#   (media/immich.nix), cloudflared :9181 (cloudflared.nix), the GPU :9835
#   (nvidia.nix), and Miniflux and Karakeep through Caddy's :9180 listener
#   (services/miniflux.nix, services/karakeep.nix).
#
# The exporters listen on all interfaces; the firewall is what isolates them:
# the ports are open on tailscale0 only, not on the LAN, not behind Caddy.
# Overview of what is and isn't monitored: the Observability page in the
# Homecluster/NixOS wiki (Documentation).
{ config, lib, pkgs, ... }:
let
  # exportarr reads ApiKey and Port from an *arr config.xml given as a systemd
  # credential (see the exportarr block below).
  arrConfigXml = path: {
    environment.CONFIG = "%d/config.xml";
    serviceConfig.LoadCredential = lib.mkForce "config.xml:${path}";
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

  # exportarr needs each app's API key. None of them is in 1Password, so read
  # them from the apps' own config instead of keeping a copy: Sonarr, Radarr
  # and Prowlarr via their config.xml (arrConfigXml), handed over as a systemd
  # credential because the exporters run as a DynamicUser that can't read the
  # app's data dir.
  # The URLs carry the module's port too: exportarr only takes the port from
  # config.xml when the file has one.
  services.prometheus.exporters.exportarr-sonarr = {
    enable = true;
    port = 9707;
    url = "http://127.0.0.1:${toString config.services.sonarr.settings.server.port}";
  };
  services.prometheus.exporters.exportarr-radarr = {
    enable = true;
    port = 9708;
    url = "http://127.0.0.1:${toString config.services.radarr.settings.server.port}";
  };
  services.prometheus.exporters.exportarr-prowlarr = {
    enable = true;
    port = 9710;
    url = "http://127.0.0.1:${toString config.services.prowlarr.settings.server.port}";
  };
  services.prometheus.exporters.exportarr-bazarr = {
    enable = true;
    port = 9712;
    url = "http://127.0.0.1:${toString config.services.bazarr.settings.general.port}";
  };

  systemd.services.prometheus-exportarr-sonarr-exporter =
    arrConfigXml "${config.services.sonarr.dataDir}/config.xml";
  systemd.services.prometheus-exportarr-radarr-exporter =
    arrConfigXml "${config.services.radarr.dataDir}/config.xml";
  # DynamicUser + StateDirectory: the real path is under /var/lib/private.
  systemd.services.prometheus-exportarr-prowlarr-exporter =
    arrConfigXml "/var/lib/private/prowlarr/config.xml";
  # Bazarr keeps its key in YAML, which exportarr can't parse: copy it into the
  # exporter's private runtime dir (0700, owned by the DynamicUser) as root
  # before start. Exporters run with UMask 0077, so the file comes out
  # root-only: hand it to the runtime dir's owner, the DynamicUser.
  systemd.services.prometheus-exportarr-bazarr-exporter = {
    environment.API_KEY_FILE = "/run/exportarr-bazarr/api-key";
    serviceConfig = {
      RuntimeDirectory = "exportarr-bazarr";
      RuntimeDirectoryMode = "0700";
      ExecStartPre = "+" + pkgs.writeShellScript "exportarr-bazarr-api-key" ''
        set -euo pipefail
        ${pkgs.yq-go}/bin/yq '.auth.apikey' ${config.services.bazarr.dataDir}/config/config.yaml \
          > /run/exportarr-bazarr/api-key
        chown --reference=/run/exportarr-bazarr /run/exportarr-bazarr/api-key
      '';
    };
  };

  services.prometheus.exporters.postgres = {
    enable = true;
    port = 9187; # k8s-config ScrapeConfig polaris-postgres
    # Peer auth over the socket as the postgres OS user; no password needed.
    runAsLocalSuperUser = true;
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    config.services.prometheus.exporters.node.port
    config.services.prometheus.exporters.restic.port
    config.services.prometheus.exporters.zfs.port
    config.services.prometheus.exporters.smartctl.port
    config.services.prometheus.exporters.pihole.port
    config.services.prometheus.exporters.exportarr-sonarr.port
    config.services.prometheus.exporters.exportarr-radarr.port
    config.services.prometheus.exporters.exportarr-prowlarr.port
    config.services.prometheus.exporters.exportarr-bazarr.port
    config.services.prometheus.exporters.postgres.port
  ];
}

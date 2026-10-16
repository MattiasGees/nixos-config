# Prometheus exporters for polaris, scraped by the k8s cluster's Prometheus
# over Tailscale egress (k8s-config: config/bases/polaris, which also holds the
# alert rules and the "Polaris backups" Grafana dashboard).
#
# - node_exporter :9100: host metrics, systemd unit state (feeds the default
#   NodeSystemdServiceFailed alert) and the backup textfile metrics below.
# - restic exporter :9753: snapshot age/count/size read from the Hetzner repo
#   every 6h, an independent check that backups actually land offsite.
#
# Both exporters listen on all interfaces; the firewall is what isolates them:
# the ports are open on tailscale0 only, not on the LAN, not behind Caddy.
{ config, lib, ... }:
let
  day = 24 * 3600;
in
{
  imports = [ ./backup-metrics ];

  # Backup units whose last success is tracked, and how old that success may
  # get before PolarisBackupStale fires. Keep in sync with the stat thresholds
  # in k8s-config's config/bases/polaris/dashboard.yaml, whose "Unit state" and
  # "Runs" panels also list these unit names in a regex.
  polaris.backupMetrics.units = {
    restic-backups-polaris.maxAge = day + 2 * 3600; # daily 03:00 (restic.nix)
    postgresqlBackup.maxAge = day + 2 * 3600; # daily 02:30 (postgresql.nix)
    karakeep-sqlite-backup.maxAge = day + 2 * 3600; # daily 02:45 (karakeep.nix)
    polaris-data-nfs-sync.maxAge = day + 3600; # every 12h; tolerates one missed run
  };

  services.prometheus.exporters.node = {
    enable = true;
    port = 9100; # k8s-config ScrapeConfig polaris-node-exporter
    enabledCollectors = [ "systemd" ];
    extraFlags = [ "--collector.textfile.directory=${config.polaris.backupMetrics.textfileDir}" ];
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

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    config.services.prometheus.exporters.node.port
    config.services.prometheus.exporters.restic.port
  ];
}

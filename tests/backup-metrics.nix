# VM test: polaris.backupMetrics records success metrics for backup units and
# node_exporter serves them. Needs x86_64-linux with KVM; run on polaris:
#   nix build .#checks.x86_64-linux.backup-metrics --impure -L
{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "backup-metrics";
  nodes.machine = { ... }: {
    imports = [ ../modules/server/backup-metrics ];
    services.prometheus.exporters.node = {
      enable = true;
      enabledCollectors = [ "systemd" ];
      extraFlags = [ "--collector.textfile.directory=/var/lib/prometheus-node-exporter-text-files" ];
    };
    polaris.backupMetrics.units = {
      ok-root.maxAge = 100;
      ok-nonroot.maxAge = 200;
      broken.maxAge = 300;
    };
    systemd.services.ok-root.serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.coreutils}/bin/sleep 2";
    };
    # Like postgresqlBackup/karakeep: not root, so ExecStartPost needs "+".
    systemd.services.ok-nonroot.serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
    };
    systemd.services.broken.serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.coreutils}/bin/false";
    };
    environment.systemPackages = [ pkgs.curl ];
  };
  testScript = ''
    import re

    machine.wait_for_unit("prometheus-node-exporter.service")
    machine.wait_for_open_port(9100)

    machine.succeed("systemctl start ok-root.service ok-nonroot.service")
    machine.fail("systemctl start broken.service")

    m = machine.succeed("curl -sf localhost:9100/metrics")
    print(m)

    # Expectations are published for every unit, including the broken one.
    for unit, age in [("ok-root", 100), ("ok-nonroot", 200), ("broken", 300)]:
        assert f'polaris_backup_max_age_seconds{{unit="{unit}"}} {age}' in m, unit

    # Success metrics only for units whose ExecStart succeeded.
    assert 'polaris_backup_last_success_timestamp_seconds{unit="ok-root"}' in m
    assert 'polaris_backup_last_success_timestamp_seconds{unit="ok-nonroot"}' in m
    assert 'polaris_backup_last_success_timestamp_seconds{unit="broken"}' not in m

    # Duration covers ExecStart (ok-root sleeps 2s).
    d = re.search(r'polaris_backup_last_duration_seconds\{unit="ok-root"\} (\d+)', m)
    assert d and int(d.group(1)) >= 2, d

    # The same metric in several files must not break the collector.
    assert "node_textfile_scrape_error 0" in m

    # The systemd collector reports the failed unit (feeds NodeSystemdServiceFailed).
    assert re.search(r'node_systemd_unit_state\{name="broken.service",state="failed"[^}]*\} 1', m)
  '';
}

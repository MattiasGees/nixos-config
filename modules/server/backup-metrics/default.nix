# Backup "last success" metrics for node_exporter's textfile collector. For
# each unit in polaris.backupMetrics.units:
#   - an ExecStartPost writes <unit>.prom (success time + run duration);
#     systemd only runs it after ExecStart succeeded;
#   - polaris-backup-expected.prom publishes the unit's max age, so the alert
#     rules in k8s-config (config/bases/polaris) stay generic over `unit`.
# Unit names are given without ".service".
{ config, lib, pkgs, ... }:
let
  cfg = config.polaris.backupMetrics;
  script = pkgs.callPackage ./script.nix { };
  expected = pkgs.writeText "polaris-backup-expected.prom" (''
    # HELP polaris_backup_max_age_seconds Maximum age of a backup unit's last successful run before it counts as stale.
    # TYPE polaris_backup_max_age_seconds gauge
  '' + lib.concatStrings (lib.mapAttrsToList (unit: u: ''
    polaris_backup_max_age_seconds{unit="${unit}"} ${toString u.maxAge}
  '') cfg.units));
in
{
  options.polaris.backupMetrics = {
    textfileDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/prometheus-node-exporter-text-files";
      description = "node_exporter textfile collector directory.";
    };
    units = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.maxAge = lib.mkOption {
          type = lib.types.ints.positive;
          description = "Seconds since the last success before the unit counts as stale.";
        };
      });
      default = { };
      description = "Backup units (names without .service) to record success metrics for.";
    };
  };

  config = lib.mkIf (cfg.units != { }) {
    # A typo'd or removed unit would otherwise become an orphan unit holding
    # only our ExecStartPost.
    assertions = lib.mapAttrsToList (unit: _: {
      assertion = config.systemd.services.${unit}.serviceConfig ? ExecStart;
      message = "polaris.backupMetrics.units.${unit}: no systemd service \"${unit}\" with an ExecStart is defined.";
    }) cfg.units;

    systemd.tmpfiles.rules = [
      "d ${cfg.textfileDir} 0755 root root - -"
      "L+ ${cfg.textfileDir}/polaris-backup-expected.prom - - - - ${expected}"
    ];

    systemd.services = lib.mapAttrs (unit: _: {
      # "+": run privileged. Some backup units run as non-root users
      # (postgres, karakeep) that can't write the textfile directory.
      serviceConfig.ExecStartPost = [ "+${script}/bin/backup-success-metrics ${unit} ${cfg.textfileDir}" ];
    }) cfg.units;
  };
}

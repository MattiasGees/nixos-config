# backup-success-metrics <unit> <textfile-dir>: record a successful run of a
# backup unit for node_exporter's textfile collector. Runs as the unit's
# ExecStartPost (see default.nix), which systemd only starts after ExecStart
# succeeded, so "ran" means "succeeded".
{ lib, stdenv, writeShellApplication, coreutils, systemd }:
writeShellApplication {
  name = "backup-success-metrics";
  # systemd is Linux-only; the macOS unit test passes a fake via SYSTEMCTL.
  runtimeInputs = [ coreutils ] ++ lib.optional stdenv.hostPlatform.isLinux systemd;
  text = ''
    if [ "$#" -ne 2 ]; then
      echo "usage: backup-success-metrics <unit> <textfile-dir>" >&2
      exit 2
    fi
    unit="$1"
    dir="$2"
    now=$(date +%s)
    # When this activation began, as "@<epoch>"; "n/a" or empty if unknown.
    start=$("''${SYSTEMCTL:-systemctl}" show -P InactiveExitTimestamp --timestamp=unix "$unit.service" || true)
    start="''${start#@}"

    # Write a dotfile without the .prom suffix (the collector ignores it), then
    # rename, so a scrape never reads a half-written file. HELP/TYPE on every
    # metric: node_exporter requires identical HELP for a metric that appears
    # in several files.
    tmp=$(mktemp "$dir/.$unit.XXXXXX")
    {
      echo "# HELP polaris_backup_last_success_timestamp_seconds Unix time of the last successful run of a backup unit."
      echo "# TYPE polaris_backup_last_success_timestamp_seconds gauge"
      echo "polaris_backup_last_success_timestamp_seconds{unit=\"$unit\"} $now"
      if [[ "$start" =~ ^[0-9]+$ ]]; then
        echo "# HELP polaris_backup_last_duration_seconds Duration of the last successful run of a backup unit."
        echo "# TYPE polaris_backup_last_duration_seconds gauge"
        echo "polaris_backup_last_duration_seconds{unit=\"$unit\"} $((now - start))"
      fi
    } > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$dir/$unit.prom"
  '';
}

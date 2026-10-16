# Unit test for the backup success-metrics script
# (modules/server/backup-metrics/script.nix): run it against a fake systemctl
# and check the .prom files it writes. Builds on Linux and macOS:
#   nix build .#checks.aarch64-darwin.backup-metrics-script --impure
{ pkgs }:
let
  script = pkgs.callPackage ../modules/server/backup-metrics/script.nix { };
  bin = "${script}/bin/backup-success-metrics";
in
pkgs.runCommand "backup-metrics-script-test" { } ''
  set -euo pipefail
  fail() { echo "FAIL: $*" >&2; exit 1; }
  mkdir textfiles
  dir="$PWD/textfiles"

  # Unit "demo" started at epoch 1000.
  printf '#!/bin/sh\necho @1000\n' > fake-systemctl
  chmod +x fake-systemctl
  SYSTEMCTL="$PWD/fake-systemctl" ${bin} demo "$dir"
  cat "$dir/demo.prom"
  grep -qE '^polaris_backup_last_success_timestamp_seconds\{unit="demo"\} [0-9]+$' "$dir/demo.prom" \
    || fail "no success timestamp"
  now=$(sed -nE 's/^polaris_backup_last_success_timestamp_seconds\{unit="demo"\} ([0-9]+)$/\1/p' "$dir/demo.prom")
  grep -qxF "polaris_backup_last_duration_seconds{unit=\"demo\"} $((now - 1000))" "$dir/demo.prom" \
    || fail "duration is not now - start"
  # Every metric carries HELP/TYPE, so several files can share a metric name.
  [ "$(grep -c '^# HELP' "$dir/demo.prom")" = 2 ] || fail "missing HELP lines"
  # Readable by the node-exporter user; no temp files left for the collector.
  [ "$(stat -c %a "$dir/demo.prom")" = 644 ] || fail "mode is not 0644"
  [ "$(ls -A "$dir")" = demo.prom ] || fail "stray files: $(ls -A "$dir")"

  # Start time unknown: success timestamp only, no duration.
  printf '#!/bin/sh\necho n/a\n' > fake-systemctl
  SYSTEMCTL="$PWD/fake-systemctl" ${bin} other "$dir"
  grep -q '^polaris_backup_last_success_timestamp_seconds{unit="other"}' "$dir/other.prom" \
    || fail "no success timestamp without start time"
  if grep -q duration "$dir/other.prom"; then fail "duration written without start time"; fi

  # A second success replaces the file rather than appending.
  SYSTEMCTL="$PWD/fake-systemctl" ${bin} other "$dir"
  [ "$(grep -c '^polaris_backup_last_success' "$dir/other.prom")" = 1 ] || fail "file appended"

  # Wrong usage fails.
  if ${bin} only-one-arg; then fail "accepted one argument"; fi

  touch $out
''

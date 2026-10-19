# Runs tests/cloud-backup-test.sh: the gdrive/github backup scripts against a
# stubbed rclone/gh and real git on local repos. Pure shell, so it also runs on
# the Macs (no Linux builder needed).
{ pkgs }:
pkgs.runCommand "cloud-backup-test" {
  nativeBuildInputs = [ pkgs.git pkgs.jq ];
} ''
  bash ${./cloud-backup-test.sh} \
    ${../modules/server/gdrive-backup.sh} \
    ${../modules/server/github-backup.sh}
  touch $out
''

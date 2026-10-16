# Tests for the cloud-backup scripts: gdrive-backup.sh against a stubbed rclone,
# github-backup.sh against a stubbed gh and real git on local bare repos.
# Run by checks.<system>.cloud-backup (tests/cloud-backup.nix).
#
# Usage: cloud-backup-test.sh <gdrive-backup.sh> <github-backup.sh>
set -euo pipefail
gdrive_script=$1
github_script=$2

work=$(mktemp -d)
stubs=$work/stubs
mkdir -p "$stubs"
real_git=$(command -v git)
export PATH="$stubs:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }
# mkstub <name>: stdin becomes an executable stub in $stubs.
mkstub() { { printf '#!%s\n' "$BASH"; cat; } > "$stubs/$1"; chmod +x "$stubs/$1"; }
# assert_line <file> <needle>...: some single line contains every needle.
assert_line() {
  local file=$1 line ok
  shift
  while IFS= read -r line; do
    ok=1
    for n in "$@"; do [[ $line == *"$n"* ]] || { ok=0; break; }; done
    ((ok)) && return 0
  done < "$file"
  fail "no line in $file contains: $*"$'\n'"$(cat "$file")"
}

# --- gdrive-backup.sh -------------------------------------------------------

mkstub rclone <<'EOF'
(IFS='|'; echo "$*") >> "$RCLONE_LOG"
case "$1" in
  backend)
    [ -n "${DRIVES_FAIL:-}" ] && exit 1
    echo '[{"id":"0A1","name":"Team/Docs"},{"id":"0A2","name":"Dup"},{"id":"0A3","name":"Dup"},{"id":"0A4","name":".."}]'
    ;;
  sync)
    [[ -n "${SYNC_FAIL:-}" && $3 == *"$SYNC_FAIL" ]] && exit 1
    mkdir -p "$3"
    ;;
esac
EOF

g=$work/gdrive
d=$g/root/gdrive-personal
mkdir -p "$g/state" "$d/.deleted/2026-07-17" "$d/.deleted/2026-07-18" "$d/.deleted/notadate"
echo '[personal]' > "$g/rendered.conf"
export RCLONE_LOG=$g/log

run_gdrive() {
  : > "$RCLONE_LOG"
  env RCLONE_CONF_SRC="$g/rendered.conf" STATE_DIRECTORY="$g/state" \
    BACKUP_ROOT="$g/root" TODAY=2026-10-16 "$@" \
    bash "$gdrive_script" personal
}

# Run 1: everything succeeds.
run_gdrive || fail "gdrive run 1 exited non-zero"
[ "$(stat -c %a "$g/state/rclone.conf")" = 600 ] || fail "config copy not 0600"
cmp -s "$g/rendered.conf" "$g/state/rclone.conf" || fail "config not copied"
c="--config|$g/state/rclone.conf|--drive-export-formats|docx,xlsx,pptx,svg,json|--drive-skip-shortcuts|--max-delete|500"
assert_line "$RCLONE_LOG" "sync|personal:|$d/my-drive|$c|--backup-dir|$d/.deleted/2026-10-16/my-drive"
assert_line "$RCLONE_LOG" "sync|personal:|$d/shared-with-me|$c|--backup-dir|$d/.deleted/2026-10-16/shared-with-me|--drive-shared-with-me"
assert_line "$RCLONE_LOG" "backend|drives|personal:|--config|$g/state/rclone.conf"
assert_line "$RCLONE_LOG" "|$d/shared-drives/Team_Docs|" "--backup-dir|$d/.deleted/2026-10-16/shared-drives/Team_Docs" "--drive-team-drive|0A1"
assert_line "$RCLONE_LOG" "|$d/shared-drives/Dup (0A2)|" "--drive-team-drive|0A2"
assert_line "$RCLONE_LOG" "|$d/shared-drives/Dup (0A3)|" "--drive-team-drive|0A3"
assert_line "$RCLONE_LOG" "|$d/shared-drives/0A4|" "--drive-team-drive|0A4"
[ "$(grep -c '^sync|' "$RCLONE_LOG")" = 6 ] || fail "expected 6 syncs"
# Retention: cutoff for 2026-10-16 minus 90 days is 2026-07-18 (kept).
[ ! -e "$d/.deleted/2026-07-17" ] || fail "91-day-old .deleted dir not pruned"
[ -d "$d/.deleted/2026-07-18" ] || fail "90-day-old .deleted dir wrongly pruned"
[ -d "$d/.deleted/notadate" ] || fail "non-date .deleted dir touched"

# Run 2: one section fails; the rest still run, MAX_DELETE applies, exit != 0.
if run_gdrive MAX_DELETE=7 SYNC_FAIL=shared-with-me; then fail "gdrive run 2 should fail"; fi
assert_line "$RCLONE_LOG" "|$d/my-drive|" "--max-delete|7|"
[ "$(grep -c '^sync|' "$RCLONE_LOG")" = 6 ] || fail "a failed section stopped later syncs"

# Run 3: listing shared drives fails; My Drive/Shared with me still synced, exit != 0.
if run_gdrive DRIVES_FAIL=1; then fail "gdrive run 3 should fail"; fi
[ "$(grep -c '^sync|' "$RCLONE_LOG")" = 2 ] || fail "expected 2 syncs without drive list"

echo "gdrive-backup.sh: ok"

# --- github-backup.sh -------------------------------------------------------
# (added in Task 2)

echo "all cloud-backup tests passed"

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

# rclone: logs each call; env knobs make a section fail (SYNC_FAIL), report
# duplicate names (DUP_IN), or trip --max-delete (MAXDEL_IN, exit 7 like rclone).
mkstub rclone <<'EOF'
(IFS='|'; echo "$*") >> "$RCLONE_LOG"
case "$1" in
  backend)
    [ -n "${DRIVES_FAIL:-}" ] && exit 1
    [ -n "${DRIVES_GARBAGE:-}" ] && { echo 'not json'; exit 0; }
    echo '[{"id":"0A1","name":"Team/Docs"},{"id":"0A2","name":"Dup"},{"id":"0A3","name":"Dup"},{"id":"0A4","name":".."},{"id":"0A5","name":"a/b"},{"id":"0A6","name":"a_b"}]'
    ;;
  sync|copy)
    [[ -n "${SYNC_FAIL:-}" && $3 == *"$SYNC_FAIL" ]] && exit 1
    if [[ -n "${DUP_IN:-}" && $3 == *"$DUP_IN" ]]; then
      echo "2026/10/16 01:00:00 NOTICE: Scan.pdf: Duplicate object found in source - ignoring" >&2
      echo "2026/10/16 01:00:00 NOTICE: Old: Duplicate directory found in source - ignoring" >&2
    fi
    if [[ -n "${MAXDEL_IN:-}" && $3 == *"$MAXDEL_IN" ]]; then
      echo "2026/10/16 01:00:00 ERROR : Fatal error received - not attempting retries" >&2
      echo "2026/10/16 01:00:00 Failed to sync: --max-delete threshold reached" >&2
      exit 7
    fi
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
c="--config|$g/state/rclone.conf|--drive-export-formats|docx,xlsx,pptx,svg,json|--drive-skip-shortcuts|--drive-acknowledge-abuse|--ignore-errors|--max-delete|500"
assert_line "$RCLONE_LOG" "sync|personal:|$d/my-drive|$c|--backup-dir|$d/.deleted/2026-10-16/my-drive"
assert_line "$RCLONE_LOG" "sync|personal:|$d/shared-with-me|$c|--backup-dir|$d/.deleted/2026-10-16/shared-with-me|--drive-shared-with-me"
assert_line "$RCLONE_LOG" "backend|drives|personal:|--config|$g/state/rclone.conf"
assert_line "$RCLONE_LOG" "|$d/shared-drives/Team_Docs|" "--backup-dir|$d/.deleted/2026-10-16/shared-drives/Team_Docs" "--drive-team-drive|0A1"
assert_line "$RCLONE_LOG" "|$d/shared-drives/Dup (0A2)|" "--drive-team-drive|0A2"
assert_line "$RCLONE_LOG" "|$d/shared-drives/Dup (0A3)|" "--drive-team-drive|0A3"
assert_line "$RCLONE_LOG" "|$d/shared-drives/0A4|" "--drive-team-drive|0A4"
# "a/b" and "a_b" sanitize to the same folder name, so both get their id.
assert_line "$RCLONE_LOG" "|$d/shared-drives/a_b (0A5)|" "--drive-team-drive|0A5"
assert_line "$RCLONE_LOG" "|$d/shared-drives/a_b (0A6)|" "--drive-team-drive|0A6"
[ "$(grep -c '^sync|' "$RCLONE_LOG")" = 8 ] || fail "expected 8 syncs"
! grep -q -- '--exclude-from' "$RCLONE_LOG" || fail "--exclude-from without an excludes file"
[ ! -e "$d/WARNINGS.txt" ] || fail "WARNINGS.txt written on a clean run"
# Retention: cutoff for 2026-10-16 minus 90 days is 2026-07-18 (kept).
[ ! -e "$d/.deleted/2026-07-17" ] || fail "91-day-old .deleted dir not pruned"
[ -d "$d/.deleted/2026-07-18" ] || fail "90-day-old .deleted dir wrongly pruned"
[ -d "$d/.deleted/notadate" ] || fail "non-date .deleted dir touched"

# Run 2: one section fails; the rest still run, MAX_DELETE applies, exit != 0.
if run_gdrive MAX_DELETE=7 SYNC_FAIL=shared-with-me; then fail "gdrive run 2 should fail"; fi
assert_line "$RCLONE_LOG" "|$d/my-drive|" "--max-delete|7|"
[ "$(grep -c '^sync|' "$RCLONE_LOG")" = 8 ] || fail "a failed section stopped later syncs"

# Run 3: listing shared drives fails; My Drive/Shared with me still synced, exit != 0.
if run_gdrive DRIVES_FAIL=1; then fail "gdrive run 3 should fail"; fi
[ "$(grep -c '^sync|' "$RCLONE_LOG")" = 2 ] || fail "expected 2 syncs without drive list"

# Run 4: unparseable drive list fails the run instead of silently skipping drives.
if run_gdrive DRIVES_GARBAGE=1; then fail "gdrive run 4 should fail on a bad drive list"; fi

# Run 5: duplicate names are skipped by rclone without an error; report them
# in WARNINGS.txt (and stderr) without failing the run. A clean run clears it.
run_gdrive DUP_IN=my-drive 2> "$g/err" || fail "duplicates alone should not fail the run"
grep -q 'my-drive: 2 duplicate names' "$d/WARNINGS.txt" || fail "duplicates not in WARNINGS.txt"
grep -q 'my-drive: 2 duplicate names' "$g/err" || fail "duplicates not reported on stderr"
run_gdrive || fail "clean run after duplicates failed"
[ ! -e "$d/WARNINGS.txt" ] || fail "WARNINGS.txt not cleared by a clean run"

# Run 6: operator excludes (persistently undownloadable files) are passed on.
printf '/shared-with-me-file-that-403s.pdf\n' > "$g/state/excludes.txt"
run_gdrive || fail "run with excludes failed"
assert_line "$RCLONE_LOG" "|$d/my-drive|" "--exclude-from|$g/state/excludes.txt"
rm "$g/state/excludes.txt"

# Run 7-9: tripping --max-delete puts the section on hold. Later runs only
# `copy` it (never delete) and stay failed, until MAX_DELETE is set explicitly.
if run_gdrive MAXDEL_IN=shared-with-me; then fail "max-delete trip should fail"; fi
[ -e "$g/state/hold/shared-with-me" ] || fail "no hold after max-delete trip"
if run_gdrive; then fail "a held section should keep the run failed"; fi
assert_line "$RCLONE_LOG" "copy|personal:|$d/shared-with-me|"
assert_line "$RCLONE_LOG" "sync|personal:|$d/my-drive|"
run_gdrive MAX_DELETE=100000 || fail "MAX_DELETE override run failed"
assert_line "$RCLONE_LOG" "sync|personal:|$d/shared-with-me|" "--max-delete|100000|"
[ ! -e "$g/state/hold/shared-with-me" ] || fail "hold not released after a successful override"
run_gdrive || fail "run after releasing the hold failed"

echo "gdrive-backup.sh: ok"

# --- github-backup.sh -------------------------------------------------------

h=$work/github
export R=$h/remote
mkdir -p "$R"
export HOME=$work GIT_CONFIG_GLOBAL=$work/gitconfig
"$real_git" config --global user.name test
"$real_git" config --global user.email test@example.com
"$real_git" config --global init.defaultBranch main

# commit_to <bare repo>: push one new commit to its main branch.
commit_to() {
  local c=$work/checkout
  rm -rf "$c"
  "$real_git" clone -q "$1" "$c" 2>/dev/null
  date +%s%N >> "$c/file"
  "$real_git" -C "$c" add file
  "$real_git" -C "$c" commit -qm change
  "$real_git" -C "$c" push -q origin HEAD:refs/heads/main
}
for r in repo-a repo-a.wiki repo-b repo-d g1; do
  "$real_git" init -q --bare "$R/$r.git"
  commit_to "$R/$r.git"
done

# gh: only answers the exact owned-repos and gists queries.
mkstub gh <<'EOF'
case "$*" in
  "api --paginate /user/repos?affiliation=owner&per_page=100 --jq "*)
    printf 'repo-a\tfile://%s/repo-a.git\ttrue\n' "$R"
    printf 'repo-b\tfile://%s/repo-b.git\ttrue\n' "$R"
    if [ -n "${GH_EXTRA:-}" ]; then printf '%s\n' "$GH_EXTRA"; fi
    ;;
  "api --paginate /gists --jq "*)
    printf 'g1\tfile://%s/g1.git\n' "$R"
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
# git: repo-b has has_wiki=true but no wiki, which GitHub reports as not found.
mkstub git <<EOF
for a in "\$@"; do
  case "\$a" in *repo-b.wiki.git) echo "remote: Repository not found." >&2; exit 128 ;; esac
done
exec "$real_git" "\$@"
EOF

run_github() { env BACKUP_ROOT="$h/root" GH_TOKEN=test-token-value "$@" bash "$github_script"; }
m=$h/root/github
head_of() { "$real_git" --git-dir "$1" rev-parse refs/heads/main; }

# Run 1: owned repos, a wiki, a missing wiki, a gist.
run_github || fail "github run 1 exited non-zero"
[ "$("$real_git" --git-dir "$m/repos/repo-a.git" config core.bare)" = true ] || fail "repo-a not bare"
[ "$(head_of "$m/repos/repo-a.git")" = "$(head_of "$R/repo-a.git")" ] || fail "repo-a not mirrored"
[ -d "$m/repos/repo-a.wiki.git" ] || fail "repo-a wiki not mirrored"
[ -d "$m/repos/repo-b.git" ] || fail "repo-b not mirrored"
[ ! -e "$m/repos/repo-b.wiki.git" ] || fail "missing wiki should be skipped"
[ -d "$m/gists/g1.git" ] || fail "gist not mirrored"
! "$real_git" --git-dir "$m/repos/repo-a.git" config --local --get-regexp credential >/dev/null \
  || fail "credential helper stored in mirror config"
! grep -q test-token-value "$m/repos/repo-a.git/config" || fail "token stored in mirror config"

# Run 2: new upstream commit, a broken repo, and a leftover partial clone.
commit_to "$R/repo-a.git"
mkdir -p "$m/repos/repo-d.git.tmp" && echo junk > "$m/repos/repo-d.git.tmp/junk"
extra=$(printf 'repo-c\tfile://%s/nope.git\tfalse\nrepo-d\tfile://%s/repo-d.git\tfalse' "$R" "$R")
if run_github GH_EXTRA="$extra"; then fail "github run 2 should fail (repo-c)"; fi
[ "$(head_of "$m/repos/repo-a.git")" = "$(head_of "$R/repo-a.git")" ] || fail "repo-a not updated"
[ "$(head_of "$m/repos/repo-d.git")" = "$(head_of "$R/repo-d.git")" ] || fail "repo-d not cloned past leftover tmp"
[ ! -e "$m/repos/repo-d.git.tmp" ] || fail "leftover tmp not cleaned"
[ ! -e "$m/repos/repo-c.git" ] || fail "failed clone left a mirror behind"
[ -d "$m/gists/g1.git" ] || fail "gists skipped after a repo failure"

echo "github-backup.sh: ok"

echo "all cloud-backup tests passed"

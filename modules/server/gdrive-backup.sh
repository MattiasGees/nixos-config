# Mirror one Google account's Drive (My Drive, Shared with me, every shared
# drive) to $BACKUP_ROOT/gdrive-<account>. Run by gdrive-backup-<account>.service
# (gdrive-backup.nix); tested by tests/cloud-backup-test.sh.
#
# Usage: gdrive-backup.sh <account>     (<account> = rclone remote name)
# Env:   RCLONE_CONF_SRC  rendered rclone config (op-secrets), copied every run
#        STATE_DIRECTORY  writable dir for that copy (set by systemd)
#        BACKUP_ROOT      default /srv/data/backups
#        MAX_DELETE       per-sync delete guard, default 500
#        RETENTION_DAYS   how long .deleted/<date> dirs live, default 90
#        TODAY            YYYY-MM-DD override (tests)
#
# Upstream deletions/overwrites move into .deleted/<date>/<section> instead of
# vanishing; --max-delete fails a sync that would delete en masse (a wiped or
# compromised account) and puts that section on hold: later runs only `copy`
# it (never delete) and stay failed until a run with MAX_DELETE set
# explicitly succeeds. A failing section doesn't stop the others; the exit
# status reports it at the end.
#
# Files that fail every night (owner disabled downloads, over the export size
# limit) can be skipped via $STATE_DIRECTORY/excludes.txt (rclone filter
# syntax) so the unit can go green again. Duplicate names, which rclone skips
# silently, are listed in $dest/WARNINGS.txt. See the wiki runbook.
set -euo pipefail

acct=$1
dest="${BACKUP_ROOT:-/srv/data/backups}/gdrive-$acct"
today="${TODAY:-$(date +%F)}"
conf="${STATE_DIRECTORY:?}/rclone.conf"

# rclone writes refreshed access tokens back into its config, and the rendered
# secret isn't ours to rewrite: work on a fresh copy every run (which also
# picks up a token rotated in 1Password).
install -m 0600 "${RCLONE_CONF_SRC:?}" "$conf"

failed=()
warnings=()
out=$(mktemp)
trap 'rm -f "$out"' EXIT

excludes=()
if [ -f "$STATE_DIRECTORY/excludes.txt" ]; then
  excludes=(--exclude-from "$STATE_DIRECTORY/excludes.txt")
fi

# sync_section <dir under $dest> [extra rclone flags...]
sync_section() {
  local section=$1 verb=sync rc=0 dups
  shift
  local hold="$STATE_DIRECTORY/hold/${section//\//_}"
  if [ -e "$hold" ] && [ -z "${MAX_DELETE:-}" ]; then
    verb=copy
  fi
  # --ignore-errors: a few undownloadable files mustn't stop deletions from
  # reaching .deleted (rclone skips all deletes after any error otherwise);
  # --max-delete still caps the damage of a bad listing.
  rclone "$verb" "$acct:" "$dest/$section" \
    --config "$conf" \
    --drive-export-formats docx,xlsx,pptx,svg,json \
    --drive-skip-shortcuts \
    --drive-acknowledge-abuse \
    --ignore-errors \
    --max-delete "${MAX_DELETE:-500}" \
    --backup-dir "$dest/.deleted/$today/$section" \
    "${excludes[@]}" "$@" 2>&1 | tee "$out" >&2 || rc=$?

  if grep -q -- '--max-delete threshold reached' "$out"; then
    mkdir -p "$(dirname "$hold")"
    touch "$hold"
  fi
  dups=$(grep -c 'Duplicate .* found in source' "$out" || true)
  if ((dups)); then
    warnings+=("$section: $dups duplicate names skipped (only one item per name is backed up; rename the others in Drive)")
  fi

  if [ "$verb" = copy ]; then
    failed+=("$section (on hold after --max-delete: copied, nothing deleted)")
  elif ((rc)); then
    failed+=("$section")
  else
    rm -f "$hold"
  fi
}

sync_section my-drive
sync_section shared-with-me --drive-shared-with-me

# One folder per shared drive, named after the drive: '/' becomes '_', drives
# whose folder names would clash get their id appended, and names that aren't
# usable paths ("", ".", "..") fall back to the id. fd 3 keeps rclone off the
# loop's input.
if drives=$(rclone backend drives "$acct:" --config "$conf") \
    && list=$(jq -r '
      map(.dir = (.name | gsub("/"; "_")))
      | group_by(.dir)
      | map(if length > 1 then map(.dir = "\(.dir) (\(.id))") else . end)
      | flatten[]
      | if .dir == "" or .dir == "." or .dir == ".." then .dir = .id else . end
      | [.id, .dir] | @tsv' <<<"$drives"); then
  while IFS=$'\t' read -r id dir <&3; do
    [ -n "$id" ] || continue
    sync_section "shared-drives/$dir" --drive-team-drive "$id"
  done 3<<<"$list"
else
  failed+=("shared-drives (listing)")
fi

# Expire .deleted/<date> dirs after RETENTION_DAYS, judged by the dir's name:
# rclone keeps upstream mtimes, so file times say nothing about when a file
# was moved here. Anything not named like a date is left alone.
cutoff=$(date -d "$today - ${RETENTION_DAYS:-90} days" +%F)
for d in "$dest/.deleted"/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  [[ $name =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
  if [[ $name < $cutoff ]]; then
    rm -rf -- "$d"
  fi
done

if ((${#warnings[@]})); then
  printf '%s\n' "${warnings[@]}" | tee "$dest/WARNINGS.txt" >&2
else
  rm -f "$dest/WARNINGS.txt"
fi

if ((${#failed[@]})); then
  printf 'gdrive-backup %s: failed: %s\n' "$acct" "${failed[*]}" >&2
  exit 1
fi

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
# compromised account). A failing section doesn't stop the others; the exit
# status reports it at the end.
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

# sync_section <dir under $dest> [extra rclone flags...]
sync_section() {
  local section=$1
  shift
  if ! rclone sync "$acct:" "$dest/$section" \
      --config "$conf" \
      --drive-export-formats docx,xlsx,pptx,svg,json \
      --drive-skip-shortcuts \
      --max-delete "${MAX_DELETE:-500}" \
      --backup-dir "$dest/.deleted/$today/$section" \
      "$@"; then
    failed+=("$section")
  fi
}

sync_section my-drive
sync_section shared-with-me --drive-shared-with-me

# One folder per shared drive, named after the drive: '/' becomes '_', drives
# sharing a name get their id appended, and names that aren't usable paths
# ("", ".", "..") fall back to the id. fd 3 keeps rclone off the loop's input.
if drives=$(rclone backend drives "$acct:" --config "$conf"); then
  while IFS=$'\t' read -r id dir <&3; do
    sync_section "shared-drives/$dir" --drive-team-drive "$id"
  done 3< <(jq -r '
    group_by(.name)
    | map(if length > 1 then map(.dir = "\(.name) (\(.id))") else map(.dir = .name) end)
    | flatten[]
    | .dir |= gsub("/"; "_")
    | if .dir == "" or .dir == "." or .dir == ".." then .dir = .id else . end
    | [.id, .dir] | @tsv' <<<"$drives")
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

if ((${#failed[@]})); then
  printf 'gdrive-backup %s: failed: %s\n' "$acct" "${failed[*]}" >&2
  exit 1
fi

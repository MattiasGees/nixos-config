# Mirror every GitHub repo owned by the token's user (plus wikis) and all of
# that user's gists to $BACKUP_ROOT/github as bare `git clone --mirror`s. Run
# by github-backup.service (github-backup.nix); tested by
# tests/cloud-backup-test.sh.
#
# Env: GH_TOKEN (op-secrets EnvironmentFile), BACKUP_ROOT (default
# /srv/data/backups). Repos deleted on GitHub keep their last mirror here. A
# failing repo doesn't stop the rest; the exit status reports it at the end.
set -euo pipefail

dest="${BACKUP_ROOT:-/srv/data/backups}/github"
mkdir -p "$dest/repos" "$dest/gists"

failed=()

# https auth comes from GH_TOKEN through gh's credential helper, so the token
# is never written into a mirror's config.
gitc() {
  git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"
}

# mirror <url> <dir>: first run clones into <dir>.tmp and renames on success,
# so an interrupted clone is never mistaken for a mirror; later runs fetch.
mirror() {
  local url=$1 dir=$2
  if [ -d "$dir" ]; then
    gitc -C "$dir" remote update --prune
  else
    rm -rf -- "$dir.tmp"
    gitc clone --quiet --mirror "$url" "$dir.tmp" && mv -- "$dir.tmp" "$dir"
  fi
}

# has_wiki is true for most repos even when no wiki page was ever created;
# GitHub then answers "Repository not found", which isn't a failure.
mirror_wiki() {
  local url=$1 dir=$2 out
  if [ -d "$dir" ] || out=$(gitc ls-remote "$url" 2>&1 >/dev/null); then
    mirror "$url" "$dir"
  elif grep -q 'not found' <<<"$out"; then
    return 0
  else
    echo "$out" >&2
    return 1
  fi
}

repos=$(gh api --paginate '/user/repos?affiliation=owner&per_page=100' \
  --jq '.[] | [.name, .clone_url, .has_wiki] | @tsv')
while IFS=$'\t' read -r name url has_wiki <&3; do
  [ -n "$name" ] || continue
  mirror "$url" "$dest/repos/$name.git" || failed+=("$name")
  if [ "$has_wiki" = true ]; then
    mirror_wiki "${url%.git}.wiki.git" "$dest/repos/$name.wiki.git" || failed+=("$name.wiki")
  fi
done 3<<<"$repos"

gists=$(gh api --paginate /gists --jq '.[] | [.id, .git_pull_url] | @tsv')
while IFS=$'\t' read -r id url <&3; do
  [ -n "$id" ] || continue
  mirror "$url" "$dest/gists/$id.git" || failed+=("gist $id")
done 3<<<"$gists"

if ((${#failed[@]})); then
  printf 'github-backup: failed: %s\n' "${failed[*]}" >&2
  exit 1
fi

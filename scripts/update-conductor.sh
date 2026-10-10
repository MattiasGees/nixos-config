#!/usr/bin/env bash
# Pin the conductor flake input to a release and update flake.lock.
#
#   scripts/update-conductor.sh           # the newest GitHub release
#   scripts/update-conductor.sh v0.2.0    # a given release (e.g. to go back)
#
# `make update-conductor [TAG=v0.2.0]` runs this. Then `make switch
# NIXNAME=polaris` and commit flake.nix and flake.lock. Runbook:
# docs/polaris/conductor.md.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=MattiasGees/conductor

tag=${1:-$(gh release view --repo "$repo" --json tagName --jq .tagName)}
if [[ ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "update-conductor: '${tag}' is not a release tag (vX.Y.Z)" >&2
  exit 1
fi

current=$(grep -oE 'conductor\?ref=refs/tags/[^"]+' flake.nix | sed 's#.*/##' || true)
if [[ -z $current ]]; then
  echo "update-conductor: flake.nix has no conductor input pinned to a tag (…/conductor?ref=refs/tags/…)" >&2
  exit 1
fi

# If anything below fails (no such tag, no network, interrupted), put
# flake.nix and flake.lock back as they were, so a later `make switch` or
# commit doesn't pick up a half-done update.
backup=$(mktemp -d)
cp flake.nix flake.lock "$backup/"
restore() {
  local status=$?
  rm -f flake.nix.new
  if [[ $status -ne 0 ]]; then
    cp "$backup/flake.nix" "$backup/flake.lock" .
    echo "update-conductor: failed; flake.nix and flake.lock are unchanged" >&2
  fi
  rm -rf "$backup"
}
trap restore EXIT

# Portable in-place edit (GNU and BSD sed differ on -i).
sed -E "s#(conductor\?ref=refs/tags/)[^\"]+#\1${tag}#" flake.nix > flake.nix.new
mv flake.nix.new flake.nix
NIX_CONFIG="experimental-features = nix-command flakes" nix flake update conductor

echo "conductor: ${current} -> ${tag}"
echo "Next: make switch NIXNAME=polaris, check https://conductor.polaris.mattiasgees.be/api/health,"
echo "then commit flake.nix and flake.lock. If the switch fails or the release misbehaves:"
echo "git checkout flake.nix flake.lock && make switch NIXNAME=polaris (back to the committed pin)."

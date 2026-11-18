#!/usr/bin/env bash
# Move release-tag-pinned inputs to their newest tag (bump_tag below), run
# `nix flake update` and print a Markdown summary of what it changes:
# the version of every service on a host before and after
# (scripts/service-versions.nix), and the flake inputs that moved.
#
#   scripts/flake-update.sh           # polaris
#   scripts/flake-update.sh server    # another nixosConfiguration
#
# `make update` runs this; .github/workflows/flake-update.yml uses the output
# as the PR description. Versions come from evaluating the host, nothing is
# built, so `make switch NIXNAME=polaris` is still the real check.
set -euo pipefail
cd "$(dirname "$0")/.."

host=${1:-polaris}
export NIX_CONFIG="experimental-features = nix-command flakes"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

versions() {
  nix eval --impure --json ".#nixosConfigurations.${host}" \
    --apply "$(cat scripts/service-versions.nix)"
}

echo "flake-update: evaluating ${host} before the update..." >&2
versions > "$tmp/old.json"
cp flake.lock "$tmp/old.lock"

# Inputs pinned to a release tag (github:<repo>/vX.Y.Z) don't move with
# `nix flake update`. Point them at the newest release tag first, so the
# update below locks it. conductor isn't here: it's private and pinned on
# purpose (`make update-conductor`).
bump_tag() {
  local repo=$1 current latest
  current=$(grep -oE "github:${repo}/v[0-9]+\.[0-9]+\.[0-9]+\"" flake.nix | sed -E 's#.*/(v[^"]+)"#\1#' || true)
  if [[ -z $current ]]; then
    echo "flake-update: no ${repo} input pinned to a tag in flake.nix, skipping" >&2
    return 0
  fi
  latest=$(git ls-remote --tags --refs "https://github.com/${repo}" 'v*' \
    | sed 's#.*refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1 || true)
  if [[ -z $latest ]]; then
    echo "flake-update: couldn't list ${repo} tags, leaving it at ${current}" >&2
    return 0
  fi
  # Only move forward (a deleted tag mustn't downgrade the pin).
  if [[ $latest != "$current" && $(printf '%s\n' "$current" "$latest" | sort -V | tail -n1) == "$latest" ]]; then
    # Portable in-place edit (GNU and BSD sed differ on -i).
    sed -E "s#(github:${repo}/)${current}\"#\1${latest}\"#" flake.nix > "$tmp/flake.nix"
    cat "$tmp/flake.nix" > flake.nix
    echo "flake-update: ${repo} ${current} -> ${latest}" >&2
  fi
}
bump_tag Christian-SC26/yabai   # yabai-fork (Macs)

nix flake update

echo "flake-update: evaluating ${host} after the update..." >&2
# If the update breaks evaluation, still report what changed and show the
# error, instead of failing: that is exactly what the PR needs to show. The
# drvPath evaluates the whole system (without building it), which catches
# errors the version lookup doesn't touch.
if ! versions > "$tmp/new.json" 2> "$tmp/new.err"; then
  no_versions=1 broken=1
elif ! nix eval --impure --raw ".#nixosConfigurations.${host}.config.system.build.toplevel.drvPath" \
    > /dev/null 2> "$tmp/new.err"; then
  broken=1
fi
if [[ ${broken:-} ]]; then
  echo "flake-update: ${host} no longer evaluates, see the summary" >&2
fi

# --- Services -----------------------------------------------------------------

echo "## Version changes on \`${host}\`"
echo

if [[ ${broken:-} ]]; then
  echo "> [!WARNING]"
  echo "> \`nixosConfigurations.${host}\` no longer evaluates after this update."
  echo
  echo '```'
  # Only the final message; the stack trace above it is noise in a PR.
  awk '/^ *error:/ { msg = "" } { msg = msg $0 "\n" } END { printf "%s", msg }' "$tmp/new.err"
  echo '```'
  echo
fi

if [[ ! ${no_versions:-} ]]; then
  jq -rn --slurpfile old "$tmp/old.json" --slurpfile new "$tmp/new.json" '
    $old[0] as $o | $new[0] as $n
    # A bump is "major" when the first number changes, or the second one on 0.x.
    | def major: split(".") | if .[0] == "0" then .[0:2] else .[0:1] end;
      def link: if . then "[changelog](\(.))" else "" end;
      def ver: if . == null then null elif .error then "error" else .version end;
      [ ($o | keys) + ($n | keys) | unique[]
        | { name: ., old: ($o[.] | ver), new: ($n[.] | ver),
            changelog: ($n[.].changelog // $o[.].changelog) } ] as $rows
    | ($rows | map(select(.old != .new))) as $changed
    | ($rows | map(select(.old == .new))) as $same
    | if ($changed | length) == 0 then "No service changes version.\n"
      else
        "| Service | Old | New | | Changelog |",
        "|---|---|---|---|---|",
        ( $changed[]
          | "| \(.name) | \(.old // "—") | \(.new // "—") | "
            + (if .new == "error" then "⚠️ fails to evaluate"
               elif .old == "error" then "fixed"
               elif .old == null then "added"
               elif .new == null then "removed"
               elif (.old | major) != (.new | major) then "**major**"
               else "" end)
            + " | \(.changelog | link) |" ),
        ""
      end,
      if ($same | length) > 0 then
        "<details><summary>\($same | length) unchanged</summary>\n",
        ($same | map("\(.name) \(.old)") | join(", ")),
        "\n</details>\n"
      else empty end
  '
fi

# --- Flake inputs -------------------------------------------------------------

echo "## Flake inputs"
echo
jq -rn --slurpfile old "$tmp/old.lock" --slurpfile new flake.lock '
  def node($lock; $name): $lock.nodes.root.inputs[$name] as $key
    | if $key then $lock.nodes[$key].locked else null end;
  def repo: if .type == "github" then "\(.owner)/\(.repo)"
            else (.url // "" | capture("github\\.com[:/](?<r>[^/]+/[^/?]+?)(\\.git)?([?].*)?$").r // null) end;
  def at: (if .rev then .rev[0:7] + " " else "" end)
          + "(\(.lastModified // 0 | strftime("%Y-%m-%d")))";
  [ $new[0].nodes.root.inputs | keys[] as $name
    | { name: $name, old: node($old[0]; $name), new: node($new[0]; $name) }
    | select((.old.rev // .old.narHash) != (.new.rev // .new.narHash)) ] as $moved
  | if ($moved | length) == 0 then "No inputs changed.\n"
    else
      "| Input | Old | New | Diff |",
      "|---|---|---|---|",
      ( $moved[]
        | (.new | repo) as $repo
        | "| \(.name) | \(.old | if . then at else "—" end) | \(.new | at) | "
          + (if $repo and .old.rev and .new.rev
             then "[compare](https://github.com/\($repo)/compare/\(.old.rev)...\(.new.rev))"
             else "" end)
          + " |" ),
      ""
    end
'

echo "Versions are read by evaluating \`nixosConfigurations.${host}\`; nothing was built."
echo "Check with \`make switch NIXNAME=${host}\` before merging."

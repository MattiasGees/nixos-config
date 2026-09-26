#
# Claude Code bootstrap (Darwin) — runs bootstrap-claude-code.sh on activation.
#
# Claude Code owns its own config files, so we can't manage plugins/marketplaces
# /MCP with read-only Nix symlinks (they get reverted). Instead we drive Claude
# Code's own CLI, which persists the changes. This home-manager activation entry
# just runs that script for you as part of `make switch`, so a new machine sets
# itself up without a manual step.
#
# It runs at most once per script version: the marker is keyed to the script's
# store hash, so editing bootstrap-claude-code.sh (e.g. adding a plugin)
# re-triggers it on the next switch. Failures don't abort activation and leave
# no marker, so they retry next time.
#
{ lib, pkgs, ... }:

let
  bootstrapScript = ../../bootstrap-claude-code.sh;
  markerName = ".nix-bootstrap." + builtins.baseNameOf "${bootstrapScript}";
in
{
  home.activation.claudeCodeBootstrap = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
    marker="$HOME/.claude/${markerName}"
    if [ ! -e "$marker" ]; then
      if command -v claude >/dev/null 2>&1; then
        echo "Running Claude Code bootstrap (plugins + MCP)..."
        if ${pkgs.bash}/bin/bash ${bootstrapScript} </dev/null; then
          mkdir -p "$HOME/.claude" && touch "$marker"
        else
          echo "Claude Code bootstrap did not complete; will retry next switch." >&2
        fi
      else
        echo "claude CLI not found; skipping Claude Code bootstrap (retries next switch)." >&2
      fi
    fi
  '';
}

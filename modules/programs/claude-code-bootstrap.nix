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
# re-triggers it on the next switch. The script exits non-zero unless every
# item is verified present; then no marker is written and it retries next time.
#
# Each run writes ~/.claude/.nix-bootstrap.log (activation environment + script
# output) so failures that only happen under `make switch` can be diagnosed.
#
# Runs after linkGeneration so stale home-manager symlinks under ~/.claude are
# already cleaned up, and inside a subshell so the PATH tweak doesn't leak into
# later activation steps (they rely on GNU coreutils, not macOS /usr/bin tools).
#
{ lib, pkgs, ... }:

let
  bootstrapScript = ../../bootstrap-claude-code.sh;
  markerName = ".nix-bootstrap." + builtins.baseNameOf "${bootstrapScript}";
in
{
  home.activation.claudeCodeBootstrap = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    (
      set -o pipefail
      export PATH="$PATH:/opt/homebrew/bin"
      marker="$HOME/.claude/${markerName}"
      log="$HOME/.claude/.nix-bootstrap.log"
      if [ ! -e "$marker" ]; then
        if command -v claude >/dev/null 2>&1; then
          echo "Running Claude Code bootstrap (plugins + MCP)..."
          mkdir -p "$HOME/.claude"
          # Record the environment activation actually provides, for debugging.
          {
            echo "=== $(date) ==="
            echo "user=$(id -un) HOME=$HOME"
            echo "SSH_AUTH_SOCK=''${SSH_AUTH_SOCK:-<unset>}"
            echo "PATH=$PATH"
            echo "git=$(command -v git) claude=$(command -v claude)"
          } > "$log"
          if ${pkgs.bash}/bin/bash ${bootstrapScript} </dev/null 2>&1 | tee -a "$log"; then
            touch "$marker"
          else
            echo "Claude Code bootstrap did not complete; will retry next switch (details: $log)." >&2
          fi
        else
          echo "claude CLI not found; skipping Claude Code bootstrap (retries next switch)." >&2
        fi
      fi
    ) || true
  '';
}

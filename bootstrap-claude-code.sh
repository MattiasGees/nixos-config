#!/usr/bin/env bash
#
# Bootstrap Claude Code's machine-local config on a new system.
#
# Why this is a script and not home-manager: Claude Code owns and continuously
# rewrites its own config files (~/.claude/settings.json,
# ~/.claude/plugins/known_marketplaces.json, ...), so a read-only Nix symlink
# gets reverted the moment Claude Code runs. These bits also do NOT sync via
# your account (unlike the Anthropic "Skills" under ~/.claude/skills/synced/),
# so they must be re-established per machine. Nix still installs the
# claude-code@latest cask; this script sets up the rest, imperatively.
#
# Safe to re-run: every step is idempotent (already-present items just no-op).
#
set -uo pipefail

if ! command -v claude >/dev/null 2>&1; then
  echo "error: 'claude' CLI not found. Install the claude-code@latest cask (make switch) first." >&2
  exit 1
fi

echo "==> Marketplaces (claude-plugins-official is built in)"
claude plugin marketplace add forrestchang/andrej-karpathy-skills || true

echo "==> Plugins"
for plugin in \
  gopls-lsp@claude-plugins-official \
  frontend-design@claude-plugins-official \
  superpowers@claude-plugins-official \
  andrej-karpathy-skills@karpathy-skills; do
  echo "  - ${plugin}"
  claude plugin install "${plugin}" -y || true
  claude plugin enable "${plugin}" || true
done

echo "==> MCP servers (user scope = available in every project)"
claude mcp add prometheus --scope user \
  -e PROMETHEUS_URL=https://prometheus.k8s.mattiasgees.be \
  -- docker run -i --rm -e PROMETHEUS_URL ghcr.io/pab1it0/prometheus-mcp-server:latest || true

echo
echo "Done. Restart Claude Code to load newly installed plugins."
echo "Note: model preference (opus[1m]) and other settings.json options are set"
echo "      interactively via /model etc. — they persist once set."

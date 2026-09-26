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
# Idempotent: each item is checked first and only added when missing. Exits
# non-zero if anything is still missing afterwards (e.g. a running Claude Code
# session overwrote ~/.claude.json), so the activation hook retries next switch.
#
set -uo pipefail

MARKETPLACES=(
  "karpathy-skills forrestchang/andrej-karpathy-skills"
)

PLUGINS=(
  gopls-lsp@claude-plugins-official
  frontend-design@claude-plugins-official
  superpowers@claude-plugins-official
  andrej-karpathy-skills@karpathy-skills
)

if ! command -v claude >/dev/null 2>&1; then
  echo "error: 'claude' CLI not found. Install the claude-code@latest cask (make switch) first." >&2
  exit 1
fi

failed=0

echo "==> Marketplaces (claude-plugins-official is built in)"
for entry in "${MARKETPLACES[@]}"; do
  read -r name source <<<"${entry}"
  if claude plugin marketplace list 2>/dev/null | grep -qF "${name}"; then
    echo "  - ${name}: present"
  else
    claude plugin marketplace add "${source}" || failed=1
  fi
done

echo "==> Plugins"
for plugin in "${PLUGINS[@]}"; do
  if ! claude plugin list 2>/dev/null | grep -qF "${plugin}"; then
    claude plugin install "${plugin}" -y || { failed=1; continue; }
  fi
  status=$(claude plugin list 2>/dev/null | grep -F -A3 "${plugin}" | grep -F "Status:")
  case "${status}" in
    *enabled*) echo "  - ${plugin}: enabled" ;;
    *) claude plugin enable "${plugin}" || failed=1 ;;
  esac
done

echo "==> MCP servers (user scope = available in every project)"
if claude mcp get prometheus >/dev/null 2>&1; then
  echo "  - prometheus: present"
else
  claude mcp add prometheus --scope user \
    -e PROMETHEUS_URL=https://prometheus.k8s.mattiasgees.be \
    -- docker run -i --rm -e PROMETHEUS_URL ghcr.io/pab1it0/prometheus-mcp-server:latest
  if ! claude mcp get prometheus >/dev/null 2>&1; then
    echo "  - prometheus: not persisted (a running Claude Code session may have overwritten ~/.claude.json)" >&2
    failed=1
  fi
fi

echo
if [ "${failed}" -ne 0 ]; then
  echo "Some steps did not complete; re-run this script (or the next make switch will retry)." >&2
  exit 1
fi
echo "Done. Restart Claude Code to load newly installed plugins."

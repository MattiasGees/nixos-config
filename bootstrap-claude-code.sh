#!/usr/bin/env bash
#
# Bootstrap Claude Code's machine-local config on a new system.
#
# Why this is a script and not home-manager: Claude Code owns and continuously
# rewrites its own config files (~/.claude/settings.json,
# ~/.claude/plugins/known_marketplaces.json, ...), so a read-only Nix symlink
# gets reverted the moment Claude Code runs. These bits also do NOT sync via
# your account (unlike the Anthropic "Skills" under ~/.claude/skills/synced/),
# so they must be re-established per machine. Nix still installs Claude Code
# itself (claude-code@latest cask on Darwin, nixpkgs on Linux); this script sets
# up the rest, imperatively.
#
# Idempotent: each item is checked first and only added when missing. Exits
# non-zero if anything is still missing afterwards (e.g. a running Claude Code
# session overwrote ~/.claude.json), so the activation hook retries next switch.
#
# Presence is read straight from Claude Code's state files rather than parsed
# from `claude plugin list`: under nix-darwin activation (sudo + launchctl
# asuser) the CLI reported installed plugins as missing, and re-installing an
# already-installed plugin then fails ("Failed to clone repository").
#
set -uo pipefail

# Fetch GitHub repos over HTTPS, never SSH. Claude Code clones GitHub sources
# over SSH when it thinks SSH works, but during `make switch` there may be no
# ssh-agent (and a fresh Mac has no GitHub key at all). Everything fetched here
# is public, so HTTPS needs no credentials. Applies only to this script's git
# calls; the user's git/SSH config is untouched.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0="url.https://github.com/.insteadOf"
export GIT_CONFIG_VALUE_0="git@github.com:"
export GIT_CONFIG_KEY_1="url.https://github.com/.insteadOf"
export GIT_CONFIG_VALUE_1="ssh://git@github.com/"

CLAUDE_DIR="${HOME}/.claude"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
INSTALLED_FILE="${CLAUDE_DIR}/plugins/installed_plugins.json"
MARKETPLACES_FILE="${CLAUDE_DIR}/plugins/known_marketplaces.json"

# "<id>": [ ... ] key in installed_plugins.json
is_installed() { [ -f "${INSTALLED_FILE}" ] && grep -qF "\"$1\":" "${INSTALLED_FILE}"; }
# "<id>": true in settings.json's enabledPlugins
is_enabled() { [ -f "${SETTINGS_FILE}" ] && grep -qE "\"$1\"[[:space:]]*:[[:space:]]*true" "${SETTINGS_FILE}"; }
# "<name>": { ... } key in known_marketplaces.json
has_marketplace() { [ -f "${MARKETPLACES_FILE}" ] && grep -qF "\"$1\":" "${MARKETPLACES_FILE}"; }

# claude-plugins-official is normally auto-added on Claude Code's first
# interactive run; listing it covers a fresh Mac where that hasn't happened yet.
MARKETPLACES=(
  "claude-plugins-official anthropics/claude-plugins-official"
  "karpathy-skills forrestchang/andrej-karpathy-skills"
)

PLUGINS=(
  gopls-lsp@claude-plugins-official
  frontend-design@claude-plugins-official
  superpowers@claude-plugins-official
  andrej-karpathy-skills@karpathy-skills
)

if ! command -v claude >/dev/null 2>&1; then
  echo "error: 'claude' CLI not found (Darwin: claude-code@latest cask; Linux: pkgs/dev.nix). Run make switch first." >&2
  exit 1
fi

failed=0

echo "==> Marketplaces"
for entry in "${MARKETPLACES[@]}"; do
  read -r name source <<<"${entry}"
  if has_marketplace "${name}"; then
    echo "  - ${name}: present"
  else
    claude plugin marketplace add "${source}" || failed=1
  fi
done

echo "==> Plugins"
for plugin in "${PLUGINS[@]}"; do
  if ! is_installed "${plugin}"; then
    claude plugin install "${plugin}" -y || { failed=1; continue; }
  fi
  if is_enabled "${plugin}"; then
    echo "  - ${plugin}: enabled"
  else
    claude plugin enable "${plugin}" || failed=1
  fi
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

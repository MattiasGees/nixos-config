#
# Claude Code (CLI)
#
# Declaratively manages ~/.claude for the Claude Code CLI. Imported on Darwin
# only (see users/default/home-manager.nix). The desktop "claude" app is a
# separate Homebrew cask managed in darwin/configuration.nix and is NOT
# configured here.
#
# NOTE: the claude-code binary itself is installed from pkgs/dev.nix (shared
# with the servers), so `package = null` keeps this module from installing a
# second, wrapper copy and colliding on it. This module owns config only.
#
# settings.json is written read-only into the Nix store, so runtime mutations
# (/model, toggling plugins, auto-mode learning) will not persist -- that is
# the intended, fully-declarative behaviour.
#
# First switch: home-manager refuses to clobber the pre-existing real
# ~/.claude/settings.json. Move it aside once beforehand:
#     mv ~/.claude/settings.json ~/.claude/settings.json.pre-nix
#

{ pkgs, ... }:

{
  programs.claude-code = {
    enable = true;
    package = null;

    # ~/.claude/CLAUDE.md -- global memory. Empty for now; fill in as needed.
    context = "";

    settings = {
      model = "opus[1m]";
      inputNeededNotifEnabled = true;
      agentPushNotifEnabled = true;

      enabledPlugins = {
        "gopls-lsp@claude-plugins-official" = true;
        "frontend-design@claude-plugins-official" = true;
        "andrej-karpathy-skills@karpathy-skills" = true;
        "superpowers@claude-plugins-official" = true;
      };
    };

    # Pinned replacement for the mutable extraKnownMarketplaces entry.
    # The "claude-plugins-official" marketplace is built in and auto-installed,
    # so only the third-party one is declared here.
    marketplaces = {
      karpathy-skills = pkgs.fetchFromGitHub {
        owner = "forrestchang";
        repo = "andrej-karpathy-skills";
        rev = "2c606141936f1eeef17fa3043a72095b4765b9c2";
        hash = "sha256-4z/wRdYH7UXRzF8RJU0sw8xbpx0BW/7CBv5sVEC2knY=";
      };
    };

    # Promoted from the per-project scope in ~/.claude.json to a global server.
    mcpServers = {
      prometheus = {
        type = "stdio";
        command = "docker";
        args = [
          "run"
          "-i"
          "--rm"
          "-e"
          "PROMETHEUS_URL"
          "ghcr.io/pab1it0/prometheus-mcp-server:latest"
        ];
        env = {
          PROMETHEUS_URL = "https://prometheus.k8s.mattiasgees.be";
        };
      };
    };
  };
}

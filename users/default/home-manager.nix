{ lib, pkgs, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;

in {

  imports = [
        ../../modules/shell/git.nix
        ../../modules/shell/zsh.nix
        ../../modules/shell/direnv-hm.nix
        # ../../modules/editors/nvim/nvim.nix
        ../../modules/archive-downloads/archive-downloads.nix
        ../../pkgs/default.nix
        ../../darwin/modules/kitty/kitty.nix
        ../../darwin/modules/ghostty/ghostty.nix
        ] ++ (lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
        ../../darwin/modules/sketchybar/sketchybar.nix
        ../../darwin/modules/yabai/yabai.nix
        ../../darwin/modules/skhd/skhd.nix
        ../../darwin/modules/vscode/vscode.nix
        # ../../darwin/modules/syncthing/syncthing.nix
        ../../modules/programs/claude-code-bootstrap.nix
        ../../pkgs/macos.nix
        ]) ++ (lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        ../../modules/desktop/hyprland/home.nix
        ../../pkgs/nixos.nix
        ../../modules/desktop/hyprland/extras.nix
        ../../modules/desktop/dunst/dunst.nix
        ../../modules/vm/vfio/default.nix
        ../../pkgs/linux.nix
        ]);

  home = {
    stateVersion = "23.05";

    # Interactive shells only. This does NOT reach activation-time brew:
    # darwin-rebuild runs `brew bundle` under `sudo … env` (scrubbed environment,
    # only PATH preserved), so the activation path relies on
    # homebrew.onActivation.extraEnv in darwin/configuration.nix instead.
    sessionVariables = lib.optionalAttrs isDarwin {
      # Skip Homebrew's third-party tap-trust prompt (FelixKratz / koekeishiya /
      # theseal taps) so manual brew installs don't need trust each time.
      HOMEBREW_NO_REQUIRE_TAP_TRUST = "1";
    };
  };
}

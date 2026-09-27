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

    # Skip Homebrew's third-party tap-trust prompt (FelixKratz / koekeishiya /
    # theseal taps). A shell session var can't do this: darwin-rebuild runs
    # `brew bundle` with a scrubbed environment (sudo env HOMEBREW_...), so only
    # brew.env files - which brew sources itself - reach it. Without
    # XDG_CONFIG_HOME (activation) brew reads ~/.homebrew/brew.env; with it
    # (interactive shells) ~/.config/homebrew/brew.env. Cover both.
    file = lib.mkIf isDarwin {
      ".homebrew/brew.env".text = "HOMEBREW_NO_REQUIRE_TAP_TRUST=1\n";
    };
  };

  xdg.configFile = lib.mkIf isDarwin {
    "homebrew/brew.env".text = "HOMEBREW_NO_REQUIRE_TAP_TRUST=1\n";
  };
}

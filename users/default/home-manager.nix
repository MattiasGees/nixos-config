{ lib, pkgs, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;

in {

  imports = [
        ../../modules/shell/git.nix
        ../../modules/shell/zsh.nix
        # ../../modules/editors/nvim/nvim.nix
        ../../modules/archive-downloads/archive-downloads.nix
        ../../pkgs/default.nix
        ../../darwin/modules/kitty/kitty.nix
        ../../darwin/modules/ghostty/ghostty.nix
        ] ++ (lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
        ../../darwin/modules/sketchybar/sketchybar.nix
        ../../darwin/modules/yabai/yabai.nix
        ../../darwin/modules/skhd/skhd.nix
        # ../../darwin/modules/syncthing/syncthing.nix
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
  };
}

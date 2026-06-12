{ config, ... }:

let
  nixConfigDir = "${config.home.homeDirectory}/Documents/git/nixos-config";
  inherit (config.lib.file) mkOutOfStoreSymlink;
in

{
  # Ghostty terminal configuration with Catppuccin Macchiato theme
  xdg.configFile."ghostty".source = mkOutOfStoreSymlink "${nixConfigDir}/darwin/modules/ghostty/config";
}

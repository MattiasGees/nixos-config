{ config, ... }:

let
  nixConfigDir = "${config.home.homeDirectory}/Documents/git/nixos-config";
  inherit (config.lib.file) mkOutOfStoreSymlink;
in

{
  # Ghostty config (custom Synthwave theme). Out-of-store symlink: edits under
  # ./config apply without a rebuild, but the repo must be checked out at
  # ~/Documents/git/nixos-config.
  xdg.configFile."ghostty".source = mkOutOfStoreSymlink "${nixConfigDir}/darwin/modules/ghostty/config";
}

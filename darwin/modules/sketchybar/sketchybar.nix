{ config, ... }:

let
  nixConfigDir = "${config.home.homeDirectory}/Documents/git/nixos-config";
  inherit (config.lib.file) mkOutOfStoreSymlink;
in

{
  # Config and widgets ------------------------------------------------------------------------- {{{
  xdg.configFile."sketchybar".source = mkOutOfStoreSymlink "${nixConfigDir}/darwin/modules/sketchybar/config";
}

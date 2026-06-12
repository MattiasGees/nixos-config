{ config, ... }:

let
  nixConfigDir = "${config.home.homeDirectory}/Documents/git/nixos-config";
  inherit (config.lib.file) mkOutOfStoreSymlink;
in

{
  # Config and widgets ------------------------------------------------------------------------- {{{
  xdg.configFile."yabai".source = mkOutOfStoreSymlink "${nixConfigDir}/darwin/modules/yabai/config";
}

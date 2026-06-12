{ config, ... }:

let
  nixConfigDir = "${config.home.homeDirectory}/Documents/git/nixos-config";
  inherit (config.lib.file) mkOutOfStoreSymlink;
in

{
  # Config and widgets ------------------------------------------------------------------------- {{{
  xdg.configFile."vfio".source = mkOutOfStoreSymlink "${nixConfigDir}/modules/vm/vfio/win.xml";
}

{ config, ... }:

let
  nixConfigDir = "${config.home.homeDirectory}/Documents/git/nixos-config";
  inherit (config.lib.file) mkOutOfStoreSymlink;
in

{
  # Config -------------------------------------------------------------------------
  xdg.configFile."nvim".source = mkOutOfStoreSymlink "${nixConfigDir}/modules/editors/nvim/LazyNvim";
}

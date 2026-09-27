{ config, ... }:

let
  nixConfigDir = "${config.home.homeDirectory}/Documents/git/nixos-config";
  inherit (config.lib.file) mkOutOfStoreSymlink;
in

{
  # Out-of-store symlink: edits under ./LazyNvim apply without a rebuild, but the
  # repo must be checked out at ~/Documents/git/nixos-config.
  xdg.configFile."nvim".source = mkOutOfStoreSymlink "${nixConfigDir}/modules/editors/nvim/LazyNvim";
}

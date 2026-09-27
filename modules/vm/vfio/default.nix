{ config, ... }:

let
  nixConfigDir = "${config.home.homeDirectory}/Documents/git/nixos-config";
  inherit (config.lib.file) mkOutOfStoreSymlink;
in

{
  # libvirt domain XML for the Windows passthrough VM. Out-of-store symlink, so
  # the repo must be checked out at ~/Documents/git/nixos-config.
  xdg.configFile."vfio".source = mkOutOfStoreSymlink "${nixConfigDir}/modules/vm/vfio/win.xml";
}

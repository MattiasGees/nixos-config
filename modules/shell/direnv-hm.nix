#
# Direnv for Home Manager
#
# Home Manager compatible version without system-level options

{ config, lib, pkgs, ... }:

{
  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };

  home.packages = with pkgs; [
    direnv
    nix-direnv
  ];
}

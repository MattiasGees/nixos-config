# Generic headless server (nixosConfigurations.server / server-arm64).
{ config, pkgs, lib, ... }:

{
  networking.hostName = "nixos-server";

  environment.systemPackages = with pkgs; [
    neovim
    git
    wget
    curl
    htop
    tmux
    killall
    bash
  ];
}

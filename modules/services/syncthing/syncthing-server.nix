{ lib, pkgs, ... }:

{
  services.syncthing = {
    enable = false;
    tray.enable = false;
  };
}

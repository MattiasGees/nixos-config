## Essentially the shared `configuration.nix` for all the machines (including darwin)
{ config, pkgs, lib, ... }:

{

  nix = {
    settings = {
      trusted-users = [ "mattias" "root" ];
    };

    package = pkgs.nix;
    gc = {                                # Garbage collection
      automatic = true;
      options = "--delete-older-than 7d";
    };
    extraOptions = ''
      auto-optimise-store = true
      experimental-features = nix-command flakes
    '';
  };
}

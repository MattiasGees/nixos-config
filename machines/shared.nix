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

  # Handy tools available system-wide on every host (root included, unlike the
  # home-manager packages which only land in mattias' profile).
  environment.systemPackages = with pkgs; [
    htop
  ] ++ lib.optionals stdenv.hostPlatform.isLinux [
    nettools   # provides `ifconfig` (+ route/netstat); macOS ships its own
  ];
}

{ config, pkgs, lib,... }:

{
  # Be careful updating this.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  nix = {
    # use unstable nix so we can access flakes
    package = pkgs.nixUnstable;
    extraOptions = ''
      experimental-features = nix-command flakes
      keep-outputs = true
      keep-derivations = true
    '';

    settings = {
      substituters = [
      "https://mitchellh-nixos-config.cachix.org"
      "https://hyprland.cachix.org"
      ];
      trusted-public-keys = [
      "mitchellh-nixos-config.cachix.org-1:bjEbXJyLrL1HZZHBbO4QALnI5faYZppzkU4D2s0G8RQ="
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
      ];
    };
  };

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # VMware, Parallels both only support this being 0 otherwise you see
  # "error switching console mode" on boot.
  boot.loader.systemd-boot.consoleMode = "0";

  networking.hostName = "dev";

  time.timeZone = "Europe/London";

  # Don't require password for sudo
  # security.sudo.wheelNeedsPassword = false;
  # security.sudo.enable = true;

  i18n.defaultLocale = "en_US.UTF-8";

  users.mutableUsers = true;

  environment.systemPackages = with pkgs; [
    cachix
    gnumake
    killall
    niv
    rxvt_unicode
    xclip

  ];


  # Disable the firewall since we're in a VM and we want to make it
  # easy to visit stuff in here. We only use NAT networking anyways.
  networking.firewall.enable = false;

  # Originally 20.09; bumped to 23.05.
  system.stateVersion = "23.05";
}

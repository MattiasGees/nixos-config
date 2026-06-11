# Server-specific NixOS user configuration
# Minimal setup without GUI dependencies
{ pkgs, lib, user, system, ... }:

{
  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  programs.zsh.enable = true;

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone
  time.timeZone = "Europe/London";

  # Select internationalisation properties
  i18n.defaultLocale = "en_GB.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_GB.UTF-8";
    LC_IDENTIFICATION = "en_GB.UTF-8";
    LC_MEASUREMENT = "en_GB.UTF-8";
    LC_MONETARY = "en_GB.UTF-8";
    LC_NAME = "en_GB.UTF-8";
    LC_NUMERIC = "en_GB.UTF-8";
    LC_PAPER = "en_GB.UTF-8";
    LC_TELEPHONE = "en_GB.UTF-8";
    LC_TIME = "en_GB.UTF-8";
  };

  users.users.mattias = {
    isNormalUser = true;
    home = "/home/mattias";
    extraGroups = [ "wheel" "docker" "networkmanager" ];
    shell = pkgs.zsh;
    group = "users";
  };

  # Enable SSH
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
    };
  };

  # Ensure system profile is in PATH for SSH sessions
  environment.shellInit = ''
    export PATH=/run/current-system/sw/bin:$PATH
  '';

  programs.ssh = {
    startAgent = true;
  };

  # Enable mosh (mobile shell)
  programs.mosh = {
    enable = true;
    withUtempter = true;
  };

  # Open firewall for mosh (UDP ports 60000-61000)
  networking.firewall.allowedUDPPortRanges = [
    { from = 60000; to = 61000; }
  ];

  # List packages installed in system profile
  environment.systemPackages = with pkgs; [
    neovim
    git
    wget
    curl
  ];

  # Enable Docker (useful for servers)
  virtualisation.docker.enable = true;

  environment.sessionVariables = {
    EDITOR = "nvim";
  };

  # This value determines the NixOS release
  system.stateVersion = "23.05";
}

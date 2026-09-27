{ config, pkgs, user, ... }: {

  networking = {
    computerName = "Mattias MacBook";
    hostName = "mattias-macbook";
  };

    fonts.packages = [
      pkgs.nerd-fonts.jetbrains-mono
      pkgs.nerd-fonts.iosevka
    ];

}

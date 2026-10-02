{ config, pkgs, user, ... }: {

  networking = {
    computerName = "Mattias MacBook";
    hostName = "mattias-macbook";
  };

    fonts.packages = [
      pkgs.nerd-fonts.jetbrains-mono
      pkgs.nerd-fonts.iosevka
      pkgs.nerd-fonts.fira-code           # "FiraCode Nerd Font Mono" (kitty)
    ];

}

{ config, pkgs, user, githubKeys, ... }: {

  networking = {
    computerName = "Mattias MacBook";
    hostName = "mattias-macbook";
  };

  # The read-only Paseo investigation agent lives on this machine only.
  paseoAgent.enable = true;

    fonts.packages = [
      pkgs.nerd-fonts.jetbrains-mono
      pkgs.nerd-fonts.iosevka
      pkgs.nerd-fonts.fira-code           # "FiraCode Nerd Font Mono" (kitty)
    ];

  # SSH: Remote Login on, key-only, with the keys from github.com/mattiasgees.keys
  # (the `github-keys` flake input).
  services.openssh.enable = true;
  services.openssh.extraConfig = ''
    PasswordAuthentication no
    KbdInteractiveAuthentication no
  '';
  users.users.${user}.openssh.authorizedKeys.keyFiles = [ githubKeys ];

}

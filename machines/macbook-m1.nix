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

  # SSH: Remote Login on, key-only. Keys from github.com/mattiasgees.keys —
  # re-sync this list when keys are added/removed on GitHub.
  services.openssh.enable = true;
  services.openssh.extraConfig = ''
    PasswordAuthentication no
    KbdInteractiveAuthentication no
  '';
  users.users.${user}.openssh.authorizedKeys.keys = [
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBKkdI6stPG4bOv3p72OsEDxs9o3jrg3Lacsook0VGkzaUcDYC2jXE4gvJtfP7UwTmVxsRJD4YJ8NGxuuRustJh0="
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFtGUiGsLHfTl/Jb5TvKK7ReZ+qa6eT8+Jd3ZbKyE+nYstbN1ZKimi8ojjlrR+NREqV4J3aG8K0e1Pmi2MfkpSk="
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBt3dIJVLAvj2IrWprwngbshWN0kwwmbB64GSQsHonqd"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBKfSjZEPrxBJsLTkOiZ6yJiGnjwmVg+YN58J0o+a/29"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICPHTlLMBXtVvkWB3zh0Cgv5vgulOu0v/LAgexiHv10e"
  ];

}

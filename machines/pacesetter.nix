{ lib, ... }: {

  # Identical to macbook-m1; only the machine's name differs.
  imports = [ ./macbook-m1.nix ];

  networking = {
    computerName = lib.mkForce "PaceSetter";
    hostName = lib.mkForce "PaceSetter";
  };

}

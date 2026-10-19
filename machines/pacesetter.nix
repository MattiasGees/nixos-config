{ lib, ... }: {

  # Identical to macbook-m1; only the machine's name differs.
  imports = [ ./macbook-m1.nix ];

  networking = {
    computerName = lib.mkForce "PaceSetter";
    hostName = lib.mkForce "PaceSetter";
  };

  # Keep the Paseo daemon off the tailnet on this machine.
  paseo.listenOnTailscale = false;

  # macbook-m1.nix enables the investigation agent; it belongs on the physical
  # MacBook only, so force it off here.
  paseoAgent.enable = lib.mkForce false;

}

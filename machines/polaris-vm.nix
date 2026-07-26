# Reuses the polaris software/system config but overrides host-specific bits
# that don't apply to a throwaway VM (static IP, hostname, AMD-only params).
{ lib, pkgs, ... }:
{
  imports = [ ./polaris.nix ];

  networking.hostName = lib.mkForce "polaris-vm";

  # VM uses NAT/DHCP, not the static LAN address.
  networking.useDHCP = lib.mkForce true;
  networking.interfaces = lib.mkForce { };
  networking.defaultGateway = lib.mkForce null;
  networking.nameservers = lib.mkForce [ ];

  # Drop AMD/x86 IOMMU kernel params on aarch64.
  boot.kernelParams = lib.mkForce [ ];

  # Give the VM a login you can use interactively.
  users.users.mattias.initialPassword = lib.mkForce "polaris";
}

# Throwaway hardware profile for the aarch64 build-vm smoke test.
# No ZFS pools, no static disks — build-vm supplies a virtual root disk.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
  networking.hostId = "0badf00d";
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}

# GENERATED hardware config for polaris.
#
# On (re)install, overwrite this file WHOLESALE with the output of
#   nixos-generate-config --root /mnt
# (found at /mnt/etc/nixos/hardware-configuration.nix) — exactly like the
# `desktop` host. Nothing here is hand-maintained.
#
# polaris' ZFS pools, hostId, encrypted swap and GPU driver live in
# hardware/polaris-extra.nix (wired in via flake.nix), so they survive
# regenerating this file. Values below are placeholders / a typical AMD+NVMe
# default until you run generate-config.
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/REPLACE-ROOT-UUID";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/REPLACE-BOOT-UUID";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };

  swapDevices = [ ];

  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}

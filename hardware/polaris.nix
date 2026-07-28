# Hardware config for polaris.
#
# The fileSystems + boot.initrd.availableKernelModules below come from
#   nixos-generate-config --root /mnt
# run on the real machine (see docs/polaris/manual-install-guide.md). Replace the
# placeholders with that output on first install — the UUIDs it emits stay valid
# as long as you don't reformat the OS disk. The ZFS/swap block at the bottom is
# a polaris addition generate-config doesn't produce: keep it if you regenerate.
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # ===== from nixos-generate-config (replace on real hardware) =====
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # generate-config writes root/boot by UUID. Placeholders — paste the real
  # by-uuid devices it emits.
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/REPLACE-ROOT-UUID";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/REPLACE-BOOT-UUID";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };

  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # ===== polaris additions (keep across regenerations) =====

  # ZFS requires a stable, unique host id. INSTALL-TIME: set with
  #   head -c 8 /dev/urandom | od -A none -t x1 | tr -d ' '
  networking.hostId = "a11c3b0d";

  # Import the manually-created pools BY NAME — stable across reinstalls (you
  # never recreate them), so no UUID needed. ZFS mounts them at their /srv
  # native mountpoints.
  boot.zfs.extraPools = [ "tank" "fast" "scratch" ];

  # Encrypted swap: a fresh random key each boot means no stable filesystem UUID,
  # so reference the partition by its GPT partlabel instead.
  swapDevices = [
    { device = "/dev/disk/by-partlabel/swap"; randomEncryption.enable = true; }
  ];
}

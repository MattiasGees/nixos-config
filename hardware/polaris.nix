# Real-hardware config for polaris. Disks are partitioned and the ZFS pools
# created BY HAND (see docs/polaris/manual-install-guide.md) — this file records
# the resulting layout: kernel modules, hostId, the OS filesystems, and the
# import of the manually-created pools.
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # INSTALL-TIME: replace this list with the real box's output from
  #   nixos-generate-config --show-hardware-config
  # (copy the boot.initrd.availableKernelModules line). The values below are a
  # typical AMD+NVMe default.
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # Required by ZFS. INSTALL-TIME: pick a unique value with
  #   head -c 8 /dev/urandom | od -A none -t x1 | tr -d ' '   (use first 8 hex)
  networking.hostId = "a11c3b0d";

  # Import the manually-created pools at boot (they back no `fileSystems`
  # entries because their datasets use ZFS-native mountpoints under /srv).
  # scratch = single-disk NVMe pool on NVMe #1 (no redundancy, disposable).
  boot.zfs.extraPools = [ "tank" "fast" "scratch" ];

  # OS filesystems (created by hand from the installer — labels set by mkfs).
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };
  swapDevices = [
    { device = "/dev/disk/by-partlabel/swap"; randomEncryption.enable = true; }
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}

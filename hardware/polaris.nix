# Real-hardware config for polaris. Disk PARTITIONS/filesystems (/,/boot,swap)
# are provided by disko/polaris.nix — not here. This file adds the bits disko
# doesn't: hostId, kernel modules, and import of the manually-created pools.
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # INSTALL-TIME: replace this list with the real box's output from
  #   nixos-generate-config --no-filesystems --show-hardware-config
  # The --no-filesystems flag omits the fileSystems/swapDevices block (disko
  # owns those), so its output is safe to merge here without conflicting with
  # disko/polaris.nix. The values below are a typical AMD+NVMe default.
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  # Required by ZFS. INSTALL-TIME: pick a unique value with
  #   head -c 8 /dev/urandom | od -A none -t x1 | tr -d ' '   (use first 8 hex)
  networking.hostId = "a11c3b0d";

  # Import the manually-created pools at boot (they back no `fileSystems`
  # entries because their datasets use ZFS-native mountpoints).
  # scratch = single-disk NVMe pool on NVMe #1 (no redundancy, disposable).
  boot.zfs.extraPools = [ "tank" "fast" "scratch" ];

  # No swapDevices / fileSystems here — disko owns them.
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}

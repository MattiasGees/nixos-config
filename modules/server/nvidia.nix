# NVIDIA RTX 3080 (Ampere) driver for HOST use — NVENC transcoding (Plex,
# Immich), CUDA (Ollama). Imported from hardware/polaris-extra.nix.
#
# ⚠️ Mutually exclusive with GPU passthrough. To pass the card to a VM, drop
#    this import and bind the GPU to vfio-pci instead (blacklist nvidia).
{ config, lib, pkgs, ... }:
{
  # Selects the NVIDIA driver on a headless box (does NOT enable an X server).
  services.xserver.videoDrivers = [ "nvidia" ];

  # Userspace graphics/compute libraries.
  hardware.graphics.enable = true;

  hardware.nvidia = {
    modesetting.enable = true;
    # Proprietary kernel module: the conservative choice. Ampere also supports
    # NVIDIA's open modules (open = true).
    open = false;
    nvidiaSettings = false;
    powerManagement.enable = false;
    # Keeps the driver initialised with no X session holding the GPU open.
    nvidiaPersistenced = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
}

# NVIDIA RTX 3080 (Ampere) driver for HOST use — NVENC hardware transcoding
# (Plex/Jellyfin), CUDA, etc. The GPU stays on the host.
#
# ⚠️ Mutually exclusive with GPU passthrough. If you later pass this card
#    through to a VM, REMOVE this module's import from machines/polaris.nix and
#    bind the GPU to vfio-pci instead (blacklist nvidia). You cannot both use it
#    on the host and pass it through to a guest.
{ config, lib, pkgs, ... }:
{
  # Load the NVIDIA kernel driver even though the box is headless.
  # (This does NOT enable an X server — it only selects the driver.)
  services.xserver.videoDrivers = [ "nvidia" ];

  # Userspace graphics/compute libraries (renamed from hardware.opengl).
  hardware.graphics.enable = true;

  hardware.nvidia = {
    modesetting.enable = true;
    # Proprietary kernel module — the conservative, well-tested choice for
    # Ampere. Ampere also supports the open modules (set open = true) if you
    # prefer NVIDIA's newer open kernel driver.
    open = false;
    # No GUI settings tool on a server.
    nvidiaSettings = false;
    powerManagement.enable = false;
    # Persistence daemon: keeps the driver initialised on a headless box so the
    # GPU is ready for transcoding/compute without an X session holding it open.
    nvidiaPersistenced = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
}

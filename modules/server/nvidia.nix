# NVIDIA RTX 3080 (Ampere) driver for HOST use — NVENC transcoding (Plex,
# Immich), CUDA (Ollama). Imported from hardware/polaris-extra.nix.
#
# ⚠️ Mutually exclusive with GPU passthrough. To pass the card to a VM, drop
#    this import and bind the GPU to vfio-pci instead (blacklist nvidia).
{ config, ... }:
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
  };

  # GPU utilisation, VRAM, temperature, power and NVENC/NVDEC load from
  # nvidia-smi, scraped by the k8s Prometheus (k8s-config ScrapeConfig
  # polaris-gpu). nvidia-smi failing (e.g. driver/library mismatch after an
  # update) shows up as nvidia_smi_last_collect_success == 0. Tailnet only.
  services.prometheus.exporters.nvidia-gpu = {
    enable = true;
    port = 9835;
  };
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    config.services.prometheus.exporters.nvidia-gpu.port
  ];
}

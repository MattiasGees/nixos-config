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
    # patchelf 0.19.2 maps .dynamic read-only when --interpreter and
    # --set-rpath run in one invocation, so nvidia-smi segfaults in ld.so
    # (nixpkgs#576412) and GpuMetricsFailing fires. Backport of nixpkgs
    # #576397: rpath first, then interpreter, as separate calls. The assert
    # fails once upstream has the fix; then drop this override.
    package = config.boot.kernelPackages.nvidiaPackages.stable.overrideAttrs (old:
      let
        src = builtins.readFile old.builder;
        patched = builtins.replaceStrings
          [ "patchelf --interpreter \"$(cat $NIX_CC/nix-support/dynamic-linker)\" \\\n                    --set-rpath $out/lib:$libPath $bin/bin/$i" ]
          [ "patchelf --set-rpath \"$out/lib:$libPath\" \"$bin/bin/$i\"\n                patchelf --interpreter \"$(cat \"$NIX_CC/nix-support/dynamic-linker\")\" \"$bin/bin/$i\"" ]
          src;
      in
      assert lib.assertMsg (patched != src)
        "nvidia.nix: nixpkgs#576397 backport no longer applies; remove the override";
      { builder = pkgs.writeText "nvidia-x11-builder.sh" patched; });
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

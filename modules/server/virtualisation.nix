# Reusable virtualisation stack: libvirt/KVM (for running VMs) + docker.
# IOMMU is enabled via kernel params in machines/polaris.nix; GPU passthrough
# is a later phase.
{ pkgs, ... }:
{
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      swtpm.enable = true;
      # OVMF/UEFI firmware ships with QEMU by default now — the old
      # qemu.ovmf submodule was removed, so we no longer set it.
    };
    onBoot = "ignore";
    onShutdown = "shutdown";
  };

  virtualisation.docker.enable = true;

  users.users.mattias.extraGroups = [ "libvirtd" "docker" ];
}

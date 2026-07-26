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
      ovmf = {
        enable = true;
        packages = [ pkgs.OVMFFull.fd ];
      };
    };
    onBoot = "ignore";
    onShutdown = "shutdown";
  };

  virtualisation.docker.enable = true;

  users.users.mattias.extraGroups = [ "libvirtd" "docker" ];
}

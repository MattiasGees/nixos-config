# Reusable virtualisation stack: libvirt/KVM + docker. (IOMMU/passthrough
# prep lives in machines/polaris.nix.)
{ pkgs, ... }:
{
  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      swtpm.enable = true;
      # No qemu.ovmf: that option was removed; QEMU ships OVMF by default.
    };
    onBoot = "ignore";
    onShutdown = "shutdown";
  };

  virtualisation.docker.enable = true;

  users.users.mattias.extraGroups = [ "libvirtd" "docker" ];
}

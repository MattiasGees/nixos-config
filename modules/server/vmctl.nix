# vmctl — KVM VM lab CLI (github.com/MattiasGees/vmctl), wired for polaris.
# The generic Go tool reads polaris specifics from VMCTL_* env vars set here.
# `vmctlPackages` is injected via _module.args from flake.nix (mkServer does
# not thread flake inputs into modules).
{ pkgs, lib, config, vmctlPackages, ... }:
let
  vmRoot = "/srv/scratch/vms"; # on the scratch pool (mountpoint /srv/scratch)
  nixosBase = "${vmctlPackages.nixos-base}/nixos.qcow2";
  # Ubuntu 24.04 LTS cloud image (docs/polaris/vmctl-runbook.md A.4 pins the sha).
  ubuntuURL = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img";
  ubuntuSHA = ""; # TODO(on-host): set to the pinned image's sha256
  # vmctlPackages.vmctl is already wrapped (PATH deps) by its own flake; this
  # adds a second wrapProgram layer for the VMCTL_* env. If those vars don't
  # take effect, check `cat $(which vmctl)` for both layers (runbook B.8).
  vmctlWrapped = pkgs.symlinkJoin {
    name = "vmctl-wrapped";
    paths = [ vmctlPackages.vmctl ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/vmctl \
        --set VMCTL_BRIDGE "br0" \
        --set VMCTL_VMROOT "${vmRoot}" \
        --set VMCTL_GATEWAY "192.168.1.1" \
        --set VMCTL_DNS "192.168.1.1" \
        --set VMCTL_USER "mattias" \
        --set VMCTL_SSH_KEYS_URL "https://github.com/mattiasgees.keys" \
        --set VMCTL_NIXOS_BASE "${nixosBase}" \
        --set VMCTL_UBUNTU_URL "${ubuntuURL}" \
        --set VMCTL_UBUNTU_SHA256 "${ubuntuSHA}"
    '';
  };
in
{
  environment.systemPackages = [ vmctlWrapped ];

  # Ensure the VM storage tree exists on scratch, owned by the operator.
  systemd.tmpfiles.rules = [
    "d ${vmRoot}        0755 mattias libvirtd - -"
    "d ${vmRoot}/base   0755 mattias libvirtd - -"
    "d ${vmRoot}/disks  0755 mattias libvirtd - -"
    "d ${vmRoot}/seeds  0755 mattias libvirtd - -"
  ];
}

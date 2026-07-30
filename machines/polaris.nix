{ config, pkgs, lib, ... }:
{
  imports = [
    ../modules/server/zfs.nix
    ../modules/server/virtualisation.nix
    # NVIDIA lives in hardware/polaris-extra.nix (x86_64-only; the aarch64
    # polaris-vm variant inherits this file, so it must stay driver-free).
    ../modules/media/common.nix
    ../modules/media/plex.nix
  ];

  networking.hostName = "polaris";

  # Stable kernel (NOT linuxPackages_latest — keep ZFS compatibility).
  boot.kernelPackages = pkgs.linuxPackages;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # IOMMU passthrough mode, ready for future GPU passthrough. IOMMU itself is
  # enabled by the BIOS + AMD kernel default — `amd_iommu=on` is NOT a valid
  # option ("AMD-Vi: Unknown option - 'on'" in dmesg), so we only set iommu=pt.
  boot.kernelParams = [ "iommu=pt" ];

  # Static IP on enp6s0 (confirmed via `ip -o link` on this machine).
  # nixos-server.nix enables NetworkManager; disable it here so it doesn't
  # fight the declarative static interface config below.
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = lib.mkDefault false;
  networking.interfaces.enp6s0.ipv4.addresses = [
    { address = "192.168.1.50"; prefixLength = 24; }
  ];
  networking.defaultGateway = "192.168.1.1";
  networking.nameservers = [ "192.168.1.1" ];

  # SSH: key-only. Keys from github.com/mattiasgees.keys (2x ecdsa, 2x ed25519).
  users.users.mattias.openssh.authorizedKeys.keys = [
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBKkdI6stPG4bOv3p72OsEDxs9o3jrg3Lacsook0VGkzaUcDYC2jXE4gvJtfP7UwTmVxsRJD4YJ8NGxuuRustJh0="
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFtGUiGsLHfTl/Jb5TvKK7ReZ+qa6eT8+Jd3ZbKyE+nYstbN1ZKimi8ojjlrR+NREqV4J3aG8K0e1Pmi2MfkpSk="
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBt3dIJVLAvj2IrWprwngbshWN0kwwmbB64GSQsHonqd"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBKfSjZEPrxBJsLTkOiZ6yJiGnjwmVg+YN58J0o+a/29"
  ];
  services.openssh.settings.PasswordAuthentication = false;

  # Ship terminfo for common terminals (kitty, alacritty, foot, wezterm, …) so
  # SSHing in doesn't error with "can't find terminal definition for
  # xterm-kitty" and TUIs render correctly.
  environment.enableAllTerminfo = true;
}

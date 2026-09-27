# Hand-maintained polaris hardware config. Wired in via flake.nix
# `extraModules` (not imported by hardware/ or machines/polaris.nix) so that:
#   - hardware/polaris.nix stays pure nixos-generate-config output and can be
#     overwritten wholesale (docs/polaris/setup.md Part 1), and
#   - the aarch64 polaris-vm doesn't inherit the NVIDIA driver or real pools.
{ lib, ... }:
{
  imports = [
    # NVIDIA RTX 3080 driver (x86_64-only, hence here).
    ../modules/server/nvidia.nix
  ];

  # ZFS requires a stable, unique host id: exactly 8 hex chars. Generate with:
  #   head -c4 /dev/urandom | od -An -tx4 | tr -d ' '
  networking.hostId = "8207d6f3";

  # Import the pools by name (stable across reinstalls). Datasets mount at the
  # /srv mountpoints stored in the pools themselves.
  boot.zfs.extraPools = [ "tank" "fast" "scratch" ];

  # Encrypted swap: a fresh random key each boot means no stable filesystem
  # UUID, so reference the GPT partlabel. Merges with generate-config's
  # `swapDevices = [ ]`.
  swapDevices = [
    { device = "/dev/disk/by-partlabel/swap"; randomEncryption.enable = true; }
  ];

  # Lock down the ESP so systemd-boot's random-seed isn't world-readable.
  # mkForce REPLACES generate-config's world-readable `fmask=0022 dmask=0022`;
  # merging would yield contradictory, order-dependent mount options.
  fileSystems."/boot".options = lib.mkForce [ "umask=0077" ];
}

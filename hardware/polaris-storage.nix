# polaris storage/ZFS config that must SURVIVE regenerating hardware/polaris.nix.
# Wired in via flake.nix `extraModules` (NOT imported by hardware/polaris.nix),
# so you can overwrite hardware/polaris.nix wholesale with nixos-generate-config
# output without losing any of this. See docs/polaris/manual-install-guide.md.
{ lib, ... }:
{
  # ZFS requires a stable, unique host id. INSTALL-TIME: set with
  #   head -c 8 /dev/urandom | od -A none -t x1 | tr -d ' '
  networking.hostId = "a11c3b0d";

  # Import the manually-created pools BY NAME (stable across reinstalls — you
  # never recreate them). ZFS mounts their datasets at the /srv native
  # mountpoints stored in the pool.
  boot.zfs.extraPools = [ "tank" "fast" "scratch" ];

  # Encrypted swap: a fresh random key each boot means no stable filesystem UUID,
  # so reference the partition by its GPT partlabel. This merges with the
  # `swapDevices = [ ]` that generate-config writes into hardware/polaris.nix.
  swapDevices = [
    { device = "/dev/disk/by-partlabel/swap"; randomEncryption.enable = true; }
  ];
}

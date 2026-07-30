# Hand-maintained polaris hardware config that must SURVIVE regenerating
# hardware/polaris.nix. Wired in via flake.nix `extraModules` (NOT imported by
# hardware/polaris.nix or machines/polaris.nix), so:
#   - hardware/polaris.nix stays pure nixos-generate-config output (overwrite it
#     wholesale — see docs/polaris/manual-install-guide.md), and
#   - the aarch64 polaris-vm variant does NOT inherit any of this (the NVIDIA
#     driver and real ZFS pools don't belong on a throwaway aarch64 VM).
{ lib, ... }:
{
  imports = [
    # NVIDIA RTX 3080 driver (host-side NVENC/CUDA). x86_64-only — which is
    # exactly why it lives here and not in machines/polaris.nix.
    ../modules/server/nvidia.nix
  ];

  # ZFS requires a stable, unique host id: exactly 8 hex chars. Generate with:
  #   head -c4 /dev/urandom | od -An -tx4 | tr -d ' '
  networking.hostId = "8207d6f3";

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

  # Lock down the ESP so systemd-boot's random-seed isn't world-readable.
  # mkForce REPLACES generate-config's `fmask=0022 dmask=0022` (0755 = world
  # readable) rather than merging with it — a merge would produce contradictory,
  # order-dependent mount options. Kept here so it survives regenerating
  # hardware/polaris.nix.
  fileSystems."/boot".options = lib.mkForce [ "umask=0077" ];
}

# Reusable ZFS enablement for servers.
# Pool definitions and hostId live in the host's hardware/<host>.nix — this
# module is pool-agnostic and safe to import anywhere.
{ pkgs, lib, ... }:
{
  boot.supportedFilesystems = [ "zfs" ];
  # Don't block boot prompting for encryption credentials: our encrypted
  # datasets are NOT needed for boot (root is ext4) and use file-based keys.
  boot.zfs.requestEncryptionCredentials = false;

  # Weekly scrub + periodic TRIM for pool health.
  services.zfs.autoScrub.enable = true;
  services.zfs.trim.enable = true;

  # Load file-based encryption keys after import, before ZFS mounts.
  # `zfs load-key -a` loads keys for every encrypted dataset whose keylocation
  # is a readable file (set at dataset creation).
  # NOTE: the name must NOT be `zfs-load-key` — that unit name is reserved and
  # masked by the ZFS systemd integration, so a service by that name never runs.
  systemd.services.load-zfs-keyfiles = {
    description = "Load ZFS encryption keys from keyfiles";
    # DefaultDependencies=no is REQUIRED. This service runs before
    # zfs-mount.service, which itself runs before local-fs.target (very early).
    # A normal service implicitly gets After=basic.target, and basic.target is
    # ordered after local-fs.target — so ordering this before zfs-mount created
    # a cycle, and systemd broke it by DELETING zfs-mount.service (leaving all
    # datasets unmounted). Opting out of default deps removes the cycle.
    unitConfig.DefaultDependencies = false;
    after = [ "zfs-import.target" ];
    before = [ "zfs-mount.service" "shutdown.target" ];
    conflicts = [ "shutdown.target" ];
    wantedBy = [ "zfs-mount.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Exit 1 (nothing to load / already loaded) is not a failure here.
      ExecStart = "${pkgs.zfs}/bin/zfs load-key -a";
      SuccessExitStatus = "0 1";
    };
  };

  # ARC sizing note: ZFS ARC defaults to ~50% of RAM (~32 GB on this 64 GB
  # box). Fine for Phase 1. When VMs/services arrive, cap it here, e.g.:
  #   boot.extraModprobeConfig = "options zfs zfs_arc_max=17179869184"; # 16 GiB
}

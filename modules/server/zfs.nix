# Reusable, pool-agnostic ZFS enablement. Pools (boot.zfs.extraPools) and
# networking.hostId are per-host — for polaris, hardware/polaris-extra.nix.
{ pkgs, lib, ... }:
{
  boot.supportedFilesystems = [ "zfs" ];
  # Don't block boot prompting for encryption credentials: our encrypted
  # datasets are NOT needed for boot (root is ext4) and use file-based keys.
  boot.zfs.requestEncryptionCredentials = false;
  # Upstream default from 26.11: never force-import a pool that looks in use
  # by another host. Our pools export cleanly, so forcing is never needed.
  boot.zfs.forceImportRoot = false;

  # Weekly scrub + periodic TRIM for pool health.
  services.zfs.autoScrub.enable = true;
  services.zfs.trim.enable = true;

  # Quiet the HDD pool (tank). ZFS commits a transaction group every
  # zfs_txg_timeout seconds while there is dirty async data; on a mostly-idle
  # HDD pool the 5 s default turns trickle writes into audible seek chatter.
  # 30 s batches them into far fewer seeks.
  #
  # Module parameter, so GLOBAL to every pool (no per-pool equivalent). Safe:
  # it only defers *async* writes (up to 30 s in RAM, lost on a hard power
  # cut); fsync'd writes still go straight to the ZIL, so PostgreSQL commits on
  # fast/db (sync=standard) are unaffected. Txgs are atomic (CoW), so 30 s is
  # as crash-consistent as 5 s — just a wider rollback window for un-fsync'd
  # data.
  boot.extraModprobeConfig = "options zfs zfs_txg_timeout=30";

  # Load file-based encryption keys (keylocation=file://, set at creation)
  # after import, before ZFS mounts.
  # NOTE: must NOT be named `zfs-load-key` — the ZFS systemd integration
  # reserves and masks that name, so a service called that never runs.
  systemd.services.load-zfs-keyfiles = {
    description = "Load ZFS encryption keys from keyfiles";
    # DefaultDependencies=no is REQUIRED. A normal service gets
    # After=basic.target (itself after local-fs.target), but this must run
    # before zfs-mount.service, which is before local-fs.target. The resulting
    # cycle made systemd drop zfs-mount.service, leaving every dataset unmounted.
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

  # ARC defaults to ~50% of RAM (~32 GB on polaris). To cap it (e.g. for VM
  # headroom), add to the existing options line above, e.g.:
  #   "options zfs zfs_txg_timeout=30 zfs_arc_max=17179869184" # 16 GiB
}

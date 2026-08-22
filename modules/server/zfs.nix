# Reusable ZFS enablement for servers.
# Pool definitions and hostId live in the host's hardware/<host>.nix — this
# module is pool-agnostic and safe to import anywhere.
{ pkgs, lib, ... }:
{
  boot.supportedFilesystems = [ "zfs" ];
  # Don't block boot prompting for encryption credentials: our encrypted
  # datasets are NOT needed for boot (root is ext4) and use file-based keys.
  boot.zfs.requestEncryptionCredentials = false;
  # New default from 26.11; reduces data-loss risk (won't force-import a pool
  # that looks in-use by another host). Our pools export cleanly, so importing
  # never needs forcing.
  boot.zfs.forceImportRoot = false;

  # Weekly scrub + periodic TRIM for pool health.
  services.zfs.autoScrub.enable = true;
  services.zfs.trim.enable = true;

  # Quiet the spinning-rust pool (tank). ZFS commits a transaction group every
  # zfs_txg_timeout seconds whenever there is dirty async data; on a mostly-idle
  # HDD pool this turns sparse trickle writes into an audible seek every 5 s (the
  # default). Batching those into one flush every 30 s means far fewer, larger
  # seeks — it's the seek chatter, not the constant spin, that's audible.
  #
  # This is a kernel-module parameter, so it is GLOBAL to every pool (tank, fast,
  # scratch) — there is no per-pool equivalent. Safe for all of them because it
  # only defers *async* writes (buffered up to 30 s in RAM, lost on a hard
  # power-cut); it does NOT affect synchronous (fsync) writes. PostgreSQL lives
  # on fast/db (ZFS, sync=standard), so on COMMIT its WAL fsync is written
  # immediately via the ZIL regardless of this timer — committed rows are
  # recovered by ZIL+WAL replay on power loss. ZFS is copy-on-write, so each txg
  # is atomic: 30 s is exactly as crash-consistent as 5 s, just a wider rollback
  # window for un-fsync'd async data, which no committed DB write is ever in.
  boot.extraModprobeConfig = "options zfs zfs_txg_timeout=30";

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

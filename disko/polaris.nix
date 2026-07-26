# disko config for polaris' OS disk ONLY. The tank/fast pools are created by
# scripts/create-zfs-pools.sh and are deliberately absent here so a reinstall
# that runs disko cannot destroy them.
{ ... }:
{
  # INSTALL-TIME VALUE: replace with the real by-id path from the target
  # machine, found via `ls -l /dev/disk/by-id/ | grep nvme`. Using by-id (not
  # /dev/nvme0n1) keeps the layout stable across reboots/reorders.
  disko.devices.disk.os =
    import ./polaris-layout.nix "/dev/disk/by-id/REPLACE_ME_NVME1";
}

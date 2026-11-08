# VM test: run the pool-creation script on virtual disks and assert the
# resulting ZFS topology, mountpoints, and encryption state.
{ pkgs, ... }:
let
  createScript = ../scripts/create-zfs-pools.sh;
in
pkgs.testers.runNixOSTest {
  name = "polaris-zfs";
  nodes.machine = { ... }: {
    imports = [ ../modules/server/zfs.nix ];
    networking.hostId = "deadbeef";
    # As in hardware/polaris-extra.nix, which this test can't import (GPU etc.).
    # Without it nothing imports the pools after the reboot below. They don't
    # exist yet on first boot, so these import units wait, then fail, harmlessly.
    boot.zfs.extraPools = [ "tank" "fast" "scratch" ];
    # The default /dev/disk/by-id is empty here: virtual disks have no serial.
    # Not by-uuid either: pool members share a UUID, so only one would show up.
    boot.zfs.devNodes = "/dev";
    # vdb = fast member, vdc = nvme2, vdd/vde/vdf = tank raidz1, vdg = scratch.
    virtualisation.emptyDiskImages = [ 512 512 2048 2048 2048 512 ];
    environment.systemPackages = [ pkgs.zfs ];
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    # FAST_MEMBER + SCRATCH_DEV override the fixed partlabels for the VM.
    machine.succeed(
        "FAST_MEMBER=/dev/vdb SCRATCH_DEV=/dev/vdg "
        "bash ${createScript} /dev/vdc /dev/vdd /dev/vde /dev/vdf"
    )
    # Topology
    machine.succeed("zpool status fast | grep -q mirror")
    machine.succeed("zpool status tank | grep -q raidz1")
    machine.succeed("zpool list scratch")
    # Datasets exist and are mounted under /srv
    machine.succeed("zfs list tank/media tank/data fast/appdata fast/db")
    machine.succeed("mountpoint /srv/media")
    machine.succeed("mountpoint /srv/data")
    machine.succeed("mountpoint /srv/fast/appdata")
    machine.succeed("mountpoint /srv/scratch")
    # Encryption: data encrypted + key available; media/scratch unencrypted
    machine.succeed("zfs get -H -o value keystatus tank/data | grep -q available")
    machine.succeed("zfs get -H -o value encryption tank/data | grep -q aes")
    machine.succeed("zfs get -H -o value encryption tank/media | grep -q off")
    machine.succeed("zfs get -H -o value encryption scratch | grep -q off")
    # Compression choices
    machine.succeed("zfs get -H -o value compression tank/media | grep -q lz4")
    machine.succeed("zfs get -H -o value compression tank/data | grep -q zstd")
    # Reboot -> key auto-loads (load-zfs-keyfiles.service) and datasets re-mount
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("zfs-mount.service")
    machine.succeed("zfs get -H -o value keystatus tank/data | grep -q available")
    machine.succeed("mountpoint /srv/data")
  '';
}

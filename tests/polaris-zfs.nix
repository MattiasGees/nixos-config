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
    # 2 disks for the fast mirror + 3 for the tank raidz1 => vdb..vdf.
    virtualisation.emptyDiskImages = [ 512 512 2048 2048 2048 ];
    environment.systemPackages = [ pkgs.zfs ];
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "bash ${createScript} /dev/vdb /dev/vdc /dev/vdd /dev/vde /dev/vdf"
    )
    # Topology
    machine.succeed("zpool status fast | grep -q mirror")
    machine.succeed("zpool status tank | grep -q raidz1")
    # Datasets exist and are mounted
    machine.succeed("zfs list tank/media tank/data fast/appdata fast/db")
    machine.succeed("mountpoint /mnt/media")
    machine.succeed("mountpoint /mnt/data")
    machine.succeed("mountpoint /mnt/fast/appdata")
    # Encryption: data encrypted + key available; media unencrypted
    machine.succeed("zfs get -H -o value keystatus tank/data | grep -q available")
    machine.succeed("zfs get -H -o value encryption tank/data | grep -q aes")
    machine.succeed("zfs get -H -o value encryption tank/media | grep -q off")
    # Compression choices
    machine.succeed("zfs get -H -o value compression tank/media | grep -q lz4")
    machine.succeed("zfs get -H -o value compression tank/data | grep -q zstd")
    # Reboot -> key auto-loads (zfs-load-key.service) and datasets re-mount
    machine.shutdown()
    machine.start()
    machine.wait_for_unit("zfs-mount.service")
    machine.succeed("zfs get -H -o value keystatus tank/data | grep -q available")
    machine.succeed("mountpoint /mnt/data")
  '';
}

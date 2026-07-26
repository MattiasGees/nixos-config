# VM test: boot the disko OS-disk layout on a virtual disk and assert that
# /, /boot, and swap come up. Uses disko's makeDiskoTest helper.
# Reference: https://github.com/nix-community/disko/blob/master/docs/reference.md
{ pkgs, disko }:
disko.lib.testLib.makeDiskoTest {
  inherit pkgs;
  name = "polaris-disko";
  disko-config = {
    disko.devices.disk.os = import ../disko/polaris-layout.nix "/dev/vdb";
  };
  # The layout uses an EFI System Partition -> boot the test VM in UEFI mode.
  efi = true;
  extraTestScript = ''
    machine.succeed("mountpoint /")
    machine.succeed("mountpoint /boot")
    machine.succeed("test \"$(stat -f -c %T /)\" = ext2/ext3")
    machine.succeed("swapon --show=NAME --noheadings | grep -q .")
  '';
}

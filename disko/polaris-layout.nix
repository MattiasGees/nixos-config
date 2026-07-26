# device -> disko layout for the OS NVMe.
# Partitions: ESP (/boot), ext4 root (/), encrypted swap, and a RAW partition
# reserved for the `fast` ZFS mirror member. The raw partition has NO content
# so disko creates the partition but never touches the pool.
device:
{
  type = "disk";
  inherit device;
  content = {
    type = "gpt";
    partitions = {
      ESP = {
        size = "1G";
        type = "EF00";
        content = {
          type = "filesystem";
          format = "vfat";
          mountpoint = "/boot";
          mountOptions = [ "umask=0077" ];
        };
      };
      root = {
        size = "450G";
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/";
        };
      };
      swap = {
        size = "8G";
        content = {
          type = "swap";
          randomEncryption = true;
        };
      };
      fastmember = {
        # Fills the rest of the 1 TB drive (~470 GiB). Raw: no content, so
        # disko leaves it unformatted for the manually-created `fast` mirror.
        size = "100%";
      };
    };
  };
}

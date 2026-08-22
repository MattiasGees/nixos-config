# Native Plex Media Server, with NVENC hardware transcoding on the RTX 3080
# (driver from modules/server/nvidia.nix). Hardware acceleration itself and
# the transcode temp dir are enabled/set in the Plex UI after deploy — see the
# Plex design archived in the Homecluster/NixOS wiki (Specs), §6, §9.
{ ... }:
{
  services.plex = {
    enable = true;
    # Opens 32400 + Plex's discovery ports on the LAN.
    openFirewall = true;
    # Config/metadata/DB on the fast (NVMe mirror, encrypted) pool.
    dataDir = "/srv/fast/appdata/plex";
  };

  # media = read the library; video = /dev/nvidia* access for NVENC.
  users.users.plex.extraGroups = [ "media" "video" ];

  # Transcode temp dir, kept off the ZFS pools (transient, cleaned per
  # session). Point Plex at this in Settings → Transcoder after deploy.
  systemd.tmpfiles.rules = [
    "d /var/cache/plex-transcode 0755 plex plex - -"
  ];
}

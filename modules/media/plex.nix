# Native Plex Media Server, with NVENC transcoding on the RTX 3080 (nvidia.nix).
# Hardware acceleration and the transcode dir are set in the Plex UI after
# deploy (Plex design, Homecluster/NixOS wiki → Specs, §6, §9).
{ ... }:
{
  services.plex = {
    enable = true;
    # 32400 + Plex's discovery ports.
    openFirewall = true;
    # Config/metadata/DB on the fast pool (encrypted NVMe mirror).
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

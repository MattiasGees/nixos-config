# Read-only NFS mount of the seedbox's completed-downloads dir, over the tailnet.
# Sonarr/Radarr/Bazarr read (copy) from here into /srv/media. Mounted at the SAME
# path the qBittorrent container reports (/mnt/media-downloads) so the *arr need
# no Remote Path Mapping.
#
# Boot-race handling: at boot the *arr/Bazarr (.NET) touch this path within ~2s —
# BEFORE Tailscale has a usable path to the seedbox (peer discovery is a few
# seconds in; a direct link can take minutes, DERP relay sooner). A mount tried
# then fails ("access denied by server" while the tunnel isn't up), and the
# automount can latch into start-limit-hit and never retry — staying dead until a
# manual `systemctl reset-failed`. The `seedbox-nfs-wait` oneshot below gates the
# mount on the seedbox NFS port being reachable first, so the mount fires once,
# after connectivity exists, instead of racing and burning the start limit.
{ pkgs, ... }:
let
  seedboxTailnetIp = "100.101.146.28";  # seedbox tailnet IP (`tailscale ip -4` on the seedbox)
in
{
  # Blocks until the seedbox's NFS port (2049) answers over the tailnet, then
  # exits 0. Caps at ~60s and still exits 0 (never fails) so a genuinely-down
  # seedbox can't wedge boot. No RemainAfterExit: the mount Requires+After this,
  # so it re-runs on every (re)mount trigger — a transiently-unreachable seedbox
  # simply re-gates instead of hammering the mount. StartLimitIntervalSec=0 so
  # this gate itself never latches under rapid re-triggering.
  systemd.services.seedbox-nfs-wait = {
    description = "Wait for the seedbox NFS export to be reachable over the tailnet";
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "tailscaled.service" "network-online.target" ];
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "seedbox-nfs-wait" ''
        for _ in $(seq 1 30); do
          (exec 3<>/dev/tcp/${seedboxTailnetIp}/2049) 2>/dev/null && { exec 3>&-; exit 0; }
          sleep 2
        done
        exit 0   # give up after ~60s; don't wedge boot — a later access re-gates
      '';
    };
  };

  # Use fileSystems (NOT systemd.mounts): NixOS only wires up the NFS mount helper
  # (mount.nfs) for fileSystems entries. A raw systemd.mounts unit mounts without
  # it and fails with "NFS: mount program didn't pass remote address". automount
  # keeps it lazy + nofail; the x-systemd.requires/after gate is what defuses the
  # boot race (see header).
  fileSystems."/mnt/media-downloads" = {
    device = "${seedboxTailnetIp}:/mnt/media-downloads";
    fsType = "nfs";
    options = [
      "ro" "nfsvers=4" "soft" "nofail"
      "x-systemd.automount" "x-systemd.idle-timeout=600"
      "timeo=50" "retrans=2"
      "x-systemd.requires=seedbox-nfs-wait.service"
      "x-systemd.after=seedbox-nfs-wait.service"
    ];
  };
}

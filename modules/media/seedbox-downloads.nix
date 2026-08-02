# Read-only NFS mount of the seedbox's completed-downloads dir, over the tailnet.
# Sonarr/Radarr/Bazarr read (copy) from here into /srv/media. Mounted at the SAME
# path the qBittorrent container reports (/mnt/media-downloads) so the *arr need
# no Remote Path Mapping.
#
# Declared as explicit systemd mount/automount (not `fileSystems`) so we can set
# StartLimitIntervalSec=0 and gate on the seedbox actually being reachable.
#
# Why: at boot the *arr/Bazarr (.NET) touch this path within ~2s — BEFORE
# Tailscale has a usable path to the seedbox (peer discovery is a few seconds in;
# a direct link can take minutes, DERP relay sooner). Those early attempts fail
# ("access denied by server" while the tunnel isn't up yet), and with systemd's
# default 5-tries-in-10s limit the (auto)mount latches into `start-limit-hit` and
# NEVER retries — it stays dead until a manual `systemctl reset-failed`. This
# module removes both failure modes:
#   1. `seedbox-nfs-wait` blocks the first mount until the seedbox NFS port answers
#      over the tailnet, so the boot mount is clean instead of racing.
#   2. StartLimitIntervalSec=0 means a failed mount never latches — the next access
#      simply remounts once the tailnet path is up, so it self-heals.
{ pkgs, ... }:
let
  seedboxTailnetIp = "100.101.146.28";  # seedbox tailnet IP (`tailscale ip -4` on the seedbox)
  where = "/mnt/media-downloads";
in
{
  # Oneshot gate: wait until the seedbox's NFS port (2049) is reachable over the
  # tailnet before the mount is attempted. Caps at ~60s then gives up WITHOUT
  # failing — the automount + no-start-limit combo self-heals on later access, so
  # a truly-down seedbox must never wedge the mount permanently.
  systemd.services.seedbox-nfs-wait = {
    description = "Wait for the seedbox NFS export to be reachable over the tailnet";
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "tailscaled.service" "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "seedbox-nfs-wait" ''
        for _ in $(seq 1 30); do
          (exec 3<>/dev/tcp/${seedboxTailnetIp}/2049) 2>/dev/null && { exec 3>&-; exit 0; }
          sleep 2
        done
        exit 0   # don't block boot; the automount self-heals on later access
      '';
    };
  };

  systemd.mounts = [{
    what = "${seedboxTailnetIp}:${where}";
    inherit where;
    type = "nfs";
    # soft + short timeo/retrans: a seedbox/tailnet blip degrades imports
    # gracefully (EIO) instead of hanging polaris on an unresponsive server.
    options = "ro,nfsvers=4,soft,timeo=50,retrans=2";
    after = [ "seedbox-nfs-wait.service" ];
    wants = [ "seedbox-nfs-wait.service" ];
    # Never latch into start-limit-hit — see the header comment. This is the load-
    # bearing line that makes the mount recover on its own after a reboot race.
    unitConfig.StartLimitIntervalSec = 0;
  }];

  systemd.automounts = [{
    inherit where;
    wantedBy = [ "multi-user.target" ];
    automountConfig.TimeoutIdleSec = 600;  # unmount after 10 min idle
  }];
}

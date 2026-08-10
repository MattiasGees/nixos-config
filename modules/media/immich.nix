# Immich (photo/video backup) — the first tenant of the shared PostgreSQL
# from modules/server/postgresql.nix. `database.enable`/`createDB` default to
# true, so the module connects over the unix socket (/run/postgresql, peer
# auth, no password) and layers pgvector + vectorchord onto our pg18 cluster,
# creating the `immich` role/DB itself — nothing to add to the Postgres
# module for this tenant to exist.
#
# Redis is `redis.enable = true` (default): a **dedicated** Valkey on its own
# socket, deliberately not the shared-Postgres pattern. Redis multi-tenancy is
# weak (shared auth/keyspace, apps assume they own the whole instance) and
# instances are cheap, so one Redis per app is the norm — the opposite
# tradeoff from Postgres. What lives in it (BullMQ job-queue/cache state) is
# ephemeral and needs no backups anyway.
#
# `machine-learning.enable = true` (default) runs CPU inference; CUDA is
# deferred (own change — see the design doc §8). `host`/`port`/`openFirewall`
# are left at their defaults (localhost:2283, no firewall hole) — Caddy is
# the only ingress, wired in caddy.nix.
#
# mediaLocation is a directory inside the existing `tank/data` dataset (same
# pool Plex's library lives on) rather than a new ZFS dataset — irreplaceable
# originals land on the redundant pool for free; no provisioning needed here
# since the dataset already exists and mounts at /srv/data.
#
# NVENC: accelerationDevices grants the sandboxed immich unit access to the
# device nodes; the NVIDIA driver/NVENC libs are already installed system-wide
# (Plex uses them). Per the design doc's known iteration point: the likely
# first-try gap is systemd sandboxing (ProtectSystem/PrivateDevices) hiding
# /dev/nvidia* or /run/opengl-driver/lib from the unit even with the devices
# listed — same class of issue Plex's NVENC setup hit. If Settings → Video
# Transcoding → NVENC doesn't actually offload (check `nvidia-smi` while
# transcoding), the fix is relaxing the unit's device/library sandboxing
# and/or adding `immich` to the `video` group — a bounded follow-up, not a
# redesign.
{ ... }:
{
  services.immich = {
    enable = true;
    mediaLocation = "/srv/data/immich";
    accelerationDevices = [ "/dev/nvidia0" "/dev/nvidiactl" "/dev/nvidia-uvm" ];
  };
}

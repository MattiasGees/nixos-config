# Immich (photo/video backup) — a tenant of the shared PostgreSQL
# (postgresql.nix). With the module defaults (database.enable/createDB) it
# connects over the unix socket with peer auth and adds pgvector + vectorchord
# and the `immich` role/DB to the cluster itself.
#
# Redis (default redis.enable) is a *dedicated* Valkey on its own socket —
# the opposite tradeoff from Postgres: Redis multi-tenancy is weak (shared
# keyspace, apps assume they own the instance) and instances are cheap. Its
# BullMQ queue/cache state is ephemeral and needs no backup.
#
# Machine learning runs on CPU (default); CUDA is a deferred follow-up.
# Listens on localhost:2283 (default), no firewall hole — Caddy is the ingress.
#
# mediaLocation is a plain dir inside the existing encrypted `tank/data`
# dataset, so the originals sit on the redundant pool and ride the restic sweep.
#
# NVENC: accelerationDevices exposes the device nodes to the sandboxed unit;
# the driver libs are system-wide (nvidia.nix). If Settings → Video
# Transcoding → NVENC doesn't actually offload (`nvidia-smi` while
# transcoding), the likely cause is unit sandboxing (ProtectSystem /
# PrivateDevices) hiding /dev/nvidia* or /run/opengl-driver/lib — relax that
# and/or add `immich` to the `video` group.
{ ... }:
{
  services.immich = {
    enable = true;
    mediaLocation = "/srv/data/immich";
    accelerationDevices = [ "/dev/nvidia0" "/dev/nvidiactl" "/dev/nvidia-uvm" ];
  };

  # For a non-default mediaLocation the module only adjusts ownership (tmpfiles
  # `e`), it doesn't create the dir — and tank/data's root is root-owned.
  systemd.tmpfiles.rules = [
    "d /srv/data/immich 0700 immich immich - -"
  ];

  # gunicorn's control server writes $HOME/.gunicorn; the immich-machine-learning
  # service's default HOME is the read-only /var/empty, which logs a (non-fatal)
  # "Operation not permitted" error on every start. Point HOME at the writable
  # cache dir it already uses (XDG_CACHE_HOME=/var/cache/immich).
  systemd.services.immich-machine-learning.environment.HOME = "/var/cache/immich";
}

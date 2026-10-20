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
# Prometheus metrics (host, API, repository timings, job queues) on :9283 (API
# worker) and :9284 (microservices worker), all interfaces, opened on
# tailscale0 only. Not Immich's default 8081/8082: Pi-hole's web UI owns 8081.
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
    environment = {
      IMMICH_TELEMETRY_INCLUDE = "all";
      IMMICH_API_METRICS_PORT = "9283"; # k8s-config ScrapeConfig polaris-immich
      IMMICH_MICROSERVICES_METRICS_PORT = "9284";
    };
  };
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 9283 9284 ];

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

  # CUDA ML: onnxruntime's CUDAExecutionProvider needs the NVIDIA *driver* lib
  # (libcuda.so.1), which is NOT in the nix store — it lives at
  # /run/opengl-driver/lib (provided by hardware.graphics/nvidia). The in-store
  # CUDA toolkit + cuDNN come via the wheel, but the driver stub must be exposed
  # to the sandboxed ML unit or the CUDA provider fails to initialise. Device
  # access (/dev/nvidia*) is granted by services.immich.accelerationDevices.
  systemd.services.immich-machine-learning.environment.LD_LIBRARY_PATH = "/run/opengl-driver/lib";
}

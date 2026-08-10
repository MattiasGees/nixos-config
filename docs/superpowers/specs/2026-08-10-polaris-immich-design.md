# Immich on polaris — Design (photo/video backup; first Postgres tenant)

**Status:** Draft for review
**Date:** 2026-08-10
**Host:** `polaris`

## 1. Purpose & scope

Stand up **Immich** (self-hosted photo/video backup — a Google Photos
replacement) on polaris as the **first tenant of the shared PostgreSQL** built
earlier. Phone auto-backup + web library, ML smart-search/faces (CPU), NVENC
video transcoding, reachable from anywhere over Tailscale.

**Scope:** the Immich server + machine-learning service, its DB/Redis wiring, the
NVENC device access, and the Caddy vhost. **Out of scope** (each its own
follow-up): CUDA-accelerated ML, importing existing photos as an external
library, and the **restic → S3 backup** (already queued next — it will cover
`/srv/data/immich` + a `pg_dumpall` of the `immich` DB).

## 2. Decisions (locked)

- **Database:** `services.immich.database` over the unix socket
  (`/run/postgresql`, peer auth — no password). `createDB = true` creates the
  `immich` role/DB and **layers `pgvector` + `vectorchord` onto our pg18
  cluster**. No change to the Postgres module is required — the Immich module
  merges its extension config into `services.postgresql`.
- **Redis:** `redis.enable = true` — Immich's module runs a **dedicated Valkey**
  over its own socket. *Not* a shared instance: Redis has weak multi-tenancy
  (shared auth/keyspace, apps assume they own it) and instances are ~free, so the
  pattern is one Redis per app — the opposite of the shared-Postgres choice. What
  lives in Redis is ephemeral job-queue/cache state (BullMQ), so it needs no
  backups.
- **Library:** `mediaLocation = "/srv/data/immich"` — a directory in the existing
  `tank/data` dataset (mounted at `/srv/data`, 26 T free). No new `zfs create`.
- **ML:** `machine-learning.enable = true`, **CPU**. Model cache at the module
  default `/var/cache/immich` (root disk) — bounded ~1–3 GB (ONNX model files,
  not per-photo; does not grow with the library). CUDA deferred.
- **Transcoding:** **NVENC now** —
  `accelerationDevices = [ "/dev/nvidia0" "/dev/nvidiactl" "/dev/nvidia-uvm" ]`.
  The NVIDIA driver/NVENC libs are already installed (Plex uses them).
- **Ingress:** Caddy `immich.polaris.mattiasgees.be → localhost:2283`. Immich
  stays `openFirewall = false` (localhost only; Caddy is the sole ingress). Remote
  access is Tailscale — phone runs Tailscale, same model as the *arr stack.

## 3. Storage

| What | Location | Pool | Notes |
|------|----------|------|-------|
| Library (originals, upload, thumbs, encoded-video, profile) | **`/srv/data/immich`** | `tank/data` | Directory in the existing dataset. Must be owned `immich:immich`; the module provisions `mediaLocation` (implementer confirms via the module's tmpfiles — if it doesn't for a non-`/var/lib` path, add a rule, same as the Postgres datadir). Irreplaceable originals live on the redundant `tank` pool; the restic step backs this up. |
| ML model cache | `/var/cache/immich` | root disk | Module default (`MACHINE_LEARNING_CACHE_FOLDER`). Bounded (~1–3 GB), reconstructible — fine off-tank. |
| Database + Redis | Postgres socket + Immich's own Valkey | `fast/db` (DB) | No separate storage decision; DB data lives in the existing pg18 cluster. |

## 4. The module (`modules/media/immich.nix`)

A new media module, imported by `machines/polaris.nix`:

```nix
services.immich = {
  enable = true;
  mediaLocation = "/srv/data/immich";
  # Defaults we rely on (documented, not overridden):
  #   database.enable/createDB = true  → attaches to services.postgresql,
  #     adds pgvector+vectorchord, creates the immich DB/role over the socket.
  #   redis.enable = true              → dedicated Valkey on a unix socket.
  #   machine-learning.enable = true   → CPU inference (immich-machine-learning).
  #   host = localhost; port = 2283; openFirewall = false.
  accelerationDevices = [ "/dev/nvidia0" "/dev/nvidiactl" "/dev/nvidia-uvm" ];
};
```

Runs as the `immich` user/group. Header comment (repo convention) explains: first
tenant of the shared Postgres, socket/peer auth, why Redis is dedicated-not-shared,
the `/srv/data/immich` placement, and the NVENC iteration point (§5).

## 5. NVENC — the known iteration point ⚠️

`accelerationDevices` grants the sandboxed `immich` unit access to the device
nodes, and the driver/NVENC libs are installed system-wide. The likely first-try
gap — same one Plex's spec called out — is the **NVIDIA userspace libs being
visible to Immich's sandboxed ffmpeg** (systemd `ProtectSystem`/`PrivateDevices`
hiding `/dev/nvidia*` or `/run/opengl-driver/lib`).

Plan: wire it as above; then in the Immich admin UI set **Video Transcoding →
Hardware Acceleration → NVENC**, upload a video, and check `nvidia-smi` shows an
Immich/ffmpeg process. If it doesn't offload, the fix is relaxing the unit's
device/library sandboxing and/or exposing the driver libs to the service (and
possibly adding `immich` to the `video` group) — a bounded iteration, not a
redesign. Verification in §7.

## 6. Repo structure & prerequisites

| File | Responsibility |
|------|----------------|
| `modules/media/immich.nix` | `services.immich` config (DB/Redis/ML/mediaLocation/NVENC) — new |
| `modules/media/caddy.nix` | add `virtualHosts."immich.polaris.mattiasgees.be".extraConfig = proxy 2283;` |
| `machines/polaris.nix` | import `../modules/media/immich.nix` |

**Manual prerequisites:** none new — `tank/data` already mounts at `/srv/data`.
DNS: the `*.polaris.mattiasgees.be` wildcard already resolves to the tailnet IP,
so `immich.` is covered — no new Route53 record. No firewall change (Caddy's
80/443 already open; Immich is localhost-only).

## 7. Verification & one-time setup

1. `make switch NIXNAME=polaris` (builds unprivileged per the fixed Makefile).
2. `systemctl status immich-server immich-machine-learning postgresql` → active.
3. DB tenant created: `sudo -u postgres psql -c '\l'` shows `immich`; then
   `sudo -u postgres psql -d immich -c '\dx'` shows `vector` + `vchord`.
4. Open `https://immich.polaris.mattiasgees.be` over Tailscale → create the admin
   account; confirm TLS is valid (Caddy ACME).
5. **NVENC:** Settings → Video Transcoding → Hardware Acceleration → **NVENC**;
   upload a video; `nvidia-smi` shows an Immich/ffmpeg process. If not → §5.
6. Install the mobile app, point it at the URL (over Tailscale), enable backup;
   confirm a photo uploads and appears in the web timeline.

## 8. Deferred / future (each its own spec → plan)

- **restic → S3 backups** (next): `/srv/data/immich` library + nightly
  `pg_dumpall` of the `immich` DB, plus local ZFS snapshots of `tank/data`.
- **CUDA ML** — build `immich-machine-learning` against `onnxruntime` with
  `cudaSupport` for fast indexing (heavy CUDA rebuild; own change).
- **NVENC hardening** — only if §5's first try doesn't offload.
- **External library** — import existing photos (e.g. from `/srv/media`) as a
  read-only Immich external library.

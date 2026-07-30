# Plex on polaris — Design (Media Stack, Phase 2a)

**Status:** Draft for review
**Date:** 2026-07-30
**Host:** `polaris`

## 1. Purpose & scope

Stand up **Plex** as the first service of the media stack, plus the shared
storage/permission foundation the rest of the stack (Sonarr, Radarr, …) will
build on. **Scope is Plex only** — the *arr apps, download client, and reverse
proxy/Tailscale come in later, separate specs.

## 2. Decisions (locked)

- **Native `services.plex`** (not Docker).
- **Hardware transcoding via the RTX 3080 (NVENC)** — Plex Pass available.
- **Remote access:** LAN + Plex's own **Relay** for now. Tailscale (the real
  CGNAT fix) is deferred to its own change. No reverse proxy, no port-forward
  (behind CGNAT, so port-forward isn't possible anyway).
- **Shared `media` group** created now as the stack's permission foundation.

## 3. Storage layout

| What | Location | On which pool | Notes |
|------|----------|---------------|-------|
| Plex config/metadata/DB | **`/srv/fast/appdata/plex`** | `fast` (NVMe mirror, encrypted) | A **directory inside the existing `fast/appdata` dataset** — no new `zfs create`. This is the irreplaceable Plex DB, so it belongs on the redundant, snapshotted pool. |
| Media library | **`/srv/media`** | `tank` (RAIDZ1) | Existing `tank/media`. Plex reads it. |
| Transcode temp | **`/var/cache/plex-transcode`** | OS root (NVMe1, ext4) | Transient, cleaned per session. Kept off `scratch` (reserved for longer-lived data) and off the encrypted pools. |

> Why not a bare `/srv/fast/plex`: the `fast` pool root is `mountpoint=none`, so
> `/srv/fast` is an ext4 directory — only `/srv/fast/appdata` and `/srv/fast/db`
> are ZFS mounts. `/srv/fast/appdata/plex` keeps the config on the fast pool
> without creating a dataset.

## 4. Permissions — the `media` group

- New group **`media`** with a **fixed GID** (pinned so ownership on `tank/media`
  survives reinstalls — files there will be group-owned by it).
- `plex` user added to `media` (read the library) and `video` (GPU device access).
- `/srv/media` set to `root:media`, mode **`2775`** (setgid) via a tmpfiles rule
  → files created under it inherit the `media` group. Plex reads via the group;
  later Sonarr/Radarr (also in `media`) write, all sharing cleanly.

## 5. Plex service config

- `services.plex.enable = true`.
- `services.plex.openFirewall = true` — opens 32400 + Plex discovery ports on the LAN.
- `services.plex.dataDir = "/srv/fast/appdata/plex"`.
- `users.users.plex.extraGroups = [ "media" "video" ]`.
- tmpfiles: ensure `/var/cache/plex-transcode` exists, owned by `plex`.

## 6. Hardware transcoding (NVENC, RTX 3080)

- Driver + `nvidiaPersistenced` already in place (`hardware/polaris-extra.nix`).
- `plex` in the `video` group for `/dev/nvidia*` access.
- In the Plex UI (post-setup): enable **"Use hardware acceleration when
  available"** and set the transcode temp dir to `/var/cache/plex-transcode`.
- ⚠️ **Iteration point:** Plex finding the NVIDIA NVENC libraries
  (`libnvidia-encode`) on NixOS is occasionally fiddly (library visibility /
  systemd sandboxing of `/dev/nvidia*`). If a transcode doesn't offload to the
  GPU on first try, this is where we adjust — likely relaxing device sandboxing
  on the plex unit and/or exposing the driver libs. Verification step in §10.

## 7. Remote access

- **LAN:** `openFirewall` handles it.
- **Outside:** Plex **Relay** (automatic, ~2 Mbps/stream cap) — acceptable
  stop-gap. Enable "Remote Access" in the Plex UI; it'll use the relay since
  port-forwarding isn't possible behind CGNAT.
- **Deferred:** Tailscale on polaris for full-quality CGNAT-proof remote access
  (its own change). Once added, register `http://<polaris-tailscale-ip>:32400`
  under Plex's *Custom server access URLs*.

## 8. Repo structure

| File | Responsibility |
|------|----------------|
| `modules/media/common.nix` | `media` group (fixed GID) + `/srv/media` setgid permissions — shared by the whole stack |
| `modules/media/plex.nix` | `services.plex` config, plex group memberships, transcode dir |
| `machines/polaris.nix` | imports the two media modules |

No manual prerequisites (no dataset to create) — the config + tmpfiles create the
directories; `/srv/media` already exists.

## 9. Post-deploy setup (one-time, in the UI)

1. `make switch NIXNAME=polaris`.
2. On a LAN machine, open `http://polaris:32400/web` (or `http://192.168.1.50:32400/web`), sign in to claim the server to your Plex account.
3. Add a library pointing at `/srv/media` (create `/srv/media/{Movies,TV,…}` as you like).
4. Settings → Transcoder: enable hardware acceleration, set temp dir to `/var/cache/plex-transcode`.
5. Settings → Remote Access: enable (uses Relay behind CGNAT).

## 10. Verification

- `systemctl status plex` → active.
- `http://192.168.1.50:32400/web` loads; library scans and shows content.
- Play something that forces a transcode; `nvidia-smi` shows a **`Plex Transcoder`** process using the GPU (confirms NVENC). If not, hit the §6 iteration point.
- New file under `/srv/media` inherits group `media` (`stat -c '%G' <file>` → `media`).

## 11. Deferred / future (not in this spec)

- Tailscale for remote access.
- Sonarr/Radarr + a download client (they join the `media` group; downloads land on `tank` or `scratch`, then hardlink/move into `/srv/media`).
- Reverse proxy (if we later want nice URLs / central ingress).
- Backups/snapshots policy (`fast/appdata` holds the Plex DB — a snapshot target).

# Sonarr / Radarr / Prowlarr + Caddy on polaris — Design (Media Stack Phase 2b)

**Status:** Draft for review
**Date:** 2026-07-30
**Host:** `polaris`

## 1. Purpose & scope

Bring the *arr media-automation apps onto polaris as **native NixOS services**,
fronted by **Caddy** with automatic TLS, reachable at `https://<app>.polaris.mattiasgees.be`
over the tailnet (and LAN). Part of **consolidating the media stack onto polaris**
(away from the k8s + Synology setup).

**In scope:** `services.sonarr` / `services.radarr` / `services.prowlarr`, a Caddy
reverse proxy with DNS-01 TLS, storage/permissions wiring, and the URLs.

**Deferred to the next phase (its own spec):**
- **Download-client rewiring** — pointing the seedbox qBittorrent at polaris
  `/srv/media/Downloads` (instead of the Synology), so imports hardlink into
  `/srv/media`. Until then the apps run and are reachable but have no download path.
- **Retiring the k8s *arr** + the Synology's role.

## 2. Decisions (locked)

- **Native NixOS services** (not containers).
- **Caddy** reverse proxy, **auto-TLS via DNS-01 on Route53 (AWS)** — required
  because polaris is behind CGNAT (HTTP-01 can't work).
- **DNS:** wildcard `*.polaris.mattiasgees.be` A record → **Tailscale IP
  `100.93.157.59`** (works from any tailnet device, remote or on the LAN).
- **Secret:** AWS creds via a **systemd `EnvironmentFile`** (`/etc/caddy/route53.env`,
  placed by hand, out of git).

## 3. The apps

Native services, each config on the **fast pool**, config-only on localhost
(Caddy is the only ingress):

| App | Service | Config dir | Media | Port (localhost) |
|-----|---------|-----------|-------|------------------|
| Sonarr | `services.sonarr` | `/srv/fast/appdata/sonarr` | `/srv/media/Series` | 8989 |
| Radarr | `services.radarr` | `/srv/fast/appdata/radarr` | `/srv/media/Movies` | 7878 |
| Prowlarr | `services.prowlarr` | `/srv/fast/appdata/prowlarr` (or module default) | — (indexer mgr, no media) | 9696 |

- **No `openFirewall`** on the apps — they bind localhost; only Caddy reaches them.
- `sonarr` and `radarr` users are added to the **`media` group** (reuse the Plex
  foundation) so they can read/write `/srv/media`. Prowlarr needs no media access.
- Config on `fast` (encrypted NVMe mirror) — these are SQLite DBs worth keeping on
  the redundant pool.
- **Implementation note:** `services.prowlarr` may not expose `dataDir`/`user` like
  sonarr/radarr; if so it keeps its module default (`/var/lib/prowlarr` on the OS
  root) — fine, its config is small and media-independent. Resolve at build time.

## 4. Caddy reverse proxy

`modules/media/caddy.nix`:
- Package built **with the `caddy-dns/route53` plugin** (`pkgs.caddy.withPlugins`).
- Global `acme_dns route53` so all vhosts use the DNS-01 challenge.
- vhosts:
  - `sonarr.polaris.mattiasgees.be` → `reverse_proxy localhost:8989`
  - `radarr.polaris.mattiasgees.be` → `reverse_proxy localhost:7878`
  - `prowlarr.polaris.mattiasgees.be` → `reverse_proxy localhost:9696`
- Listens on all interfaces → reachable on both the LAN and the tailnet IP.
- AWS creds via `systemd.services.caddy.serviceConfig.EnvironmentFile = "/etc/caddy/route53.env"`
  (contains `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION=us-east-1`).
- Open firewall **TCP 80 + 443** (80 for Caddy's http→https redirect; both needed
  for LAN + tailnet access).
- **Iteration note:** `caddy.withPlugins` needs the plugin's FOD `hash`; the first
  build prints the correct value to paste in. Same class of build-time detail as
  the ZFS/disko bits earlier.

## 5. DNS + AWS (operator, out-of-band)

- **Route53:** a wildcard record `*.polaris.mattiasgees.be` **A → `100.93.157.59`**
  (the tailnet IP). One record covers all three apps + future ones.
- **IAM:** a user/role with `route53:ChangeResourceRecordSets` +
  `route53:ListHostedZonesByName` + `route53:GetChange` on the `mattiasgees.be`
  zone. Put its keys in `/etc/caddy/route53.env` on polaris (mode `0600`).

## 6. Storage / permissions

- `/srv/media/{Movies,Series}` already exist (created for Plex, `media` group,
  setgid). Add **`/srv/media/Downloads`** (same `tank/media` dataset → hardlink
  imports later), same `2775 root:media`.
- `services.plex`/sonarr/radarr all read via the shared `media` group.

## 7. Repo structure

| File | Responsibility |
|------|----------------|
| `modules/media/sonarr.nix` | `services.sonarr` + media group + config dir |
| `modules/media/radarr.nix` | `services.radarr` + media group + config dir |
| `modules/media/prowlarr.nix` | `services.prowlarr` + config dir |
| `modules/media/caddy.nix` | Caddy (route53 plugin, vhosts, EnvironmentFile, firewall) |
| `machines/polaris.nix` | imports the four new modules |

(Follows the existing `modules/media/{common,plex}.nix` pattern.)

## 8. Prerequisites (operator, before/at deploy)

1. Create the Route53 wildcard A record → `100.93.157.59`.
2. Create the IAM creds; write `/etc/caddy/route53.env` on polaris (`0600`).
3. `sudo mkdir -p /srv/media/Downloads && sudo chmod 2775 /srv/media/Downloads`.

## 9. Post-deploy setup (in the UIs)

1. `make switch NIXNAME=polaris`; wait for Caddy to issue certs (watch `journalctl -u caddy`).
2. **Prowlarr** (`prowlarr.polaris.mattiasgees.be`): add indexers → Settings → Apps →
   add Sonarr + Radarr (URL `http://localhost:8989` / `:7878` + API key), sync on.
3. **Sonarr**: root folder `/srv/media/Series`.
4. **Radarr**: root folder `/srv/media/Movies`.
5. (Download client comes in the next phase.)

## 10. Verification

- `systemctl status sonarr radarr prowlarr caddy` all active.
- `https://sonarr.polaris.mattiasgees.be` loads with a **valid cert** from a tailnet device.
- `journalctl -u caddy` shows successful ACME DNS-01 issuance (no errors).
- A test file under `/srv/media/Series` is group `media` (setgid inheritance).

## 11. Deferred / future

- Download-client rewiring (seedbox qBittorrent → polaris `/srv/media/Downloads`)
  + Sonarr/Radarr download-client config → **next spec**.
- Retire the k8s `media` base + reassess the Synology's role.
- Backups: `fast/appdata` (the *arr SQLite DBs) join the Plex DB as snapshot targets.

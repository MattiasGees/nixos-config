# Seedbox qBittorrent + polaris library — Download Management (Media Stack Phase 3)

**Status:** Draft for review
**Date:** 2026-07-31
**Hosts:** `seedbox` (Ubuntu VPS, public `85.17.236.99`, tailnet node) · `polaris`
(tailnet `100.93.157.59`)

## 1. Purpose & scope

Bring qBittorrent's downloads into the polaris media stack while keeping all
BitTorrent traffic on the seedbox's public IP. This is **"Path A / Model 2"** from
the design discussion: qBittorrent stays on the seedbox as the fast **local
working disk**, polaris holds the **permanent library**, and Sonarr/Radarr import
completed downloads by copying them from the seedbox to polaris over the existing
tailnet. It then adds lifecycle management: private-only seeding, automatic
cleanup, and disk-pressure eviction on the **seedbox** disk.

**In scope:** the data-flow change (replace the NAS rsync with *arr imports over
an NFS mount), and three management behaviours — seed only private, auto-delete
what's no longer needed, and free the seedbox disk under pressure.

**Explicitly not in scope:** moving qBittorrent onto polaris; any new WireGuard
tunnel (we reuse the tailnet); the *arr↔Prowlarr wiring (already done);
Plex/backups.

## 2. Decisions (locked in discussion)

- **qBittorrent stays on the seedbox** (podman container, existing `qbittorrent`
  role). Downloading and seeding happen on the seedbox's **local disk**, so the
  swarm sees the seedbox IP and **seeding never uses home bandwidth**.
- **polaris is the library.** Sonarr/Radarr **copy** completed downloads into
  `/srv/media/{Series,Movies}`. It's a copy, not a hardlink — the source (seedbox)
  and destination (polaris) are different machines. This is the standard remote-
  seedbox pattern; home bandwidth is used once per item (the import pull), then
  never again.
- **Transport is the existing tailnet** — no new secure connection. polaris NFS-
  mounts the seedbox's completed-downloads directory, read-only, restricted to
  polaris' tailnet IP.
- **Seed policy:** private torrents seed to their ratio/time; public torrents are
  **not** seeded — removed right after import.
- **Management runs on the seedbox** (next to qBittorrent and its local disk):
  `qbit_manage` for tagging + share-limits + cleanup, and a disk-pressure job that
  watches the seedbox's local free space.

## 3. Architecture & data flow

```
INTERNET (swarm)
   │  leech ▲ / seed ▼   (seedbox public IP; NOT home bandwidth)
┌──┴───────────────────────────────────────────────┐
│ SEEDBOX  (qBittorrent (podman), local disk)       │
│   /var/qbittorrent/downloads/incomplete           │
│   /mnt/video/Downloads/{tv,movies}   (complete)   │
│        │  NFS export (ro) over tailnet            │
│   qbit_manage  +  disk-pressure eviction (timers) │
└────────┼──────────────────────────────────────────┘
         │  tailnet (existing)         ▲ import = COPY (home bw, once per item)
┌────────┴──────────────────────────────────────────┐
│ POLARIS                                            │
│   mounts seedbox:/mnt/video/Downloads (ro)         │
│   Sonarr/Radarr import → copy into                 │
│   /srv/media/{Series,Movies}   (ZFS, Plex library) │
└────────────────────────────────────────────────────┘
```

Lifecycle of one download:
1. qBittorrent (seedbox) downloads to local disk under the right category dir.
2. Sonarr/Radarr (polaris) see it via the qBittorrent API, read it over the NFS
   mount, and **copy** it into the library, renamed/organised for Plex.
3. **Public** torrent → removed from the seedbox right after import (no seeding).
4. **Private** torrent → keeps seeding from the seedbox's local disk to its ratio,
   then is removed. The polaris library copy is untouched by any removal.
5. If the seedbox disk fills, the disk-pressure job evicts the least-in-demand
   **already-imported** torrents early (polaris copy survives).

## 4. Bandwidth & disk model (why this shape)

- **Seeding is seedbox-local** → zero home bandwidth for seeding, and native
  seedbox-IP connectability.
- **Home bandwidth** is used only for the one-time import copy per item.
- **The seedbox disk is the constrained resource** (holds active private seeds) →
  hence requirement 3 targets the *seedbox's* `df`, not polaris.
- polaris disk is effectively unbounded for this purpose (user's stated position).

## 5. Components & responsibilities

### Seedbox (ansible repo)
- **`qbittorrent` role (modify):**
  - Keep the podman container, WebUI on the tailnet, categories
    `tv-sonarr → …/tv`, `radarr → …/movies`.
  - **Remove** the NAS rsync path: delete `qbittorrent-nas-sync.{sh,service,timer}`
    templates, the sshpass/NAS tasks, and the `qbittorrent_nas_*` defaults.
  - Global share-limit knobs (`max_ratio`, `max_seeding_minutes`) become
    subordinate to per-tag limits set by `qbit_manage` (below).
- **NFS export (new, small role or fold into `qbittorrent`):** export
  `/mnt/video/Downloads` **read-only** to polaris' tailnet IP only (NFSv4,
  `ro,root_squash`). Read-only is safe because the *arr and `qbit_manage` delete
  via the qBittorrent API / locally on the seedbox — polaris never writes here.
- **`qbit-manage` role (new):** run [`qbit_manage`](https://github.com/StuffAnThings/qbit_manage)
  (podman container, matching the existing pattern) on a timer against the local
  qBittorrent API:
  - Tag each torrent `private`/`public` from its private flag.
  - **Share-limit groups:** `public → max_ratio 0` (action: pause → the *arr then
    removes it post-import); `private → seed to ratio/time` then pause for removal.
  - `rem_unregistered` (drop dead/unregistered private torrents) and
    `rem_orphaned` (delete stray files under the complete dir owned by no torrent).
- **`qbit-autoremove` role (new):** disk-pressure eviction on a short timer:
  - If seedbox free space under the complete-dir filesystem < floor, remove the
    least-in-demand **completed, already-imported** torrents (data included) until
    free ≥ floor.
  - Order: public/idle first; **private only as a last resort** (hit-and-run
    risk), and `log()` every eviction.
  - Candidate tool: [`autoremove-torrents`](https://github.com/jerrymakesjelly/autoremove-torrents)
    (`free_space` strategy) or a small Python script against the API.

### polaris (nixos-config)
- **`modules/media/seedbox-downloads.nix` (new):** an NFS **client** mount of
  `seedbox:/mnt/video/Downloads` at `/mnt/video/Downloads` (matching the path the
  qBittorrent container reports, so **no Remote Path Mapping** is needed), over
  the tailnet, `ro`, with `x-systemd.automount` + `soft`/`nofail` so a seedbox
  blip can't wedge boot.
- **Sonarr/Radarr config (manual, documented in `manual-steps.md`):** download
  client = qBittorrent at the seedbox tailnet IP:8080 (categories as above);
  **Completed Download Handling** on, **import mode = Copy**; **Remove Completed
  Downloads** on (removes via API after import + once seeding is complete — so
  public go immediately, private after ratio). Let `qbit_manage` own the seed
  policy; the *arr just import and remove.

## 6. Requirements → mechanisms

| Requirement | Mechanism |
|---|---|
| **Seed only private after leech** | `qbit_manage` tags private/public and sets per-tag share limits: public `max_ratio 0` (removed post-import), private seeds to ratio. |
| **Auto-delete what's not needed** | *arr "Remove Completed Downloads" (post-import) + `qbit_manage` `rem_unregistered` + `rem_orphaned`. |
| **Free the seedbox disk under pressure** | `qbit-autoremove` timer keyed to the seedbox `df`, evicting least-in-demand already-imported torrents; public/idle first, private last. |

## 7. Open parameters (please set / confirm on review)

| Parameter | Proposed default | Notes |
|---|---|---|
| Mount mechanism | NFS (ro) over tailnet | SSHFS is the alternative if you prefer reusing SSH |
| Mount path on polaris | `/mnt/video/Downloads` | matches container path → no Remote Path Mapping |
| Import mode | Copy | cross-machine; hardlink impossible |
| Public seeding | none (removed after import) | set a small ratio instead if you want to be polite |
| Free-space floor | **?? GB** (need your number) | based on the seedbox disk size |
| "Least in demand" metric | fewest leechers + well-seeded swarm + stale `last_activity` | vs. your own upload speed |
| Eviction "imported?" safety | completed + age-grace (≥1h) | optional stronger check: query Sonarr/Radarr API for import status |
| `qbit_manage` schedule | hourly | |
| `qbit-autoremove` schedule | every 15 min | |

## 8. Repo structure

| File | Repo | Change |
|---|---|---|
| `roles/qbittorrent/*` | ansible | modify: drop NAS rsync; keep container + categories |
| `roles/qbittorrent` NFS export task | ansible | add: export complete dir (ro) to polaris tailnet IP |
| `roles/qbit-manage/*` | ansible | new: qbit_manage container + config + timer |
| `roles/qbit-autoremove/*` | ansible | new: disk-pressure eviction + timer |
| `server.yml` seedbox play | ansible | add the two new roles |
| `modules/media/seedbox-downloads.nix` | nixos-config | new: NFS client mount |
| `machines/polaris.nix` | nixos-config | import the mount module |
| `docs/polaris/manual-steps.md` | nixos-config | document *arr download-client + import settings |

## 9. Migration

- Remove the seedbox→NAS rsync (`qbittorrent-nas-sync` timer/service/script) —
  the *arr import replaces it. The Synology's role in the media path retires.
- `/srv/media/Downloads` on polaris (created earlier for a download-on-polaris
  plan) becomes vestigial in Model 2; downloads live on the seedbox. Leave or drop.
- Existing in-flight torrents keep working; the change is where imports land.

## 10. Prerequisites (operator)

1. Seedbox tailnet IP (`tailscale ip -4` on the seedbox) for the polaris mount.
2. qBittorrent WebUI credentials / API reachable on the tailnet (already is).
3. Decide the free-space floor and confirm the parameters in §7.

## 11. Verification

- A test grab: appears in qBittorrent (seedbox) → Sonarr/Radarr import a **copy**
  into `/srv/media/…` → Plex sees it.
- A **public** torrent is gone from qBittorrent shortly after import; a **private**
  one keeps seeding.
- `qbit_manage` logs show correct private/public tagging + share-limit groups.
- Fill the seedbox past the floor (or lower it temporarily) → `qbit-autoremove`
  removes least-in-demand imported torrents and free space recovers; the polaris
  library copies remain.
- `curl`-checking the swarm IP still shows the seedbox public IP.

## 12. Risks & caveats

- **Duplicate copy:** every item exists on both the seedbox (seed) and polaris
  (library) until the seed is removed — inherent to seeding-from-seedbox.
- **Eviction safety:** we infer "imported" from completed + age (and optionally an
  *arr API check). A mis-inference could evict a not-yet-imported torrent; the
  age-grace + public-first ordering keeps this low-risk. Private eviction risks
  hit-and-run on that tracker — last resort, and logged.
- **NFS over tailnet:** use `soft,nofail,automount` so a seedbox/tailnet blip
  degrades imports gracefully rather than hanging polaris.
- **Container file access:** `qbit_manage`/eviction need the same paths the
  container reports; run them with the complete dir mounted at the identical path.

## 13. Deferred / future

- Backups: the *arr SQLite DBs already covered; qBittorrent config could join.
- Cross-seed / ratio tooling on the seedbox (out of scope now).
- Retiring the Synology entirely once this is proven.

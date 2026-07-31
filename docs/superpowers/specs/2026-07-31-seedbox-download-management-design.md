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
tailnet. Lifecycle (seed policy, cleanup) is handled by **Sonarr/Radarr
themselves**; the only bespoke piece is a **disk-pressure eviction** job that
frees the seedbox disk when it fills.

**In scope:** the data-flow change (replace the NAS rsync with *arr imports over
an NFS mount), the *arr seed/removal configuration, and the seedbox disk-pressure
eviction job.

**Explicitly not in scope:** moving qBittorrent onto polaris; any new WireGuard
tunnel (we reuse the tailnet); `qbit_manage` (see §13 — the *arr cover its job for
a well-run stack; revisit only if cruft accumulates); the *arr↔Prowlarr wiring
(already done); Plex/backups.

## 2. Decisions (locked in discussion)

- **qBittorrent stays on the seedbox** (podman container, existing `qbittorrent`
  role). Downloading and seeding happen on the seedbox's **local disk**, so the
  swarm sees the seedbox IP and **seeding never uses home bandwidth**.
- **polaris is the library.** Sonarr/Radarr **copy** completed downloads into
  `/srv/media/{Series,Movies}`. It's a copy, not a hardlink — the source (seedbox)
  and destination (polaris) are different machines. Standard remote-seedbox
  pattern; home bandwidth is used once per item (the import pull), then never again.
- **Transport is the existing tailnet** — no new secure connection. polaris NFS-
  mounts the seedbox's completed-downloads directory, read-only, restricted to
  polaris' tailnet IP.
- **Sonarr/Radarr own the torrent lifecycle** — seed policy (per-indexer seed
  criteria), import (copy), and removal. Because the import is a cross-machine
  **copy with no hardlink**, only the *arr know an import succeeded, so **only the
  *arr remove** downloads. No `qbit_manage`.
- **Seed policy:** private torrents seed to their tracker's ratio/time; public
  torrents are **not** seeded — removed right after import. Enforced via *arr
  per-indexer seed criteria; qBittorrent's global seed limit stays **unlimited**
  so a mis-configured private indexer keeps seeding (no accidental hit-and-run)
  rather than being force-paused.
- **Disk-pressure eviction** is the one added seedbox job: when the seedbox disk
  fills, evict the least-in-demand **already-imported** torrents, obligation-met
  ones first.

## 3. Architecture & data flow

```
INTERNET (swarm)
   │  leech ▲ / seed ▼   (seedbox public IP; NOT home bandwidth)
┌──┴───────────────────────────────────────────────┐
│ SEEDBOX  (qBittorrent (podman), local disk)       │
│   /var/qbittorrent/downloads/incomplete           │
│   /mnt/video/Downloads/{tv,movies}   (complete)   │
│        │  NFS export (ro) over tailnet            │
│   disk-pressure eviction (systemd timer)          │
└────────┼──────────────────────────────────────────┘
         │  tailnet (existing)         ▲ import = COPY (home bw, once per item)
┌────────┴──────────────────────────────────────────┐
│ POLARIS                                            │
│   mounts seedbox:/mnt/video/Downloads (ro)         │
│   Sonarr/Radarr: import(copy) + seed policy +      │
│     removal → /srv/media/{Series,Movies}  (ZFS)    │
└────────────────────────────────────────────────────┘
```

Lifecycle of one download:
1. qBittorrent (seedbox) downloads to local disk under the right category dir.
2. Sonarr/Radarr (polaris) see it via the qBittorrent API, read it over the NFS
   mount, and **copy** it into the library, renamed/organised for Plex.
3. **Public** torrent → seed criteria = ratio 0, so it's "seeding-complete" at
   once; the *arr remove it (with data) right after import. No seeding.
4. **Private** torrent → seed criteria = the tracker's requirement; qBittorrent
   seeds from local disk until met, then the *arr remove it. The polaris library
   copy is untouched by any removal.
5. If the seedbox disk fills, the eviction job removes the least-in-demand
   **already-imported** torrents early (obligation-met first).

## 4. Bandwidth & disk model (why this shape)

- **Seeding is seedbox-local** → zero home bandwidth for seeding, and native
  seedbox-IP connectability.
- **Home bandwidth** is used only for the one-time import copy per item.
- **The seedbox disk is the constrained resource** (holds active private seeds) →
  hence the eviction job targets the *seedbox's* `df`, not polaris.
- polaris disk is effectively unbounded for this purpose (user's stated position).

## 5. Components & responsibilities

### Seedbox (ansible repo)
- **`qbittorrent` role (modify):**
  - Keep the podman container, WebUI on the tailnet, categories
    `tv-sonarr → …/tv`, `radarr → …/movies`.
  - **Remove** the NAS rsync path: delete `qbittorrent-nas-sync.{sh,service,timer}`
    templates, the sshpass/NAS tasks, and the `qbittorrent_nas_*` defaults.
  - Leave the **global share limit unlimited** (no forced ratio/time), so torrents
    without explicit *arr seed criteria keep seeding rather than being paused —
    protecting private torrents from accidental hit-and-run. "Seed only private"
    is enforced by the *arr per-indexer criteria (public → ratio 0; private →
    tracker requirement), not by a global limit.
- **NFS export (new, small role or fold into `qbittorrent`):** export
  `/mnt/video/Downloads` **read-only** to polaris' tailnet IP only (NFSv4,
  `ro,root_squash`). Read-only is safe — the *arr delete via the qBittorrent API,
  never by writing to this share.
- **`qbit-autoremove` role (new):** disk-pressure eviction on a short systemd
  timer, against the local qBittorrent API. See §6/§7 for the ordering.

### polaris (nixos-config)
- **`modules/media/seedbox-downloads.nix` (new):** an NFS **client** mount of
  `seedbox:/mnt/video/Downloads` at `/mnt/video/Downloads` (matching the path the
  qBittorrent container reports, so **no Remote Path Mapping** is needed), over
  the tailnet, `ro`, with `x-systemd.automount` + `soft`/`nofail` so a seedbox
  blip can't wedge boot.
- **Sonarr/Radarr config (manual, documented in `manual-steps.md`):**
  - Download client = qBittorrent at the seedbox tailnet IP:8080 (categories as
    above); **Completed Download Handling** on, **import mode = Copy**; **Remove
    Completed Downloads** on.
  - **Per-indexer seed criteria** (Settings → Indexers → each indexer): public
    trackers → **Seed Ratio 0 / Seed Time 0** (removed right after import); private
    trackers → the tracker's required ratio/time. This is what makes "seed only
    private" hold, on top of the qBittorrent ratio-0 baseline.

## 6. Requirements → mechanisms

| Requirement | Mechanism |
|---|---|
| **Seed only private after leech** | *arr per-indexer seed criteria (public → ratio 0, private → tracker requirement); qBittorrent global seed limit stays unlimited. |
| **Auto-delete what's not needed** | *arr "Remove Completed Downloads" removes each grab (with data) once imported + seed goal met. |
| **Free the seedbox disk under pressure** | `qbit-autoremove` timer keyed to the seedbox `df` (see ordering below). |

**Eviction ordering** (when free space < floor, remove until free ≥ floor):
1. Only consider **download-complete** torrents past an age-grace (default 2 h;
   so the import has happened) — never touch downloading or not-yet-imported ones.
2. Any **public** leftovers first (should be rare; the *arr already remove them).
3. **Private, seed-obligation met** (qBittorrent state `pausedUP` = share limit
   reached) — zero H&R risk.
4. Only if still under floor: **private, obligation *not* met**, **lowest-share
   first** (fewest leechers / lowest recent upload / stalest activity) — H&R risk;
   `log()` each removal.
5. Never evict a torrent not yet copied to polaris (the age-grace, or an optional
   Sonarr/Radarr API import check).

## 7. Parameters (decided)

| Parameter | Value | Notes |
|---|---|---|
| Mount mechanism | NFS (ro) over tailnet | |
| Mount path on polaris | `/mnt/video/Downloads` | matches container path → no Remote Path Mapping |
| Import mode | Copy | cross-machine; hardlink impossible |
| Public seeding | none (ratio 0, removed after import) | |
| Free-space floor | **10 GB** free | seedbox disk is 197 GB |
| "Least in demand" metric | fewest leechers + well-seeded swarm + stale `last_activity` | |
| Eviction "imported?" safety | **complete + age-grace (2 h)** heuristic; job on the **seedbox** | accepts ~99%; API check is a later upgrade (§13) |
| H&R policy | obligation-met first; unmet only as last resort, logged | |
| `qbit-autoremove` schedule | every 15 min | |

## 8. Repo structure

| File | Repo | Change |
|---|---|---|
| `roles/qbittorrent/*` | ansible | modify: drop NAS rsync; ratio-0 baseline; keep container + categories |
| `roles/qbittorrent` NFS export task | ansible | add: export complete dir (ro) to polaris tailnet IP |
| `roles/qbit-autoremove/*` | ansible | new: disk-pressure eviction + timer |
| `server.yml` seedbox play | ansible | add the new role |
| `modules/media/seedbox-downloads.nix` | nixos-config | new: NFS client mount |
| `machines/polaris.nix` | nixos-config | import the mount module |
| `docs/polaris/manual-steps.md` | nixos-config | document *arr download-client + seed criteria |

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
  one keeps seeding until its ratio/time, then the *arr remove it.
- Fill the seedbox past the floor (or lower it temporarily) → `qbit-autoremove`
  removes least-in-demand imported torrents (obligation-met first) and free space
  recovers; the polaris library copies remain.
- `curl`-checking the swarm IP still shows the seedbox public IP.

## 12. Risks & caveats

- **Duplicate copy:** every item exists on both the seedbox (seed) and polaris
  (library) until the seed is removed — inherent to seeding-from-seedbox.
- **Unregistered-while-seeding (deferred gap):** if a tracker unregisters a private
  torrent *before* your seed goal is met, the *arr wait forever for a goal that
  can't complete, so it lingers. Uncommon; the eviction job mops it up under
  pressure (zero-share, complete). If these pile up, add `qbit_manage`
  `rem_unregistered` (§13).
- **Hit-and-run:** under real disk pressure the eviction job may remove a private
  torrent before its seed obligation is met (step 4) → an H&R strike. Ordering
  puts obligation-met torrents first and logs any encroachment.
- **Eviction safety:** "imported" is inferred from complete + age-grace (optionally
  an *arr API check). Age-grace + public-first keeps a mis-inference low-risk.
- **NFS over tailnet:** use `soft,nofail,automount` so a seedbox/tailnet blip
  degrades imports gracefully rather than hanging polaris.

## 13. Deferred / future

- **`qbit_manage`** — the *arr cover seed policy + removal for a well-run stack, so
  it's dropped for now. Add it back only if dead/unregistered torrents or orphaned
  files actually accumulate; then it would own `rem_unregistered` + `rem_orphaned`
  only (never removal of *arr content — the no-hardlink rule stands).
- **API-based eviction import check** — replace the age-grace heuristic with a
  Sonarr/Radarr history lookup (a `downloadFolderImported` event per torrent hash),
  so a failed/stuck import can never be evicted. That also moves the eviction job
  onto **polaris** (local *arr APIs; still reads the seedbox `df` via the NFS
  mount; deletes via the qBittorrent API over the tailnet). Add if a failed import
  is ever silently evicted.
- Backups: the *arr SQLite DBs already covered; qBittorrent config could join.
- Cross-seed / ratio tooling on the seedbox (out of scope now).
- Retiring the Synology entirely once this is proven.

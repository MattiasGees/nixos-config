# polaris — Manual / Out-of-Band Steps (Operator Runbook)

Everything on polaris that is **not** captured by `nixos-rebuild` and must be done
by hand: secrets that live off git, third-party authentication, DNS records, and
per-service first-run setup. `make switch` builds the OS and services; this file
covers the rest.

> **Golden rule — secrets never go in git.** The Nix config references secret
> *paths* (e.g. `/var/lib/secrets/caddy-route53.env`), never secret *values*.
> Everything in the table below is either placed on the box by hand or rendered
> by op-secrets from 1Password, and, where noted, backed up off-box. Losing an
> item marked **irreplaceable** means data loss, not just reconfiguration.

## Secrets & files that live outside git

| File (on polaris) | Mode / owner | What it is | Backup? |
|-------------------|--------------|-----------|---------|
| `/etc/zfs/keys/polaris.key` | `0400 root` | ZFS encryption key for `fast` + `tank/data` | **Irreplaceable — back up offline** |
| `/var/lib/secrets/caddy-route53.env` | `0600 caddy` | AWS creds for Caddy's Route53 DNS-01, rendered from 1Password by op-secrets (§3) | Reproducible from Terraform / 1Password |
| `/var/lib/secrets/miniflux-admin.env` | `0600 root` | Miniflux `ADMIN_USERNAME`/`ADMIN_PASSWORD` bootstrap, rendered from 1Password by op-secrets (§11) | Reproducible from 1Password |

None of these are in the repo, and none should ever be pasted into a commit,
issue, or chat. `/etc/zfs/keys` is created by hand (during the
[install guide](manual-install-guide.md), step 8/12); the caddy and miniflux
files are rendered automatically at deploy time — see
[op-secrets-manual.md](op-secrets-manual.md).

---

## 1. ZFS encryption key (irreplaceable)

Created during install (`head -c 32 /dev/urandom > /etc/zfs/keys/polaris.key`).
The `fast` pool and the `tank/data` dataset auto-unlock from this file at boot.

**If this file is lost, that data is gone — there is no recovery.** Back it up
now, off the machine, somewhere you control:

```bash
# On polaris, copy it out over SSH to your workstation, then into a password
# manager / offline encrypted store. Do NOT email it or put it in the repo.
sudo cat /etc/zfs/keys/polaris.key | base64        # copy the base64 blob
# restore later with:  echo '<blob>' | base64 -d | sudo tee /etc/zfs/keys/polaris.key ; sudo chmod 0400 ...
```

Verify it still matches the pools after any change:
`sudo zfs get keystatus fast tank/data` → both `available`.

---

## 2. Tailscale (one-time auth)

The module (`modules/server/tailscale.nix`) installs and enables Tailscale, but
the node must be authenticated once:

```bash
sudo tailscale up          # prints a login URL — open it, approve the node
tailscale ip -4            # note the tailnet IP — currently 100.93.157.59
```

The tailnet IP is the stable address used by (a) the seedbox Plex front-door and
(b) the `*.polaris.mattiasgees.be` DNS record below. If it ever changes, update
both.

---

## 3. AWS credentials for Caddy TLS (Route53 DNS-01)

polaris is behind CGNAT, so Caddy proves domain ownership with the **DNS-01**
challenge — it writes a temporary TXT record into Route53. That needs AWS
credentials, provided to the Caddy systemd unit via
`EnvironmentFile=/var/lib/secrets/caddy-route53.env`.

### 3a. Create the IAM user (Terraform)

The IAM user + least-privilege policy is defined in the **infrastructure** repo:
`stacks/kubernetes/polaris-caddy-iam.tf`. It is a plain IAM *user* (not an
OIDC role) because polaris is bare-metal, not in the cluster.

```bash
cd ~/Documents/git/infrastructure/stacks/kubernetes
terraform apply                 # creates user `polaris-caddy` + access key
```

The policy is scoped to the `mattiasgees.be` hosted zone and grants exactly:
`route53:ListHostedZonesByName`, `route53:ListResourceRecordSets`,
`route53:ChangeResourceRecordSets`, `route53:GetChange`.

### 3b. Store the credentials in 1Password

Pull the generated key straight from Terraform state (the secret is marked
`sensitive`, so it only prints with `-raw`):

```bash
terraform output -raw polaris_caddy_access_key_id
terraform output -raw polaris_caddy_secret_access_key
```

This secret is no longer hand-placed on the box. It's rendered from
`op://polaris/caddy-route53/*` to `/var/lib/secrets/caddy-route53.env` by
op-secrets (`modules/server/op-secrets.nix`) at `make switch` time — store the
two key values as the `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` fields on the
`caddy-route53` item in the `polaris` 1Password vault. For bootstrap and
rotation steps, see [op-secrets-manual.md](op-secrets-manual.md).

### 3c. DNS record (Route53)

One wildcard record covers all current and future apps:

| Name | Type | Value |
|------|------|-------|
| `*.polaris.mattiasgees.be` | `A` | `100.93.157.59` (tailnet IP from step 2) |

This is what makes `https://sonarr|radarr|prowlarr.polaris.mattiasgees.be`
resolve to polaris over the tailnet. (The DNS-01 *challenge* records are created
and deleted automatically by Caddy — you don't manage those.)

### 3d. Verify

```bash
journalctl -u caddy -f | grep -iE "obtain|certificate obtained|error"
```

Expect `certificate obtained successfully` for each host. Then load
`https://radarr.polaris.mattiasgees.be` — valid cert, no `ERR_SSL_PROTOCOL_ERROR`.

> **Gotcha (already handled in config):** the `mattiasgees.be` zone uses
> Route53's default **24 h SOA negative-cache TTL**. Because polaris resolves
> only via the LAN router, an early `_acme-challenge` lookup would poison the
> router cache with NXDOMAIN for 24 h and issuance would time out
> (`last error: <nil>`). `modules/media/caddy.nix` avoids this by pointing the
> propagation check at `1.1.1.1`/`8.8.8.8` with a 30 s delay — no action needed,
> but that's why those `resolvers` are there.

---

## 4. Plex remote access (friends behind CGNAT)

Plex serves its own `*.plex.direct` TLS end-to-end; the seedbox is a plain TCP
passthrough (see step 5). Manual Plex-side settings:

1. **Claim the server**: sign in once in the Plex web UI so the server is linked
   to your account.
2. **Settings → Network → Secure connections = `Preferred`** (not Disabled — the
   app validates the `plex.direct` cert).
3. **Settings → Network → Custom server access URLs** — add the seedbox
   front-door, using the server's `plex.direct` hash with **dashes** in the IP:
   ```
   https://85-17-236-99.3741abf55abb4ae28c049d2fbe47d369.plex.direct:32400
   ```
   - `85.17.236.99` = seedbox public IP → dashes.
   - `3741abf55abb4ae28c049d2fbe47d369` = *this server's* plex.direct hash. Find
     it in the cert Plex serves (`openssl s_client -connect 100.93.157.59:32400`
     → look at the `*.HASH.plex.direct` SAN) — it's tied to the server identity,
     so re-derive it if you ever rebuild the Plex database.
4. **Share the library**: Plex UI → your library → Share → invite by email/username.
   Friends don't need the tailnet; they reach it through the seedbox.

---

## 5. Seedbox Plex front-door (Ansible)

The seedbox (Ubuntu VPS, public IP `85.17.236.99`) runs an HAProxy TCP
passthrough that forwards `:32400` to polaris' Plex over the tailnet. It's the
`plex-proxy` role in the **ansible** repo.

```bash
cd ~/Documents/git/ansible
ansible-playbook server.yml --limit seedbox      # deploys/updates HAProxy + iptables
```

- Upstream is `100.93.157.59:32400` (polaris tailnet IP) — update
  `roles/plex-proxy/defaults/main.yml` if the tailnet IP changes.
- It's TCP passthrough, so Plex's own TLS is preserved end-to-end; no certs on
  the seedbox.

---

## 6. First-run app config (in the web UIs)

After `make switch` and TLS is green, configure the *arr apps once. These live in
their SQLite DBs on `/srv/fast/appdata`, not in git.

1. **Prowlarr** (`https://prowlarr.polaris.mattiasgees.be`): add your indexers,
   then **Settings → Apps** → add Sonarr (`http://localhost:8989`) and Radarr
   (`http://localhost:7878`) with each app's API key. Prowlarr syncs indexers to
   both.
2. **Sonarr** (`…/sonarr…`): **Settings → Media Management → Root Folders** →
   add `/srv/media/Series`.
3. **Radarr**: root folder `/srv/media/Movies`.
4. **Download client** — seedbox qBittorrent, wired per section 8 below.

---

## 7. Route indexer / RSS traffic via the seedbox

Make Prowlarr/Sonarr/Radarr fetch from indexers (searches + RSS sync) through the
**seedbox's public IP** instead of the home (CGNAT) IP — for indexers that block
residential IPs or tie an account to a fixed address. This uses the apps' own
Proxy feature, not a Tailscale exit node, so **only these apps** detour; the rest
of polaris is unaffected.

### 7a. Deploy the proxy (Ansible)

An HTTP proxy (`tinyproxy`) runs on the seedbox, **bound to its tailnet IP only**
(`seedbox-proxy` role in the ansible repo):

```bash
cd ~/Documents/git/ansible
ansible-playbook server.yml --limit seedbox      # installs + configures tinyproxy
tailscale ip -4                                   # run on the seedbox: note its tailnet IP
```

It listens on the seedbox tailnet IP, port **8888**, and accepts only the tailnet
range (`100.64.0.0/10`) — never the public interface. Outbound requests still
egress via the seedbox's public IP (that's the point). DNS for the indexers is
resolved on the seedbox, so your home resolver never sees those hostnames.

### 7b. Point each app at it (in the web UIs)

For **all three** (Sonarr/Radarr query indexers directly — Prowlarr only *syncs
the definitions* to them), go to **Settings → General → Proxy**:

| Field | Value |
|-------|-------|
| Use Proxy | ✅ |
| Proxy Type | `HTTP(S)` |
| Hostname | *seedbox tailnet IP* (from 7a) |
| Port | `8888` |
| Bypass Proxy for Local Addresses | ✅ |
| Ignored Addresses | `100.*` |

`Ignored Addresses: 100.*` keeps tailnet-internal traffic (the download client,
Prowlarr↔app sync) direct; only public indexer traffic goes through the proxy.

### 7c. Verify

```bash
# From polaris — should print the SEEDBOX public IP, not your home IP:
curl -x http://<seedbox-tailnet-ip>:8888 https://ifconfig.me ; echo
curl https://ifconfig.me ; echo          # contrast: your home/CGNAT IP
```

Then in Sonarr/Radarr/Prowlarr, an indexer **Test** should still pass. (If a test
fails only when proxied, that indexer may use HTTPS on a non-standard port — add
a matching `ConnectPort` in the role's `tinyproxy.conf.j2`.)

---

## 8. Download client (qBittorrent on the seedbox)

qBittorrent runs on the seedbox, not polaris — Sonarr/Radarr talk to it over the
tailnet, and its completed-downloads dir reaches polaris via the read-only NFS
mount from `modules/media/seedbox-downloads.nix` (`/mnt/media-downloads`, see
[Task 3](../../modules/media/seedbox-downloads.nix)). The mount path is
**identical** to the path the qBittorrent container reports internally, so no
Remote Path Mapping is needed in either app — that's the whole reason the mount
lives at `/mnt/media-downloads` and not somewhere more "natural".

### 8a. Add the download client (in the web UIs)

**Sonarr** → Settings → Download Clients → add **qBittorrent**:

| Field | Value |
|-------|-------|
| Host | seedbox tailnet IP (§ Quick reference) |
| Port | `8080` |
| Category | `tv-sonarr` |

**Radarr** → same, but Category `radarr`.

For both apps:

- **Completed Download Handling**: **on**.
- **Remove Completed Downloads**: **on** — this is what lets the *arr, not a
  cron job, be the sole thing that deletes a torrent from qBittorrent (see
  Global Constraints). They only do this once *their own* import has
  succeeded, which is the signal a blind eviction script can't see.
- **Media Management → Completed Download Handling → Import Mode**: **Copy**,
  never Move/Hardlink — the download lives on the seedbox's filesystem and the
  library on polaris' `tank/data`; hardlinks can't cross a network mount.
- **Remote Path Mapping**: leave empty / do not add one. The NFS mount already
  presents the seedbox path at the same `/mnt/media-downloads` the container
  reports, so a mapping would be redundant (and wrong if it drifted).

### 8b. Seed policy (per-indexer seed criteria)

qBittorrent's **global seed limit stays unlimited** — on purpose. Seeding is
governed per-indexer, in each app's **Settings → Indexers → (edit indexer) →
Seed Ratio / Seed Time**, so a mis-configured global ratio-0 can't accidentally
hit-and-run a private tracker:

| Indexer type | Seed Ratio | Seed Time | Effect |
|---|---|---|---|
| Public | `0` | `0` | Seeding is considered "done" immediately at import; the *arr remove the torrent from qBittorrent right after Completed Download Handling runs. |
| Private | tracker's H&R requirement | tracker's H&R requirement | qBittorrent keeps seeding until the criteria are met; the *arr then remove it. |

This is also why the eviction job on the seedbox (separate task) is only ever
allowed to sweep **download-complete torrents past a 2 h age-grace**, in the
order public → private-obligation-met → last-resort private-unmet-lowest-share:
it must never race a private torrent that's still short of its own seed
criteria.

### 8c. Functional verify (test grab)

1. Grab one **public** item. After import: it appears under `/srv/media/…` (a
   *copy*, not a move), and the torrent disappears from qBittorrent within one
   *arr poll cycle (Seed Ratio/Time = 0 → immediately eligible for removal).
2. Grab one **private** item. After import: it's in `/srv/media/…` **and still
   seeding** in qBittorrent — it stays until its Seed Ratio/Time target is hit.
3. For both, confirm the swarm sees the seedbox, not home: check the tracker
   announce or `curl` the peer IP a client reports — it should be the seedbox's
   **public IP** (`85.17.236.99`), never the CGNAT home IP.

---

## 9. Recyclarr — Sonarr quality profiles (TRaSH)

`recyclarr` (installed system-wide) pushes two quality profiles into Sonarr from
a **declarative config** at `/etc/recyclarr/recyclarr.yml` (managed by
`modules/media/recyclarr.nix`). There's **no timer** — you run it by hand.

Profiles are imported straight from TRaSH by `trash_id` (recyclarr pulls the full
profile — qualities, score set, and its custom formats + scores). **Three** are
installed so you can choose per series:
- **WEB-1080p** (`72dae194…`) — the **default**, untweaked TRaSH profile → h264-first
  (x265 stays at TRaSH's `-10000`).
- **WEB-1080p x265** (same `72dae194…`, renamed) — **size-first**: `x265 (HD)` flipped
  from `-10000` to **`+2000`**, high enough to beat even a top-tier h264 group (e.g.
  `NTb ~+1775`), so any non-junk x265 wins. (Both 1080p profiles reuse one trash_id,
  so each needs an explicit `name:` in `recyclarr.yml`.)
- **WEB-2160p (Combined)** (`c4cadd6b…`) — prefers 4K, falls back to 1080p. Left at
  TRaSH defaults. **Use sparingly** — 4K files are large and will dominate the
  seedbox disk (and its eviction), so assign it only to select series.

### Run it

The config uses `!env_var SONARR_API_KEY` / `!env_var RADARR_API_KEY` (no secret
in git), so provide both keys at sync time. Get each from **Settings → General →
API Key** in Sonarr / Radarr.

```bash
# Dry run first — validates the config and shows changes WITHOUT applying:
SONARR_API_KEY=<key> RADARR_API_KEY=<key> recyclarr sync --config /etc/recyclarr/recyclarr.yml --preview
# Apply:
SONARR_API_KEY=<key> RADARR_API_KEY=<key> recyclarr sync --config /etc/recyclarr/recyclarr.yml
```

Then set each item's **Quality Profile**:
- **Sonarr:** `WEB-1080p x265` (size-first), `WEB-1080p` (h264), or `WEB-2160p (Combined)` (4K).
- **Radarr:** `HD Bluray + WEB x265` (size-first), `HD Bluray + WEB` (h264), or `UHD Bluray + WEB` (4K).

Re-run `recyclarr sync` after editing the config (or to pull TRaSH updates) — it's idempotent.

Notes:
- **Tune the x265 bias:** the `x265 (HD)` override is **+2000** (size-first — beats even
  a top-tier h264 group). Adjust in `modules/media/recyclarr.yml` if you want it looser.
- **Instance names are global:** Sonarr is `main`, Radarr is `movies` — recyclarr
  rejects the whole config if two instances share a name.

### 9a. Propers & Repacks — let the CF scores actually decide (manual, per app)

**This is required for the x265/size scoring above to win — without it a Repack
overrides everything.** Radarr/Sonarr compare a release's *revision*
(Proper/Repack) as part of **quality**, which ranks **above** custom-format
score. So with the default **Prefer and Upgrade**, a Repack wins the quality
comparison *before* CF scores are ever consulted — e.g. a Repack **x264** release
(+2005) is grabbed over a plain **x265** one (+2200), silently defeating the whole
x265 bias.

Fix it once, in **both** apps — **Settings → Media Management → File Management →
Propers and Repacks** → set to **`Do not Prefer`**:

| App | Setting | Value |
|---|---|---|
| Radarr | Media Management → Propers and Repacks | `Do not Prefer` |
| Sonarr | Media Management → Propers and Repacks | `Do not Prefer` |

Now the revision no longer short-circuits the decision; ranking falls through to
CF score, so the recyclarr scores above are authoritative (x265 +2200 beats the
Repack +2005). You don't lose repacks entirely: the TRaSH profiles imported by
`trash_id` already score the **Repack/Proper** custom formats a few points, so a
genuine fix still edges out a broken original — it just can't beat a real
codec/quality lead anymore. This is a Radarr/Sonarr **media-management** setting,
**not** managed by recyclarr, so it must be set by hand (and re-checked if you
ever reset an app's DB).

---

## 10. Subtitles (Bazarr)

Sonarr and Radarr **don't do subtitles** — they only fetch the video. `bazarr`
(`modules/media/bazarr.nix`, `https://bazarr.polaris.mattiasgees.be`, port 6767)
reads their libraries and downloads subtitles from online providers, writing
**sidecar files** (`Movie.en.srt`, `Movie.nl.srt`, `Movie.pt-BR.srt`) next to each
video. Plex's **Local Media Assets** agent (on by default, no Plex Pass needed)
picks them up automatically — nothing to configure on the Plex side.

Nix handles the service, TLS, and permissions; the rest lives in Bazarr's own
SQLite DB (nixpkgs has no declarative config for it), so configure it once in the
web UI:

1. **Connect the apps** — Settings → **Sonarr**: address `localhost`, port `8989`,
   its API key. Settings → **Radarr**: `localhost`, port `7878`, its API key.
   (Same API keys as recyclarr — Settings → General → API Key in each app.) No
   path mapping: Bazarr sees the same `/srv/media/{Series,Movies}` the *arr do.
2. **Languages Profile** — Settings → Languages → create a profile with **English**,
   **Dutch (nl)**, and **Brazilian Portuguese (pt-BR)** — pick *Brazilian*
   Portuguese specifically, Bazarr lists it separately from `pt`. Set it as the
   **default** for both Sonarr and Radarr (Settings → Sonarr/Radarr → Default
   Language Profile), and optionally enable **Series/Movies → Edit → mass-assign**
   for the existing library.
3. **Providers** — Settings → Providers → add at least one (e.g. **OpenSubtitles.com**,
   free account; Podnapisi needs no account). Credentials are entered in the UI,
   so **no secrets in git**.
4. **(optional) Subtitle sync** — Settings → Subtitles → enable "Automatic
   Subtitles Synchronization" so subs are re-timed to the actual video.

Config/DB lives on the fast mirror at `/srv/fast/appdata/bazarr` (created
automatically by the module). Bazarr runs as user `bazarr` in the `media` group,
which is what lets it drop sidecars alongside the media.

---

## 11. Miniflux admin credentials

`modules/media/miniflux.nix` points `services.miniflux.adminCredentialsFile` at
`/var/lib/secrets/miniflux-admin.env`. The module keeps `CREATE_ADMIN = 1` (a
NixOS default), so this file **must exist before the first `make switch` that
enables miniflux** or the unit fails to start.

This secret is no longer hand-placed on the box. It's rendered from
`op://polaris/miniflux/*` to `/var/lib/secrets/miniflux-admin.env` by op-secrets
(`modules/server/op-secrets.nix`) at `make switch` time — reuse the same
password the old k8s deployment used (so nothing is invented by hand) and store
it as the `username`/`password` fields on the `miniflux` item in the `polaris`
1Password vault:

```bash
# workstation (hetzner kubectl context):
PW=$(kubectl get secret miniflux-secrets -n miniflux \
      -o jsonpath='{.data.minifluxPassword}' | base64 -d)
```

After the data migration (`migrate-miniflux.sh`) restores the k8s database, the
`miniflux` admin (and your real `mattias` account) already exist in it, so
`CREATE_ADMIN` is a no-op — you log in with your **existing** credentials. This
credential is then only a break-glass admin. Full cutover order lives in the
migration runbook: `docs/superpowers/plans/2026-08-12-polaris-miniflux.md` (§6)
and its design doc `docs/superpowers/specs/2026-08-12-polaris-miniflux-design.md`.
For bootstrap and rotation steps, see [op-secrets-manual.md](op-secrets-manual.md).

---

## Quick reference

| Thing | Value |
|-------|-------|
| Static LAN IP | `192.168.1.50` (enp6s0) |
| Tailnet IP | `100.93.157.59` |
| Seedbox public IP | `85.17.236.99` |
| Route53 zone | `mattiasgees.be` (`Z2570BL3CYXE68`) |
| App URLs | `https://{sonarr,radarr,prowlarr,bazarr}.polaris.mattiasgees.be` |
| Bazarr (subtitles) | `:6767`, DB `/srv/fast/appdata/bazarr`, langs en+nl+pt-BR |
| Miniflux (RSS) | `https://miniflux.polaris.mattiasgees.be` → `:8080`, DB `miniflux` on shared pg18, secret `/var/lib/secrets/miniflux-admin.env` (§11) |
| App config | `/srv/fast/appdata/<app>` (fast NVMe mirror) |
| Media roots | `/srv/media/{Series,Movies,Downloads}` (`media` group, setgid) |
| ZFS key | `/etc/zfs/keys/polaris.key` (**back up offline**) |
| Caddy AWS creds | `/var/lib/secrets/caddy-route53.env` (`0600 caddy`) |
| Terraform (IAM) | `infrastructure/stacks/kubernetes/polaris-caddy-iam.tf` |
| Seedbox roles | `ansible/roles/{plex-proxy,seedbox-proxy}` |
| Indexer egress proxy | seedbox tailnet IP `:8888` (HTTP, tinyproxy) |
| Seedbox download client | qBittorrent, seedbox tailnet IP `:8080` |
| Seedbox downloads mount | `/mnt/media-downloads` (ro NFS from seedbox, `modules/media/seedbox-downloads.nix`) |

See also: [manual-install-guide.md](manual-install-guide.md) (from-ISO OS + ZFS
setup), [updating.md](updating.md) (flake/Caddy/kernel updates), and
[bios-checklist.md](bios-checklist.md).

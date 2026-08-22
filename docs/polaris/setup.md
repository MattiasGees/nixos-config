# polaris — Setup / Rebuild Guide

How to stand `polaris` back up from a bare NixOS minimal ISO **while keeping the
existing ZFS layout** — the disk you rebuild is the OS disk; your data pools are
imported, never recreated. Use this when:

- the **OS M.2 (NVMe #1) dies** and you fit a replacement, or
- you **move polaris to new hardware** but carry the existing disks over.

**Part 1** rebuilds the OS and re-imports the pools. **Part 2** is the
out-of-band setup (secrets, third-party auth, DNS, per-service first-run config)
that `nixos-rebuild` doesn't capture. For a **first-ever** build, or if the data
pools are genuinely gone (all disks new/wiped), the [Appendix](#appendix--first-time-build-or-total-pool-loss)
creates the pools from scratch instead of importing them.

> **Golden rule — only ever repartition NVMe #1 (the boot disk).** `tank` and the
> surviving half of `fast` hold your data; they are *imported*. Recreating them
> destroys everything. (Secrets golden rule is in Part 2.)

The layout you're rebuilding onto (unchanged):

| Pool | vdev | Mount | Encrypted | Survives an OS-disk death? |
|------|------|-------|-----------|----------------------------|
| `fast` | mirror(NVMe1 part, NVMe2) | `/srv/fast/*` | ✅ keyfile | Yes — degraded on NVMe2, re-attach the NVMe1 half |
| `tank` | raidz1(3× HDD) | `/srv/media`, `/srv/data` | `data` ✅ / `media` ❌ | Yes — untouched, plain import |
| `scratch` | single NVMe1 partition | `/srv/scratch` | ❌ | No — lived on NVMe1, recreated (disposable) |

---

## Part 1 — Rebuild the OS (keep the ZFS layout)

### 1. Boot the installer and get tools

- **BIOS:** UEFI, Secure Boot **off**, SVM/IOMMU on, AHCI (not RAID) — full list
  in [bios-checklist.md](bios-checklist.md).
- Write the **NixOS minimal ISO** (x86_64) to USB, boot it in **UEFI** mode, then
  `sudo -i`.
- **Network:** wired DHCP is automatic — confirm `ping -c2 nixos.org`.
- **Tools** (the minimal ISO lacks some):

  ```bash
  export NIX_CONFIG="experimental-features = nix-command flakes"
  nix-shell -p git gptfdisk zfs
  modprobe zfs && echo "ZFS ready"
  ```

  If `modprobe zfs` errors (`module not found`), the ISO kernel lacks ZFS — grab a
  ZFS-enabled NixOS ISO and start over.

### 2. Identify disks and partition the boot disk **only**

Everything here is destructive — get the device right. Use `by-id` (stable across
reboots):

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE
ls -l /dev/disk/by-id/
NVME1=/dev/disk/by-id/nvme-<NVMe1-2TB>      # the NEW/replacement boot disk
NVME2=/dev/disk/by-id/nvme-<NVMe2-512GB>    # surviving fast mirror half — DO NOT touch
```

Partition **NVMe #1 only** — same layout as the original, because that disk carries
the OS *plus* a `fast` mirror half and `scratch`:

```bash
sgdisk --zap-all "$NVME1"
sgdisk -n1:0:+1G    -t1:EF00 -c1:ESP        "$NVME1"   # EFI System Partition
sgdisk -n2:0:+500G  -t2:8300 -c2:nixos      "$NVME1"   # ext4 root
sgdisk -n3:0:+8G    -t3:8200 -c3:swap       "$NVME1"   # swap
sgdisk -n4:0:+475G  -t4:BF00 -c4:fastmember "$NVME1"   # fast ZFS mirror member
sgdisk -n5:0:0      -t5:BF00 -c5:scratch    "$NVME1"   # rest -> scratch pool
partprobe "$NVME1"; udevadm settle
```

### 3. Format and mount root + boot

```bash
mkfs.vfat -F32 /dev/disk/by-partlabel/ESP
mkfs.ext4      /dev/disk/by-partlabel/nixos
udevadm settle

mount /dev/disk/by-partlabel/nixos /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-partlabel/ESP /mnt/boot
```

Swap needs no `mkswap` — NixOS `randomEncryption` reformats it with a fresh key
each boot.

### 4. Restore the ZFS keyfile

The existing pools are encrypted with the **existing** key — restore it from your
off-box backup (Part 2 §1). Do **not** generate a new one, or the pools won't
unlock:

```bash
install -d -m 0700 /etc/zfs/keys
# if you stored the key base64-encoded (see Part 2 §1):
echo '<base64-blob>' | base64 -d > /etc/zfs/keys/polaris.key
chmod 0400 /etc/zfs/keys/polaris.key
```

### 5. Import the existing pools and repair the boot-disk bits

```bash
zpool import tank                 # clean — the HDDs were untouched
zpool import fast                 # imports DEGRADED (NVMe #1's mirror half was wiped)
```

If either refuses to import because the host identity changed, add `-f`
(`zpool import -f fast`) to clear the "last used by another system" stamp.

Re-attach the `fast` mirror half that lived on the old NVMe #1:

```bash
zpool status fast                 # note the missing/old member id
zpool replace fast <old-nvme1-part-id> /dev/disk/by-partlabel/fastmember
zpool status fast                 # watch it resilver back to ONLINE
```

Recreate `scratch` — it lived on NVMe #1 and was wiped; its contents are
disposable, so that's expected:

```bash
zpool create -f \
  -o ashift=12 -o autotrim=on \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  -O mountpoint=/srv/scratch \
  scratch /dev/disk/by-partlabel/scratch
```

Verify keys load, then persist the keyfile onto the target root and export the
pools so the installed system imports them cleanly at first boot:

```bash
zfs get -o value keystatus tank/data fast   # => available
install -d -m 0700 /mnt/etc/zfs/keys
cp -a /etc/zfs/keys/polaris.key /mnt/etc/zfs/keys/polaris.key
zpool export tank fast scratch              # root stays mounted at /mnt
```

### 6. Install NixOS

```bash
cd /mnt/etc
git clone https://github.com/mattiasgees/nixos-config
cd nixos-config && git checkout mattias
nixos-generate-config --root /mnt
cp /mnt/etc/nixos/hardware-configuration.nix hardware/polaris.nix
```

The replacement boot disk has **new** root/boot UUIDs, so regenerating
`hardware/polaris.nix` is required. **Keep the committed `networking.hostId`** in
`hardware/polaris-extra.nix` — do *not* regenerate it; the existing pools were
created under it. Confirm the NIC name (`ip -o link` → `enp6s0`) in
`machines/polaris.nix`, then install and reboot:

```bash
nixos-install --flake /mnt/etc/nixos-config#polaris   # prompts for a root password
reboot
```

### 7. First-boot verification

```bash
zpool status                                 # fast=mirror, tank=raidz1, scratch=single, all ONLINE
zfs get -o value keystatus tank/data fast    # => available (auto-unlocked)
mount | grep -E '/srv/(media|data|fast|scratch)'
nvidia-smi                                   # RTX 3080 detected
systemctl is-system-running                  # running (or investigate 'degraded')
```

If `keystatus` isn't `available`, check `journalctl -u zfs-load-key`. The OS is now
up — but secrets and per-service setup are **not** done yet. Continue with Part 2.

---

## Part 2 — Out-of-band setup (secrets, auth, per-service)

Everything on polaris that is **not** captured by `nixos-rebuild` and must be done
by hand: secrets that live off git, third-party authentication, DNS records, and
per-service first-run setup. `make switch` builds the OS and services; this file
covers the rest.

> **Golden rule — secrets never go in git.** The Nix config references secret
> *paths* (e.g. `/var/lib/secrets/caddy-route53.env`), never secret *values*.
> Losing an item marked **irreplaceable** means data loss, not just
> reconfiguration.

Only **two** secrets are managed by hand — the roots of trust. Everything the
services actually consume under `/var/lib/secrets/` is *derived* from the second
one: op-secrets renders each file from the `polaris` 1Password vault at every
`make switch` (see the **op-secrets** section for the full list).

| File (on polaris) | Mode / owner | What it is | Backup? |
|-------------------|--------------|-----------|---------|
| `/etc/zfs/keys/polaris.key` | `0400 root` | ZFS encryption key for `fast` + `tank/data` | **Irreplaceable — back up offline** |
| `/etc/op/token` | `0600 root` | 1Password service-account token that unlocks the `polaris` vault for op-secrets (§ op-secrets) | Reproducible — re-issue from 1Password |
| `/var/lib/secrets/*` | `0600` (per-service) | Per-service secrets (caddy, miniflux, restic, karakeep) **rendered automatically** by op-secrets — not hand-placed. See the **op-secrets** section for the item→file map | Reproducible — re-renders from 1Password |

None of these are in the repo, and none should ever be pasted into a commit,
issue, or chat. Only the two roots need a human: `/etc/zfs/keys/polaris.key` is
restored/created during the OS rebuild (Part 1 §4, or the Appendix), and
`/etc/op/token` is placed once (see the **op-secrets** section below). After that,
the `/var/lib/secrets/*` files render themselves on every `make switch`.

---

## op-secrets — 1Password secret rendering (do this first)

Most of polaris' service secrets are **not** hand-placed anymore — a single
1Password service-account token unlocks the `polaris` vault, and `op inject`
renders each secret into `/var/lib/secrets/` at every `make switch`
(`modules/server/op-secrets.nix`). Rendering is atomic and
**last-good-preserving**: if 1Password is unreachable (or the token is missing),
the previously rendered file is kept and the switch still succeeds — a 1Password
outage never blocks a deploy or a boot.

The only bootstrap secret is the token itself at `/etc/op/token`. On a fresh
reinstall, do this **before the first `make switch`** that enables caddy,
miniflux, or restic.

### Secrets rendered from the `polaris` vault

Field names must match **exactly** — the templates reference them by name.

| 1P item | Fields | Rendered to | Consumer |
|---|---|---|---|
| `caddy-route53` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `/var/lib/secrets/caddy-route53.env` | Caddy Route53 DNS-01 (§3) |
| `miniflux` | `username`, `password` | `/var/lib/secrets/miniflux-admin.env` | Miniflux admin bootstrap (§11) |
| `restic` | `repo-password` | `/var/lib/secrets/restic-repo.pass` | restic repo password |
| `restic-backend` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `/var/lib/secrets/restic-backend.env` | restic → Hetzner offsite |
| `karakeep` | `OPENAI_API_KEY` | `/var/lib/secrets/karakeep.env` | Karakeep AI tagging/OCR (§12) |

> Regions are **not** secret and are **not** stored in 1Password — they're
> literals in the templates: caddy uses `AWS_REGION=eu-west-1` (Route53 is
> global; the region is just an SDK formality), restic uses
> `AWS_DEFAULT_REGION=nbg1` (Hetzner object storage).

### Bootstrap (once, on a fresh host)

1. **Create the `polaris` vault** in 1Password with the five items/fields in the
   table above.
2. **Create a service account** with **read** access to **only** the `polaris`
   vault; copy its token (starts with `ops_`).
3. **Place the token** on polaris — the single bootstrap secret:

   ```bash
   sudo install -d -m 0700 /etc/op
   printf '%s' 'ops_PASTE_YOUR_TOKEN' | sudo install -m 0600 /dev/stdin /etc/op/token
   ```

4. **Verify the token reads every reference** before deploying. The 1Password CLI
   is unfree, so an ad-hoc `nix run` needs `NIXPKGS_ALLOW_UNFREE=1` **and**
   `--impure` (so `nix run` reads that env var):

   ```bash
   sudo sh -c 'export OP_SERVICE_ACCOUNT_TOKEN="$(cat /etc/op/token)"; \
     export NIXPKGS_ALLOW_UNFREE=1; \
     for r in \
       op://polaris/caddy-route53/AWS_ACCESS_KEY_ID \
       op://polaris/caddy-route53/AWS_SECRET_ACCESS_KEY \
       op://polaris/miniflux/username \
       op://polaris/miniflux/password \
       op://polaris/restic/repo-password \
       op://polaris/restic-backend/AWS_ACCESS_KEY_ID \
       op://polaris/restic-backend/AWS_SECRET_ACCESS_KEY \
       op://polaris/karakeep/OPENAI_API_KEY; do \
       printf "%s -> " "$r"; \
       nix run --impure nixpkgs#_1password-cli -- read "$r" >/dev/null && echo OK || echo FAIL; \
     done'
   ```

   All eight should print `OK`. Any `FAIL` is a vault/item/field-name mismatch or
   a scope problem — fix it before `make switch`.

5. **Deploy and confirm the render:**

   ```bash
   make switch NIXNAME=polaris
   sudo journalctl -b | grep op-secrets     # "rendered ..." lines, no WARNING
   sudo ls -l /var/lib/secrets/             # the rendered files, root-only dir
   ```

### Rotation

1. Edit the value in 1Password (`polaris` vault).
2. `cd /home/mattias/git/nixos-config && make switch NIXNAME=polaris` — re-renders.
3. `sudo systemctl restart <service>` — an `EnvironmentFile`/`passwordFile` change
   does **not** auto-restart the consuming unit.

To rotate the **bootstrap token**: create a new service-account token in
1Password, re-place `/etc/op/token` (bootstrap step 3), then `make switch`.

### Troubleshooting

- **`op-secrets: WARNING <name> render failed`** in `journalctl` → the template's
  `{{ op://... }}` reference doesn't match a 1P item/field, or the token can't
  read it. The last-good rendered file is kept. Fix the field/scope and
  `make switch`.
- **`op-secrets: no token` and a service won't start** → `/etc/op/token` is
  missing/unreadable and there's no last-good file yet (fresh host). Place the
  token (bootstrap step 3) and `make switch`.
- **Debug a render without writing a file** — once op-secrets is deployed the
  system `op` is on PATH: `op inject -i <template-path>` prints the rendered
  result to stdout. Before the first deploy, via an ad-hoc unfree `nix run`:
  `sudo sh -c 'OP_SERVICE_ACCOUNT_TOKEN="$(cat /etc/op/token)" NIXPKGS_ALLOW_UNFREE=1 nix run --impure nixpkgs#_1password-cli -- inject -i <template-path>'`.

---

## 1. ZFS encryption key (irreplaceable)

Created once during the first build (Appendix §A) and **restored** on every OS
rebuild (Part 1 §4). The `fast` pool and the `tank/data` dataset auto-unlock from
this file at boot.

**If this file is lost, that data is gone — there is no recovery.** This backup is
exactly what Part 1 §4 restores from, so keep it current, off the machine,
somewhere you control:

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

Caddy reads these creds from `/var/lib/secrets/caddy-route53.env`, which
op-secrets (`modules/server/op-secrets.nix`) renders from
`op://polaris/caddy-route53/*` at `make switch` time — store the two key values
as the `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` fields on the `caddy-route53`
item in the `polaris` 1Password vault. For the token bootstrap and rotation, see
the **op-secrets** section above.

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

This secret is rendered from `op://polaris/miniflux/*` to
`/var/lib/secrets/miniflux-admin.env` by op-secrets
(`modules/server/op-secrets.nix`) at `make switch` time — store the admin
`username`/`password` as fields on the `miniflux` item in the `polaris` 1Password
vault. For the token bootstrap and rotation, see the **op-secrets** section
above.

Because the Miniflux database was migrated from the old k8s deployment, the
`miniflux` admin (and your real `mattias` account) already exist in it, so
`CREATE_ADMIN` is a no-op — you log in with your **existing** credentials, and
this rendered file is only a break-glass admin. (The original migration plan and
design are archived in the wiki under **NixOS → Plans / Specs**.)

---

## 12. Karakeep OpenAI key

`modules/media/karakeep.nix` points `services.karakeep.environmentFile` at
`/var/lib/secrets/karakeep.env`, which supplies **`OPENAI_API_KEY`** to the
Karakeep `web` + `workers` units (the workers do the AI auto-tagging and LLM OCR —
`INFERENCE_TEXT_MODEL`/`INFERENCE_IMAGE_MODEL = gpt-4o-mini`, `OCR_USE_LLM = true`,
all set in git). The file is **rendered by op-secrets** from
`op://polaris/karakeep/OPENAI_API_KEY` (template `modules/media/karakeep.env.tpl`)
during `make switch` — same mechanism as caddy and miniflux. It **must render
before the first `make switch` that enables karakeep** or the units fail to start,
so create the 1Password item first.

Everything else Karakeep needs (`NEXTAUTH_SECRET`, `MEILI_MASTER_KEY`) is
**auto-generated** by the module into `/var/lib/karakeep/settings.env` — only the
OpenAI key comes from 1Password.

**Bootstrap the 1Password item** (once). Reuse the same key the old k8s deployment
used; pull it from a workstation that still has the hetzner kubectl context so the
value never lands in the repo, then create item `karakeep` (field `OPENAI_API_KEY`)
in the `polaris` vault:

```bash
# workstation (hetzner kubectl context):
KEY=$(kubectl get secret karakeep-secrets -n karakeep \
      -o jsonpath='{.data.OPENAI_API_KEY}' | base64 -d)
# put $KEY into 1Password: polaris vault, item "karakeep", field "OPENAI_API_KEY"
```

The service account (`/etc/op/token`) already has read access to the whole
`polaris` vault, so no scope change is needed. On the next `make switch NIXNAME=polaris`
op-secrets renders `/var/lib/secrets/karakeep.env` (`0600 karakeep`); rotation is
the standard op-secrets flow (edit in 1Password → `make switch` → `sudo systemctl
restart karakeep-web karakeep-workers`). For the token bootstrap and rotation,
see the **op-secrets** section above.

Karakeep is **SQLite-only** (not a shared-Postgres tenant); its DB + assets live
on the fast mirror at `/srv/fast/appdata/karakeep` (bind-mounted to
`/var/lib/karakeep`) and ride an explicit restic path plus a 02:45 `.backup` +
`.dump` export. (The original k8s → polaris migration runbook and design are
archived in the wiki under **NixOS → Plans / Specs**.)

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
| Karakeep (bookmarks) | `https://karakeep.polaris.mattiasgees.be` → `:3000`, SQLite `/srv/fast/appdata/karakeep`, secret `/var/lib/secrets/karakeep.env` (§12) |
| App config | `/srv/fast/appdata/<app>` (fast NVMe mirror) |
| Media roots | `/srv/media/{Series,Movies,Downloads}` (`media` group, setgid) |
| ZFS key | `/etc/zfs/keys/polaris.key` (**back up offline**) |
| op-secrets token | `/etc/op/token` (`0600 root`) — unlocks the `polaris` 1P vault; renders `/var/lib/secrets/*` at `make switch` (§ op-secrets) |
| Caddy AWS creds | `/var/lib/secrets/caddy-route53.env` (`0600 caddy`) |
| Terraform (IAM) | `infrastructure/stacks/kubernetes/polaris-caddy-iam.tf` |
| Seedbox roles | `ansible/roles/{plex-proxy,seedbox-proxy}` |
| Indexer egress proxy | seedbox tailnet IP `:8888` (HTTP, tinyproxy) |
| Seedbox download client | qBittorrent, seedbox tailnet IP `:8080` |
| Seedbox downloads mount | `/mnt/media-downloads` (ro NFS from seedbox, `modules/media/seedbox-downloads.nix`) |

See also: [updating.md](updating.md) (flake/Caddy/kernel updates) and
[bios-checklist.md](bios-checklist.md) (BIOS/UEFI settings for the rebuild). The
from-ISO OS + ZFS rebuild is Part 1 above; creating the pools from scratch is the
Appendix below.

---

## Appendix — First-time build or total pool loss

Only for a **first-ever** install, or when the data pools are genuinely gone (all
disks new or wiped). This **replaces Part 1 §4–§5** (restore key + import pools)
with pool *creation*. Do Part 1 §1–§3 first (boot, partition NVMe #1, mount root),
then the steps here, then continue at Part 1 §6 (install NixOS).

> **Shortcut.** The repo ships `scripts/create-zfs-pools.sh`, which does A–D below
> (including the keyfile). You're already root with `git`/`zfs` on `PATH`, so:
> ```bash
> git clone https://github.com/mattiasgees/nixos-config
> ( cd nixos-config && git checkout mattias )
> bash nixos-config/scripts/create-zfs-pools.sh \
>   /dev/disk/by-id/nvme-<NVMe2-512GB> \
>   /dev/disk/by-id/ata-<HDD1-14TB> \
>   /dev/disk/by-id/ata-<HDD2-14TB> \
>   /dev/disk/by-id/ata-<HDD3-14TB>
> ```
> The fast-member and scratch partitions come from their fixed GPT partlabels. It
> prints verification when done; then jump to step E to back up the key and export.

### A. Create the encryption keyfile

```bash
install -d -m 0700 /etc/zfs/keys
head -c 32 /dev/urandom > /etc/zfs/keys/polaris.key
chmod 0400 /etc/zfs/keys/polaris.key
```

One 32-byte random key unlocks the encrypted datasets (`fast/*`, `tank/data`).
Stored as a file (`keylocation=file://…`) so the headless server reboots
unattended.

### B. Create the `fast` pool (NVMe mirror, encrypted)

```bash
zpool create -f \
  -o ashift=12 -o autotrim=on \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  -O encryption=aes-256-gcm -O keyformat=raw \
  -O keylocation=file:///etc/zfs/keys/polaris.key \
  -O mountpoint=none \
  fast mirror \
    /dev/disk/by-partlabel/fastmember \
    "$NVME2"

zfs create -o mountpoint=/srv/fast/appdata fast/appdata
zfs create -o mountpoint=/srv/fast/db      fast/db
```

`ashift=12` (4K sectors, immutable after creation); `mirror` survives either
device failing.

### C. Create the `tank` pool (HDD RAIDZ1)

```bash
# set the three HDD by-id paths (in addition to NVME1/NVME2 from Part 1 §2):
HDD1=/dev/disk/by-id/ata-<HDD1-14TB>
HDD2=/dev/disk/by-id/ata-<HDD2-14TB>
HDD3=/dev/disk/by-id/ata-<HDD3-14TB>

zpool create -f \
  -o ashift=12 \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  -O mountpoint=none \
  tank raidz1 "$HDD1" "$HDD2" "$HDD3"

# media: replaceable, already-compressed files -> lz4 + big records, no encryption
zfs create -o mountpoint=/srv/media -o compression=lz4 -o recordsize=1M tank/media

# data: personal/bulk data -> its own encryptionroot
zfs create -o mountpoint=/srv/data \
  -o encryption=aes-256-gcm -o keyformat=raw \
  -o keylocation=file:///etc/zfs/keys/polaris.key \
  tank/data
```

`raidz1` across the three 14 TB disks = ~28 TB usable, survives one disk failing.

### D. Create the `scratch` pool (single NVMe, no redundancy)

```bash
zpool create -f \
  -o ashift=12 -o autotrim=on \
  -O compression=zstd -O atime=off -O xattr=sa -O acltype=posixacl \
  -O mountpoint=/srv/scratch \
  scratch /dev/disk/by-partlabel/scratch
```

Disposable NVMe space (transcode temp, download staging, caches). One disk = no
redundancy — keep nothing precious here.

### E. Verify, back up the key, and export

```bash
zpool status                                  # fast=mirror, tank=raidz1, scratch=single, all ONLINE
zfs list                                      # datasets present under /srv
zfs get -o value keystatus tank/data fast     # => available

install -d -m 0700 /mnt/etc/zfs/keys
cp -a /etc/zfs/keys/polaris.key /mnt/etc/zfs/keys/polaris.key
zpool export tank fast scratch                # clean stamp for first-boot import
```

> **Back up `/etc/zfs/keys/polaris.key` off the machine right now** (password
> manager). Lose it and every encrypted dataset is gone forever — see Part 2 §1.

Then continue at **Part 1 §6** (install NixOS).

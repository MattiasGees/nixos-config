# polaris — Setup / Rebuild Guide

How to stand `polaris` back up from a bare NixOS minimal ISO **while keeping the
existing ZFS layout** — the disk you rebuild is the OS disk; your data pools are
imported, never recreated. Use this when:

- the **OS M.2 (NVMe #1) dies** and you fit a replacement, or
- you **move polaris to new hardware** but carry the existing disks over.

**Part 1** rebuilds the OS and re-imports the pools. **Part 2** is the host-side
out-of-band setup (secrets, third-party auth, DNS) that `nixos-rebuild` doesn't
capture. For a **first-ever** build, or if the data
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

## Part 2 — Out-of-band setup (secrets, auth, DNS)

Everything on polaris that is **not** captured by `nixos-rebuild` and must be done
by hand: secrets that live off git, third-party authentication, and DNS records.
`make switch` builds the OS and services; this section covers the host-side rest.

> **Golden rule — secrets never go in git.** The Nix config references secret
> *paths* (e.g. `/var/lib/secrets/caddy-route53.env`), never secret *values*.
> Losing an item marked **irreplaceable** means data loss, not just
> reconfiguration.

Only **two** secrets are managed by hand — the roots of trust. Everything the
services actually consume under `/var/lib/secrets/` is *derived* from the second
one: op-secrets renders each file from the `polaris` 1Password vault at every
`make switch` (the **op-secrets** section lists them).

| File (on polaris) | Mode / owner | What it is | Backup? |
|-------------------|--------------|-----------|---------|
| `/etc/zfs/keys/polaris.key` | `0400 root` | ZFS encryption key for `fast` + `tank/data` | **Irreplaceable — back up offline** |
| `/etc/op/token` | `0600 root` | 1Password service-account token that unlocks the `polaris` vault for op-secrets (§ op-secrets) | Reproducible — re-issue from 1Password |
| `/var/lib/secrets/*` | `0600` (per-service) | Per-service secrets (caddy, miniflux, restic, karakeep) **rendered automatically** by op-secrets — not hand-placed (see the **op-secrets** section) | Reproducible — re-renders from 1Password |

None of these are in the repo, and none should ever be pasted into a commit,
issue, or chat. Only the two roots need a human: `/etc/zfs/keys/polaris.key` is
restored/created during the OS rebuild (Part 1 §4, or the Appendix), and
`/etc/op/token` is placed once (see the **op-secrets** section below). After that,
the `/var/lib/secrets/*` files render themselves on every `make switch`.

---

## op-secrets — 1Password service-account token (do this first)

The per-service secrets under `/var/lib/secrets/` render themselves from the
`polaris` 1Password vault at `make switch`. The only thing you place by hand is
the service-account token — once, **before the first `make switch`**.

1. **Create the `polaris` vault** in 1Password with the items/fields referenced in
   the verification below (`caddy-route53`, `miniflux`, `restic`, `restic-backend`,
   `karakeep`).
2. **Create a service account** with **read** access to **only** the `polaris`
   vault; copy its token (starts with `ops_`).
3. **Place the token** on polaris:

   ```bash
   sudo install -d -m 0700 /etc/op
   printf '%s' 'ops_PASTE_YOUR_TOKEN' | sudo install -m 0600 /dev/stdin /etc/op/token
   ```

4. **Verify the token reads every reference.** The 1Password CLI is unfree, so an
   ad-hoc `nix run` needs `NIXPKGS_ALLOW_UNFREE=1` and `--impure`:

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

   All eight must print `OK` before you `make switch`. A `FAIL` is a
   vault/item/field-name mismatch or a scope problem.

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

### 3a. AWS credentials (1Password)

Caddy reads the creds from `/var/lib/secrets/caddy-route53.env`, which op-secrets
(`modules/server/op-secrets.nix`) renders from `op://polaris/caddy-route53/*` at
`make switch` — store the access key as the `AWS_ACCESS_KEY_ID`/
`AWS_SECRET_ACCESS_KEY` fields on the `caddy-route53` item in the `polaris` vault.
The key belongs to the `polaris-caddy` IAM user defined in the infrastructure
repo (see the Quick reference); on a rebuild it already exists and the creds are
already in 1Password.

### 3b. DNS record (Route53)

One wildcard record covers all current and future apps:

| Name | Type | Value |
|------|------|-------|
| `*.polaris.mattiasgees.be` | `A` | `100.93.157.59` (tailnet IP from step 2) |

This is what makes `https://sonarr|radarr|prowlarr.polaris.mattiasgees.be`
resolve to polaris over the tailnet. (The DNS-01 *challenge* records are created
and deleted automatically by Caddy — you don't manage those.)

### 3c. Verify

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

## 4. Miniflux admin credentials

`modules/media/miniflux.nix` points `services.miniflux.adminCredentialsFile` at
`/var/lib/secrets/miniflux-admin.env`. The module keeps `CREATE_ADMIN = 1` (a
NixOS default), so this file **must exist before the first `make switch` that
enables miniflux** or the unit fails to start.

This secret is rendered from `op://polaris/miniflux/*` to
`/var/lib/secrets/miniflux-admin.env` by op-secrets
(`modules/server/op-secrets.nix`) at `make switch` time — store the admin
`username`/`password` as fields on the `miniflux` item in the `polaris` 1Password
vault. For the token bootstrap, see the **op-secrets** section above.

---

## 5. Karakeep OpenAI key

`modules/media/karakeep.nix` supplies **`OPENAI_API_KEY`** to Karakeep from
`/var/lib/secrets/karakeep.env`, which op-secrets renders from
`op://polaris/karakeep/OPENAI_API_KEY` at `make switch` — store it as the
`OPENAI_API_KEY` field on the `karakeep` item in the `polaris` vault. It **must
render before the first `make switch` that enables karakeep** or the units fail to
start. (`NEXTAUTH_SECRET`/`MEILI_MASTER_KEY` are auto-generated by the module.)
For the token bootstrap, see the **op-secrets** section above.

---

## Quick reference

| Thing | Value |
|-------|-------|
| Static LAN IP | `192.168.1.50` (enp6s0) |
| Tailnet IP | `100.93.157.59` |
| Route53 zone | `mattiasgees.be` (`Z2570BL3CYXE68`) |
| ZFS key | `/etc/zfs/keys/polaris.key` (**back up offline**) |
| op-secrets token | `/etc/op/token` (`0600 root`) — unlocks the `polaris` 1P vault; renders `/var/lib/secrets/*` at `make switch` (§ op-secrets) |
| Caddy AWS creds | `/var/lib/secrets/caddy-route53.env` (`0600 caddy`) |
| Terraform (IAM) | `infrastructure/stacks/kubernetes/polaris-caddy-iam.tf` |
| Miniflux (RSS) | `https://miniflux.polaris.mattiasgees.be` → `:8080`, secret `/var/lib/secrets/miniflux-admin.env` (§4) |
| Karakeep (bookmarks) | `https://karakeep.polaris.mattiasgees.be` → `:3000`, secret `/var/lib/secrets/karakeep.env` (§5) |
| App config | `/srv/fast/appdata/<app>` (fast NVMe mirror) |
| Media roots | `/srv/media/{Series,Movies,Downloads}` (`media` group, setgid) |

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

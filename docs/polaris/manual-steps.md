# polaris — Manual / Out-of-Band Steps (Operator Runbook)

Everything on polaris that is **not** captured by `nixos-rebuild` and must be done
by hand: secrets that live off git, third-party authentication, DNS records, and
per-service first-run setup. `make switch` builds the OS and services; this file
covers the rest.

> **Golden rule — secrets never go in git.** The Nix config references secret
> *paths* (e.g. `/etc/caddy/route53.env`), never secret *values*. Everything in
> the table below is placed on the box by hand and, where noted, backed up
> off-box. Losing an item marked **irreplaceable** means data loss, not just
> reconfiguration.

## Secrets & files that live outside git

| File (on polaris) | Mode / owner | What it is | Backup? |
|-------------------|--------------|-----------|---------|
| `/etc/zfs/keys/polaris.key` | `0400 root` | ZFS encryption key for `fast` + `tank/data` | **Irreplaceable — back up offline** |
| `/etc/caddy/route53.env` | `0600 root` | AWS creds for Caddy's Route53 DNS-01 | Reproducible from Terraform |

Neither is in the repo, and neither should ever be pasted into a commit, issue,
or chat. `/etc/caddy` and `/etc/zfs/keys` are created by hand (the latter during
the [install guide](manual-install-guide.md), step 8/12).

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
`EnvironmentFile=/etc/caddy/route53.env`.

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

### 3b. Write the credentials onto polaris

Pull the generated key straight from Terraform state (the secret is marked
`sensitive`, so it only prints with `-raw`):

```bash
terraform output -raw polaris_caddy_access_key_id
terraform output -raw polaris_caddy_secret_access_key
```

Put them in `/etc/caddy/route53.env` on polaris — systemd `EnvironmentFile`
format, so **plain `KEY=value`, no `export`, no quotes** (the secret contains
`/` and `+`, which must stay literal):

```bash
sudo install -d -m 0755 /etc/caddy
sudo install -m 0600 /dev/null /etc/caddy/route53.env
sudo tee /etc/caddy/route53.env >/dev/null <<'EOF'
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=us-east-1
EOF
sudo chmod 0600 /etc/caddy/route53.env      # root-only; systemd reads it as root
sudo systemctl restart caddy
```

`AWS_REGION` is required by the AWS SDK even though Route53 is global;
`us-east-1` is the conventional value.

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
4. **Download client** — *next phase*, not wired yet (seedbox qBittorrent →
   `/srv/media/Downloads`). Until then the apps run and are reachable but have no
   download path.

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

## Quick reference

| Thing | Value |
|-------|-------|
| Static LAN IP | `192.168.1.50` (enp6s0) |
| Tailnet IP | `100.93.157.59` |
| Seedbox public IP | `85.17.236.99` |
| Route53 zone | `mattiasgees.be` (`Z2570BL3CYXE68`) |
| App URLs | `https://{sonarr,radarr,prowlarr}.polaris.mattiasgees.be` |
| App config | `/srv/fast/appdata/<app>` (fast NVMe mirror) |
| Media roots | `/srv/media/{Series,Movies,Downloads}` (`media` group, setgid) |
| ZFS key | `/etc/zfs/keys/polaris.key` (**back up offline**) |
| Caddy AWS creds | `/etc/caddy/route53.env` (`0600 root`) |
| Terraform (IAM) | `infrastructure/stacks/kubernetes/polaris-caddy-iam.tf` |
| Seedbox roles | `ansible/roles/{plex-proxy,seedbox-proxy}` |
| Indexer egress proxy | seedbox tailnet IP `:8888` (HTTP, tinyproxy) |

See also: [manual-install-guide.md](manual-install-guide.md) (from-ISO OS + ZFS
setup), [updating.md](updating.md) (flake/Caddy/kernel updates), and
[bios-checklist.md](bios-checklist.md).

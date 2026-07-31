# Seedbox qBittorrent + polaris Library — Download Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move qBittorrent's downloads into the media stack (seedbox = working disk, polaris = library, imports over NFS on the tailnet) and add automatic seedbox disk-pressure eviction — per `docs/superpowers/specs/2026-07-31-seedbox-download-management-design.md`.

**Architecture:** qBittorrent stays on the seedbox (podman). Sonarr/Radarr on polaris import (copy) completed downloads over a read-only NFS mount of the seedbox's complete dir. Seed policy + removal are owned by the *arr. One bespoke job (`qbit-autoremove`) runs on the seedbox and evicts already-imported, least-in-demand torrents when free space drops below a floor.

**Tech Stack:** Ansible (seedbox: Ubuntu, podman qBittorrent, NFSv4 server, Python 3, systemd timers) · NixOS flake (polaris: `fileSystems` NFS client) · Python 3 for the eviction script (pytest).

**Two repos:**
- **ansible** — `~/Documents/git/ansible` (branch off `master`, PR like `plex-proxy`).
- **nixos-config** — `~/Documents/git/nixos-config` (branch `mattias`).

## Global Constraints

- **Transport is the existing tailnet.** No new WireGuard/secure connection. The NFS export is restricted to polaris' tailnet IP `100.93.157.59` and served over the `tailscale0` interface only.
- **NFS export is read-only** to polaris. The *arr delete via the qBittorrent API, never by writing to the share.
- **Only the *arr remove torrents** (they alone know an import succeeded — the cross-machine copy has no hardlink signal). The eviction job is the sole exception and only ever removes **download-complete torrents past a 2 h age-grace**.
- **qBittorrent global seed limit stays UNLIMITED.** "Seed only private" is enforced by *arr per-indexer seed criteria (public → ratio 0 / time 0; private → the tracker's requirement) — never by a global ratio-0 (that would risk H&R on a mis-configured private indexer).
- **Eviction free-space floor = 10 GB** (seedbox disk is 197 GB). Eviction order: public first → private-obligation-met → (last resort, logged) private-unmet lowest-share. Never evict a not-yet-imported (within-grace) torrent.
- **Mount path on polaris is `/mnt/media-downloads`** — identical to the path the qBittorrent container reports, so **no Remote Path Mapping** is needed in the *arr.
- No secrets in git. qBittorrent WebUI creds / any API password stay in existing vault/host files.
- Verification = successful deploy + functional check (no CI). For the eviction script, verification = pytest on its pure selection logic.

## File Structure

**ansible repo:**
- `roles/qbittorrent/defaults/main.yml` — modify: drop `qbittorrent_nas_*`; set unlimited seed baseline.
- `roles/qbittorrent/tasks/main.yml` — modify: remove NAS-sync tasks; add NFS export tasks.
- `roles/qbittorrent/templates/qbittorrent-nas-sync.{sh,service,timer}.j2` — delete.
- `roles/qbittorrent/templates/qBittorrent.conf.j2` — modify: unlimited global share limit.
- `roles/qbittorrent/templates/exports.j2` — create: `/etc/exports.d/qbittorrent.exports`.
- `roles/qbit-autoremove/{defaults,tasks,handlers,files,templates}/…` — create: eviction script + timer.
- `server.yml` — modify: add `qbit-autoremove` to the `seedbox` play.

**nixos-config repo:**
- `modules/media/seedbox-downloads.nix` — create: NFS client mount.
- `machines/polaris.nix` — modify: import the mount module.
- `docs/polaris/manual-steps.md` — modify: §8 *arr download-client + seed-criteria + eviction operator notes.

---

### Task 1: qBittorrent role — remove NAS rsync, set unlimited seed baseline

**Files (ansible repo):**
- Modify: `roles/qbittorrent/defaults/main.yml`
- Modify: `roles/qbittorrent/tasks/main.yml`
- Modify: `roles/qbittorrent/templates/qBittorrent.conf.j2`
- Delete: `roles/qbittorrent/templates/qbittorrent-nas-sync.{sh,service,timer}.j2`

**Interfaces:**
- Produces: qBittorrent on the seedbox with categories `tv-sonarr → /mnt/media-downloads/tv`, `radarr → /mnt/media-downloads/movies`, WebUI on the tailnet:8080, **no** NAS-sync timer, **unlimited** global seed limit.

- [ ] **Step 1: Remove the NAS-sync tasks.** In `roles/qbittorrent/tasks/main.yml`, delete every task related to NAS sync: "Install sshpass", "Install NAS SSH password file", "Install NAS sync script", "Install NAS sync systemd service", "Install NAS sync systemd timer", "Enable and start NAS sync timer". Also delete the now-unused `/etc/qbittorrent` dir task **only if** it was solely for the NAS secret (keep it if other tasks use it).

- [ ] **Step 2: Delete the NAS-sync templates.**
```bash
cd ~/Documents/git/ansible
git rm roles/qbittorrent/templates/qbittorrent-nas-sync.sh.j2 \
       roles/qbittorrent/templates/qbittorrent-nas-sync.service.j2 \
       roles/qbittorrent/templates/qbittorrent-nas-sync.timer.j2
```

- [ ] **Step 3: Remove NAS defaults.** In `roles/qbittorrent/defaults/main.yml`, delete all `qbittorrent_nas_*` vars and `qbittorrent_sync_subdirs` / `qbittorrent_sync_interval`.

- [ ] **Step 4: Set the unlimited seed baseline.** In `roles/qbittorrent/defaults/main.yml` set:
```yaml
# Global seed limit: UNLIMITED. "Seed only private" is enforced by the *arr
# per-indexer seed criteria, NOT a global ratio — a global ratio-0 would risk
# hit-and-run on a mis-configured private indexer.
qbittorrent_max_ratio: -1          # -1 = no global ratio limit
qbittorrent_max_seeding_minutes: -1
# Rename the completed-downloads dir away from the Synology-era "video" name.
# Cascades to the categories (…/tv, …/movies), the dir-creation task, and the
# container bind mount, which all reference qbittorrent_complete_dir.
qbittorrent_complete_dir: /mnt/media-downloads     # was /mnt/video/Downloads
```
And in `roles/qbittorrent/templates/qBittorrent.conf.j2` ensure the share-limit keys render `-1` (no forced pause). Confirm the rendered keys match this qBittorrent version (5.0.3) — e.g. `Session\GlobalMaxRatio=-1`, `Session\GlobalMaxSeedingMinutes=-1`. If the template hard-codes an action, leave `MaxRatioAction` unused since the limit is `-1`.

- [ ] **Step 5: Syntax-check.**
```bash
cd ~/Documents/git/ansible
TMP=$(mktemp --suffix=.yml); printf -- '---\n- hosts: localhost\n  gather_facts: false\n  roles: [qbittorrent]\n' > "$TMP"
ANSIBLE_ROLES_PATH="$(pwd)/roles" ansible-playbook --syntax-check "$TMP"
```
Expected: parses with no error (only the "no inventory" warnings).

- [ ] **Step 6: Deploy and verify.**
```bash
ansible-playbook server.yml --limit seedbox --tags qbittorrent   # or without --tags
# on the seedbox:
systemctl status qbittorrent            # active
systemctl list-timers | grep nas-sync   # -> empty (timer gone)
```
Expected: qBittorrent active; the `qbittorrent-nas-sync.timer` no longer present. (Leftover unit files may remain until removed; note in the report if a manual `systemctl disable --now qbittorrent-nas-sync.timer` + file cleanup is needed on the box.)

**Migration note (path rename):** any in-flight torrents still point at the old `/mnt/video/Downloads`. Before/at deploy, either drain them or relocate: move the data (`mv /mnt/video/Downloads/* /mnt/media-downloads/`) and set each torrent's location to the new path in qBittorrent (Set Location → `/mnt/media-downloads/{tv,movies}`), then force-recheck. The old `/mnt/video` mountpoint/folder can then be removed. Do this before enabling the NFS export (Task 2) so polaris mounts the populated new path.

- [ ] **Step 7: Commit.**
```bash
git add -A roles/qbittorrent
git commit -m "feat(qbittorrent): drop NAS rsync; unlimited seed baseline"
```

---

### Task 2: qBittorrent role — NFS export of the complete dir (read-only) to polaris

**Files (ansible repo):**
- Create: `roles/qbittorrent/templates/exports.j2`
- Modify: `roles/qbittorrent/tasks/main.yml`
- Modify: `roles/qbittorrent/defaults/main.yml`

**Interfaces:**
- Consumes: `qbittorrent_complete_dir` (`/mnt/media-downloads`).
- Produces: an NFSv4 export of `/mnt/media-downloads` to polaris' tailnet IP, read-only, reachable over `tailscale0` on port 2049.

- [ ] **Step 1: Add export defaults.** In `roles/qbittorrent/defaults/main.yml`:
```yaml
# NFS export of the completed-downloads dir to polaris (read-only, tailnet only).
# polaris imports (copies) from here; it never writes, so ro is safe.
qbittorrent_nfs_client_ip: "100.93.157.59"   # polaris tailnet IP
qbittorrent_tailscale_interface: "tailscale0"
```

- [ ] **Step 2: Create the exports template** `roles/qbittorrent/templates/exports.j2`:
```jinja
# {{ ansible_managed }} — qbittorrent role. Completed-downloads export to polaris.
{{ qbittorrent_complete_dir }} {{ qbittorrent_nfs_client_ip }}(ro,sync,no_subtree_check,root_squash,fsid=0)
```

- [ ] **Step 3: Add NFS tasks** to `roles/qbittorrent/tasks/main.yml` (after the container is up):
```yaml
- name: Install NFS server
  ansible.builtin.apt:
    name: nfs-kernel-server
    state: present
    update_cache: true

- name: Configure the completed-downloads NFS export
  ansible.builtin.template:
    src: exports.j2
    dest: /etc/exports.d/qbittorrent.exports
    owner: root
    group: root
    mode: "0644"
  notify: Re-export NFS

- name: Ensure nfs-server is enabled and running
  ansible.builtin.systemd:
    name: nfs-server
    enabled: true
    state: started

- name: Allow NFSv4 (2049/tcp) on the tailscale interface from polaris only
  ansible.builtin.iptables:
    chain: INPUT
    in_interface: "{{ qbittorrent_tailscale_interface }}"
    source: "{{ qbittorrent_nfs_client_ip }}"
    protocol: tcp
    destination_port: "2049"
    jump: ACCEPT
  notify: Persist iptables rules
```

- [ ] **Step 4: Add handlers.** In `roles/qbittorrent/handlers/main.yml` (create if absent):
```yaml
---
- name: Re-export NFS
  ansible.builtin.command: exportfs -ra
  changed_when: true

- name: Persist iptables rules
  ansible.builtin.shell:
    cmd: iptables-save > /etc/iptables/rules.v4
```

- [ ] **Step 5: Deploy and verify the export.**
```bash
ansible-playbook server.yml --limit seedbox
# on the seedbox:
exportfs -v            # shows /mnt/media-downloads to 100.93.157.59 (ro)
ss -tlnp | grep 2049   # nfsd listening
```
Expected: the export is listed, read-only, to the polaris IP.

- [ ] **Step 6: Commit.**
```bash
git add -A roles/qbittorrent
git commit -m "feat(qbittorrent): NFSv4 export of complete dir (ro) to polaris"
```

---

### Task 3: polaris — NFS client mount of the seedbox complete dir

**Files (nixos-config repo):**
- Create: `modules/media/seedbox-downloads.nix`
- Modify: `machines/polaris.nix`

**Interfaces:**
- Consumes: the NFS export from Task 2 (seedbox tailnet IP, `/mnt/media-downloads`).
- Produces: `/mnt/media-downloads` on polaris, read-only, automounted, showing the seedbox's `tv/` and `movies/` dirs.

- [ ] **Step 1: Create the mount module** `modules/media/seedbox-downloads.nix`:
```nix
# Read-only NFS mount of the seedbox's completed-downloads dir, over the tailnet.
# Sonarr/Radarr import (copy) from here into /srv/media. Mounted at the SAME path
# the qBittorrent container reports (/mnt/media-downloads) so the *arr need no
# Remote Path Mapping. automount + soft + nofail: a seedbox/tailnet blip degrades
# imports gracefully instead of hanging polaris.
{ ... }:
let
  seedboxTailnetIp = "SEEDBOX_TAILNET_IP";  # BUILD-TIME: `tailscale ip -4` on the seedbox
in
{
  fileSystems."/mnt/media-downloads" = {
    device = "${seedboxTailnetIp}:/mnt/media-downloads";
    fsType = "nfs";
    options = [
      "ro" "nfsvers=4" "soft" "nofail"
      "x-systemd.automount" "x-systemd.idle-timeout=600"
      "timeo=50" "retrans=2"
    ];
  };
}
```

- [ ] **Step 2: Import it in `machines/polaris.nix`.** Add `../modules/media/seedbox-downloads.nix` to the `imports = [ … ]` list (next to the other `modules/media/*`).

- [ ] **Step 3: Fill the seedbox tailnet IP.** Replace `SEEDBOX_TAILNET_IP` with the value from `tailscale ip -4` on the seedbox.

- [ ] **Step 4: Build, switch, verify.**
```bash
cd ~/Documents/git/nixos-config
sudo nixos-rebuild build --flake .#polaris --impure    # builds clean
make switch NIXNAME=polaris
ls /mnt/media-downloads                                # -> tv  movies (from the seedbox)
findmnt /mnt/media-downloads                           # nfs4, ro
```
Expected: the seedbox's completed-downloads dirs are visible read-only. (First `ls` triggers the automount.)

- [ ] **Step 5: Commit (branch `mattias`).**
```bash
git add modules/media/seedbox-downloads.nix machines/polaris.nix
git commit -m "feat(media): mount seedbox completed-downloads over NFS (ro)"
```

---

### Task 4: Sonarr/Radarr wiring + operator docs

**Files (nixos-config repo):**
- Modify: `docs/polaris/manual-steps.md`

This task is **operator UI config** captured as documentation; the "deliverable" is the runbook section plus a verified test grab. No code build.

**Interfaces:**
- Consumes: the mount (Task 3), qBittorrent on the seedbox tailnet IP:8080.

- [ ] **Step 1: Document the download client + import settings** in a new `manual-steps.md` section "Download client (qBittorrent on the seedbox)":
  - Sonarr/Radarr → Settings → Download Clients → add qBittorrent: host = seedbox tailnet IP, port 8080, category `tv-sonarr` (Sonarr) / `radarr` (Radarr).
  - Completed Download Handling: **on**; **Remove Completed Downloads: on**.
  - Import mode: **Copy** (Media Management → set to Copy, since hardlink is impossible cross-machine).
  - **No** Remote Path Mapping (mount path matches the container path).

- [ ] **Step 2: Document the seed policy (per-indexer seed criteria).** In the same section:
  - Public trackers → each indexer's **Seed Ratio = 0** and **Seed Time = 0** → the *arr consider seeding done at import and remove the download (no public seeding).
  - Private trackers → each indexer's **Seed Ratio / Seed Time** = the tracker's H&R requirement → seeds until met, then the *arr remove it.
  - Note the qBittorrent global seed limit is unlimited on purpose (protects a forgotten private indexer from H&R).

- [ ] **Step 3: Functional verify with a test grab** (document the exact expected outcomes):
  - Grab one **public** item → after import it appears under `/srv/media/…` (a copy), and the torrent is gone from qBittorrent within a poll cycle.
  - Grab one **private** item → after import it's in `/srv/media/…` and still seeding in qBittorrent.
  - Both: the swarm IP check (`curl` from a peer / tracker announce) shows the seedbox public IP.

- [ ] **Step 4: Commit.**
```bash
git add docs/polaris/manual-steps.md
git commit -m "docs(polaris): document seedbox qBittorrent download-client + seed criteria"
```

---

### Task 5: `qbit-autoremove` — disk-pressure eviction (script + timer)

**Files (ansible repo):**
- Create: `roles/qbit-autoremove/defaults/main.yml`
- Create: `roles/qbit-autoremove/files/qbit_autoremove.py`
- Create: `roles/qbit-autoremove/files/test_qbit_autoremove.py`
- Create: `roles/qbit-autoremove/templates/qbit-autoremove.service.j2`
- Create: `roles/qbit-autoremove/templates/qbit-autoremove.timer.j2`
- Create: `roles/qbit-autoremove/tasks/main.yml`
- Modify: `server.yml`

**Interfaces:**
- Consumes: qBittorrent WebUI API on the seedbox; the complete-dir filesystem.
- Produces: a systemd timer that, every 15 min, keeps ≥ 10 GB free by evicting imported, least-in-demand torrents in the spec's order.

The selection logic is a **pure function** (TDD it); the API/disk glue wraps it.

- [ ] **Step 1: Write the failing tests** `roles/qbit-autoremove/files/test_qbit_autoremove.py`:
```python
from qbit_autoremove import order_candidates, NOW_FIXED as _  # noqa
import qbit_autoremove as q

def t(**kw):
    base = dict(hash="h", name="n", progress=1.0, state="uploading",
                private=True, num_leechs=5, num_complete=5,
                last_activity=0, completion_on=0, size=100)
    base.update(kw); return base

GRACE = 7200
NOW = 100000

def test_skips_incomplete_and_within_grace():
    cands = q.order_candidates(
        [t(progress=0.5), t(completion_on=NOW-10)], GRACE, NOW)
    assert cands == []

def test_public_before_private():
    pub = t(hash="pub", private=False, completion_on=0)
    prv = t(hash="prv", private=True, completion_on=0)
    order = [c["hash"] for c in q.order_candidates([prv, pub], GRACE, NOW)]
    assert order == ["pub", "prv"]

def test_private_met_before_unmet():
    met = t(hash="met", state="pausedUP", completion_on=0)
    unmet = t(hash="unmet", state="uploading", completion_on=0)
    order = [c["hash"] for c in q.order_candidates([unmet, met], GRACE, NOW)]
    assert order == ["met", "unmet"]

def test_within_tier_fewest_leechers_first():
    lo = t(hash="lo", num_leechs=1, completion_on=0)
    hi = t(hash="hi", num_leechs=50, completion_on=0)
    order = [c["hash"] for c in q.order_candidates([hi, lo], GRACE, NOW)]
    assert order == ["lo", "hi"]
```

- [ ] **Step 2: Run the tests, confirm they fail** (module not yet written):
```bash
cd ~/Documents/git/ansible/roles/qbit-autoremove/files
python3 -m pytest -q   # ImportError / fails
```

- [ ] **Step 3: Write the script** `roles/qbit-autoremove/files/qbit_autoremove.py`:
```python
#!/usr/bin/env python3
"""Evict already-imported, least-in-demand torrents when the seedbox disk fills.

Order (spec §6): public first -> private/obligation-met -> private/unmet
(lowest-share, logged). Only download-complete torrents past AGE_GRACE are
candidates (so the *arr have imported them). Removal deletes files.
"""
import os, sys, shutil, logging, argparse

NOW_FIXED = None  # tests import this to prove the module loads

AGE_GRACE = int(os.environ.get("QBIT_AGE_GRACE", 7200))          # 2 h
FLOOR_BYTES = int(os.environ.get("QBIT_FLOOR_GB", "10")) * 1024**3
COMPLETE_DIR = os.environ.get("QBIT_COMPLETE_DIR", "/mnt/media-downloads")
_MET_STATES = {"pausedUP", "stoppedUP"}   # paused after hitting share limit

def _tier(tor):
    if not tor["private"]:
        return 0
    return 1 if tor["state"] in _MET_STATES else 2

def _demand_key(tor):
    # lower = less useful to keep = evict earlier: fewest leechers,
    # most redundant swarm seeds, stalest activity.
    return (tor["num_leechs"], -tor["num_complete"], tor["last_activity"])

def _is_candidate(tor, now):
    return tor["progress"] >= 1.0 and (now - tor["completion_on"]) >= AGE_GRACE

def order_candidates(torrents, grace, now):
    global AGE_GRACE
    AGE_GRACE = grace
    cands = [x for x in torrents if _is_candidate(x, now)]
    cands.sort(key=lambda x: (_tier(x), _demand_key(x)))
    return cands

def _connect():
    import qbittorrentapi
    c = qbittorrentapi.Client(
        host=os.environ["QBIT_HOST"], port=int(os.environ.get("QBIT_PORT", "8080")),
        username=os.environ.get("QBIT_USER"), password=os.environ.get("QBIT_PASS"))
    c.auth_log_in()
    return c

def main():
    import time
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    free = shutil.disk_usage(COMPLETE_DIR).free
    if free >= FLOOR_BYTES:
        logging.info("qbit-autoremove: %.1fG free >= floor, nothing to do", free/1024**3)
        return
    client = _connect()
    torrents = [dict(t) for t in client.torrents_info()]
    now = int(time.time())
    for tor in order_candidates(torrents, AGE_GRACE, now):
        if shutil.disk_usage(COMPLETE_DIR).free >= FLOOR_BYTES:
            break
        risk = " (H&R: private, obligation NOT met)" if _tier(tor) == 2 else ""
        logging.info("qbit-autoremove: %s %s%s",
                     "WOULD REMOVE" if args.dry_run else "removing", tor["name"], risk)
        if not args.dry_run:
            client.torrents_delete(delete_files=True, torrent_hashes=tor["hash"])

if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the tests, confirm they pass:**
```bash
cd ~/Documents/git/ansible/roles/qbit-autoremove/files
python3 -m pytest -q     # 4 passed
```

- [ ] **Step 5: Role defaults** `roles/qbit-autoremove/defaults/main.yml`:
```yaml
---
qbit_autoremove_floor_gb: 10
qbit_autoremove_age_grace_seconds: 7200
qbit_autoremove_complete_dir: /mnt/media-downloads
qbit_autoremove_interval: "15min"
qbit_autoremove_qbit_host: "127.0.0.1"   # override to the seedbox tailnet IP if WebUI isn't on localhost
qbit_autoremove_qbit_port: 8080
qbit_autoremove_qbit_user: ""            # set if WebUI auth isn't whitelisted for this host
qbit_autoremove_qbit_pass: ""            # from vault; never commit
```

- [ ] **Step 6: systemd service template** `roles/qbit-autoremove/templates/qbit-autoremove.service.j2`:
```jinja
# {{ ansible_managed }}
[Unit]
Description=qBittorrent disk-pressure eviction
After=network-online.target qbittorrent.service

[Service]
Type=oneshot
Environment=QBIT_FLOOR_GB={{ qbit_autoremove_floor_gb }}
Environment=QBIT_AGE_GRACE={{ qbit_autoremove_age_grace_seconds }}
Environment=QBIT_COMPLETE_DIR={{ qbit_autoremove_complete_dir }}
Environment=QBIT_HOST={{ qbit_autoremove_qbit_host }}
Environment=QBIT_PORT={{ qbit_autoremove_qbit_port }}
Environment=QBIT_USER={{ qbit_autoremove_qbit_user }}
Environment=QBIT_PASS={{ qbit_autoremove_qbit_pass }}
ExecStart=/usr/bin/python3 /opt/qbit-autoremove/qbit_autoremove.py
```

- [ ] **Step 7: systemd timer template** `roles/qbit-autoremove/templates/qbit-autoremove.timer.j2`:
```jinja
# {{ ansible_managed }}
[Unit]
Description=Run qBittorrent disk-pressure eviction periodically

[Timer]
OnBootSec=10min
OnUnitActiveSec={{ qbit_autoremove_interval }}

[Install]
WantedBy=timers.target
```

- [ ] **Step 8: Role tasks** `roles/qbit-autoremove/tasks/main.yml`:
```yaml
---
- name: Install python3 + qbittorrent-api
  ansible.builtin.apt:
    name: [python3, python3-pip]
    state: present
    update_cache: true

- name: Install qbittorrent-api
  ansible.builtin.pip:
    name: qbittorrent-api
    state: present

- name: Install the eviction script
  ansible.builtin.copy:
    src: qbit_autoremove.py
    dest: /opt/qbit-autoremove/qbit_autoremove.py
    owner: root
    group: root
    mode: "0755"

- name: Install the eviction service + timer
  ansible.builtin.template:
    src: "{{ item }}"
    dest: "/etc/systemd/system/{{ item | replace('.j2','') }}"
    owner: root
    group: root
    mode: "0644"
  loop:
    - qbit-autoremove.service.j2
    - qbit-autoremove.timer.j2

- name: Enable and start the eviction timer
  ansible.builtin.systemd:
    name: qbit-autoremove.timer
    daemon_reload: true
    enabled: true
    state: started
```

- [ ] **Step 9: Wire into the play.** In `server.yml`, add `- qbit-autoremove` to the `seedbox` play's roles (after `qbittorrent`).

- [ ] **Step 10: Syntax-check + deploy.**
```bash
cd ~/Documents/git/ansible
TMP=$(mktemp --suffix=.yml); printf -- '---\n- hosts: localhost\n  gather_facts: false\n  roles: [qbit-autoremove]\n' > "$TMP"
ANSIBLE_ROLES_PATH="$(pwd)/roles" ansible-playbook --syntax-check "$TMP"
ansible-playbook server.yml --limit seedbox
```

- [ ] **Step 11: Verify on the seedbox (dry-run first).**
```bash
# safe preview — evaluates order but deletes nothing:
sudo QBIT_HOST=127.0.0.1 QBIT_FLOOR_GB=999 /usr/bin/python3 /opt/qbit-autoremove/qbit_autoremove.py --dry-run
systemctl list-timers | grep qbit-autoremove          # scheduled
```
Expected: with an impossibly high floor, the dry-run lists the eviction order (public → met → unmet, least-in-demand first) and removes nothing. Then confirm the real timer is scheduled.

- [ ] **Step 12: Commit.**
```bash
git add -A roles/qbit-autoremove server.yml
git commit -m "feat(qbit-autoremove): disk-pressure eviction timer for the seedbox"
```

---

## Self-review notes (author)

- **Spec coverage:** Req 1 (seed-only-private) → Task 4 per-indexer criteria + unlimited baseline (Task 1). Req 2 (delete unneeded) → Task 4 *arr Remove-Completed. Req 3 (disk pressure) → Task 5. Data flow → Tasks 2–4. Migration (drop NAS) → Task 1.
- **Cross-repo order:** Task 2 (export) must land before Task 3 (mount) is verifiable; Tasks 1–3 before Task 4's functional test; Task 5 is independent of 3–4 but needs qBittorrent (Task 1).
- **Placeholders to resolve at execution:** the seedbox tailnet IP (Task 3 Step 3); the exact `qBittorrent.conf` share-limit keys for image 5.0.3 (Task 1 Step 4); whether the WebUI auth whitelist already lets the local eviction script in or a `QBIT_USER/PASS` is needed (Task 5 defaults).
- **No hardlink signal** across machines is why removal stays with the *arr and the eviction job is gated on age-grace — do not "optimise" the eviction to remove anything within the grace window.

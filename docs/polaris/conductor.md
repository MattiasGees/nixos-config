# polaris — conductor (home dashboard)

conductor is the home dashboard: train departures, tube status, room climate,
lights, plugs and Sonos, on the phones, laptops and the wall tablet. The code,
its design, its releases and polaris's config template live in
[github.com/MattiasGees/conductor](https://github.com/MattiasGees/conductor)
(private); this runbook covers running it on polaris. Run everything **on
polaris as `mattias`** (the conductor input is a private `git+ssh` repo, like
vmctl: never evaluate as root).

| Thing | Value |
|-------|-------|
| URL | `https://conductor.polaris.mattiasgees.be` (never the public tunnel: there is no login) |
| Access | Like the other `*.polaris.mattiasgees.be` apps: the name resolves to the tailnet IP, and it's not on the public tunnel |
| Service | `conductor.service`, user `conductor`, listens on `127.0.0.1:8420`; Caddy proxies the board, `/api`, the WebSocket and `/metrics` |
| Version | `flake.nix` pins `?ref=refs/tags/vX.Y.Z`; `/api/health` reports that release's commit (in a conductor clone: `git rev-parse --short=7 'vX.Y.Z^{commit}'`; the `^{commit}` matters for annotated tags) |
| Config | `deploy/polaris.config.yaml.tpl` in the conductor repo, taken from the pinned release → `/var/lib/secrets/conductor.yaml` (`0600 conductor`), rendered by op-secrets |
| Secrets | 1Password item `conductor`, vault `polaris`: `ha_token`, `rail_api_key`, `tfl_app_key` |
| Database | `conductor` on the shared PostgreSQL, owned by the `conductor` role, peer auth over `/run/postgresql`. Best effort: conductor runs without it |
| Logs | `journalctl -u conductor` (JSON lines) |

Nix wiring: `flake.nix` adds the input and, for polaris only, its
`nixosModules.default` plus `modules/services/conductor.nix` (which takes the
config template from the input); the vhost and its access guard are in
`modules/media/caddy.nix`.

## First deploy

1. **1Password.** In the `polaris` vault, create the item `conductor` with three
   fields: `ha_token` (the long-lived token of the Conductor HA user),
   `rail_api_key` (the Rail Data Marketplace key) and `tfl_app_key` (optional).
   Leave the rail and TfL fields empty until their keys arrive. **Never type a
   placeholder**: a made-up TfL key breaks the tube status (which works without
   a key), and a made-up rail key turns "no api_key configured" into auth
   errors.
2. **Check the references** the template uses (see setup.md § op-secrets for
   the full list):

   ```bash
   sudo sh -c 'export OP_SERVICE_ACCOUNT_TOKEN="$(cat /etc/op/token)"; export NIXPKGS_ALLOW_UNFREE=1; \
     for f in ha_token rail_api_key tfl_app_key; do printf "%s -> " "$f"; \
       nix run --impure nixpkgs#_1password-cli -- read "op://polaris/conductor/$f" >/dev/null && echo OK || echo FAIL; done'
   ```

   All three must print `OK`: one `FAIL` fails the whole render, and on a first
   deploy that leaves no config file, so conductor keeps restarting. If
   1Password won't keep an empty field (`FAIL` for `rail_api_key` or
   `tfl_app_key`), the fix is in the conductor repo: replace that reference in
   `deploy/polaris.config.yaml.tpl` with `""`, and deploy a release with that
   change. Put the reference back (another release) once the key is in
   1Password.
3. **Deploy:** `git pull`, then `make switch NIXNAME=polaris`.
4. **Check** (read-only). The first certificate takes about a minute (DNS-01;
   `journalctl -u caddy`):

   ```bash
   journalctl -b | grep 'op-secrets: rendered conductor-config'
   systemctl status conductor
   curl -s https://conductor.polaris.mattiasgees.be/api/health
   curl -s https://conductor.polaris.mattiasgees.be/api/status | jq '.upstreams'
   curl -s https://conductor.polaris.mattiasgees.be/metrics | grep -c '^conductor_'
   ```

   Expected: `{"status":"ok","version":"<commit>"}`; `homeassistant`, `postgres`
   and `tfl` `ok`; `rail` `down` with "no api_key configured" until the key is
   in 1Password. Then open the URL in a browser: the board should show the
   rooms, lights and music.

   If it doesn't come up, see Troubleshooting. To take it off polaris again
   while you look, `sudo systemctl stop conductor` (the next switch starts it).

## Moving to a new release

`make update-conductor` asks GitHub for the newest release with `gh`, which
needs `gh auth status` to pass (once: `gh auth login`); otherwise pass the tag,
`make update-conductor TAG=vX.Y.Z`. In the nixos-config checkout on polaris:

```bash
git pull
make update-conductor            # pins the newest release, updates flake.lock
make switch NIXNAME=polaris
curl -s https://conductor.polaris.mattiasgees.be/api/health   # the new release's commit
git add flake.nix flake.lock && git commit -m "conductor: vX.Y.Z" && git push
```

If `make update-conductor` fails (no such tag, no network), it leaves
`flake.nix` and `flake.lock` as they were.

**If the switch fails or the new release misbehaves**, go back to the committed
pin before anything else, so a later `make switch` doesn't deploy the bad
release again:

```bash
git checkout flake.nix flake.lock
make switch NIXNAME=polaris
```

The same applies after `sudo nixos-rebuild switch --rollback` (updating.md):
also restore the pin as above. If the bad release is already committed, pin the
previous one instead: `make update-conductor TAG=<previous>`, switch, commit.

The board on the wall tablet reloads itself when the version changes. A plain
`make update` (all inputs) keeps conductor on its pinned tag.

## Trying a branch or a commit

Override the input for one build, without touching `flake.nix` or the lock:

```bash
make switch NIXNAME=polaris NIXFLAGS="--override-input conductor 'git+ssh://git@github.com/MattiasGees/conductor?ref=my-branch'"
# a commit: 'git+ssh://git@github.com/MattiasGees/conductor?ref=my-branch&rev=<full sha>'
```

The override isn't recorded anywhere: the next plain `make switch
NIXNAME=polaris` goes back to the pinned release. Do that when the test is
done; until then a reboot also boots the override. The branch must build: CI's
nix job on its pull request shows that.

## Changing the config

- **Devices, rooms, lights and so on:** the template is
  `deploy/polaris.config.yaml.tpl` in the conductor repo (keys are documented
  in its `config.example.yaml`; `make check` there validates the template).
  The change reaches polaris with the next release (`make update-conductor`),
  or earlier with a test override of a branch (above). A changed template
  restarts conductor; an invalid config stops it with the reason in
  `journalctl -u conductor`. After the switch, check
  `journalctl -b | grep op-secrets` for a `WARNING` on `conductor-config`: a
  failed render keeps the old file, so the change wouldn't take effect.
- **A secret** (new HA token, the rail key arriving): edit the 1Password item,
  `make switch` (re-renders the file), then `sudo systemctl restart conductor`.

## Troubleshooting

- **conductor keeps restarting:** `journalctl -u conductor -n 50`. "read config"
  means the file wasn't rendered: `journalctl -b | grep op-secrets` shows a
  `WARNING` for `conductor-config` (token, item or field name).
- **`postgres` down in `/api/status`:** conductor keeps working, without the
  command log. Check the database owner:
  `sudo -u postgres psql -c '\l conductor'` must show `conductor` as the owner.
- **`homeassistant` down:** HA (on the Pi, `192.168.1.86:8123`) is unreachable
  or the token is wrong; the detail in `/api/status` says which.

# nixos-config

Personal Nix flake for my NixOS machines (desktop, home server `polaris`), Macs (nix-darwin) and standalone home-manager on other Linux boxes.

```bash
git clone --recurse-submodules https://github.com/mattiasgees/nixos-config.git ~/Documents/git/nixos-config
cd ~/Documents/git/nixos-config
make switch NIXNAME=<host>   # desktop | server | polaris | macbook-m1 | pacesetter | macbook-x86
make help                    # all targets
```

Clone to `~/Documents/git/nixos-config` — several home-manager modules symlink back into that path.

## Docs

- [CLAUDE.md](CLAUDE.md) — repo layout, hosts, build commands and gotchas
- [architecture/mac.md](architecture/mac.md) — what a Darwin build loads
- [docs/workstation-manual.md](docs/workstation-manual.md) — how the NixOS desktop is put together
- [SERVER-SETUP.md](SERVER-SETUP.md) — generic NixOS servers and home-manager on other distros
- [docs/polaris/](docs/polaris/) — home server setup, updating and backup/VM runbooks

## Provisioning a GPG key from a smartcard

1. `gpg --edit-card`
2. `fetch`

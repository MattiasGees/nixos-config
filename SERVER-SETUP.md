# Server Setup

Setting up a generic headless machine with this repo: either a NixOS server (`nixosConfigurations.server` / `server-arm64`) or a standalone home-manager profile on any other Linux distro. Both deliver the shell-only profile from `users/default/home-manager-server.nix` (no GUI packages).

Polaris has its own guide: [docs/polaris/setup.md](docs/polaris/setup.md).

## NixOS

1. Install NixOS with a minimal profile.
2. Clone and switch:
   ```bash
   git clone https://github.com/mattiasgees/nixos-config.git ~/Documents/git/nixos-config
   cd ~/Documents/git/nixos-config
   make switch                        # x86_64 → nixosConfigurations.server
   make switch NIXNAME=server-arm64   # aarch64
   ```

`make switch` builds as your user and only uses sudo to activate — don't run the whole thing under sudo.

This gives you the `mattias` user (wheel, docker), SSH, mosh (UDP 60000–61000 open), Docker, and the server home-manager profile.

### A new server host

1. `nixos-generate-config --show-hardware-config > hardware/<name>.nix`
2. Create `machines/<name>.nix` (hostname and host-specific options).
3. Add to `flake.nix`:
   ```nix
   nixosConfigurations.<name> = mkServer "<name>" rec {
     inherit home-manager user nixpkgs system pkgs;
     lib = pkgs.lib;
   };
   ```
4. `make switch NIXNAME=<name>`

## Other Linux (Debian, Ubuntu, Lima, …)

Uses `homeConfigurations.mattias@<arch>-linux` — installs tools and dotfiles into your home directory without touching the system.

**Automated, as root** — creates the `mattias` user (password `changeme`; change it immediately), installs multi-user Nix, clones the repo and applies home-manager:

```bash
curl -L https://raw.githubusercontent.com/mattiasgees/nixos-config/master/bootstrap-server.sh | sudo bash
```

**As an existing user** — single-user Nix, clones to `~/.config/nixos-config`, applies home-manager:

```bash
curl -L https://raw.githubusercontent.com/mattiasgees/nixos-config/master/install-home-manager.sh | bash
```

**Manually:**

```bash
git clone https://github.com/mattiasgees/nixos-config.git ~/.config/nixos-config
cd ~/.config/nixos-config
make install              # install Nix, then restart the shell
make setup-home-manager   # apply, backing up existing dotfiles as *.backup
```

Both scripts hardcode the `mattias` username. The bash profile installed by home-manager `exec`s into zsh on login.

## Updating

```bash
git pull
make switch                                     # NixOS
home-manager switch --flake .#mattias --impure  # other Linux (or: make home-manager)
```

## Troubleshooting

**`nix` not found** — source the profile:

```bash
. ~/.nix-profile/etc/profile.d/nix.sh                        # single-user
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh  # multi-user
```

**mosh can't find the server** — point at it explicitly:

```bash
mosh --server=/run/current-system/sw/bin/mosh-server mattias@host                               # NixOS
mosh --server='$HOME/.local/state/nix/profiles/home-manager/home-path/bin/mosh-server' mattias@host  # home-manager
```

On non-NixOS hosts also open UDP 60000–61000 (e.g. `sudo ufw allow 60000:61000/udp`).

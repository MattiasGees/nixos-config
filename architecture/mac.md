# Mac (Darwin) build structure

File map for `darwinConfigurations.macbook-m1` / `macbook-x86` — only what actually gets loaded for a Mac build.

## Entry point

```
flake.nix
└── darwinConfigurations.macbook-m1  ──► lib/mkdarwin.nix
                                        │
                                        ├── system-level modules
                                        └── home-manager (via darwinModules.home-manager)
```

`lib/mkdarwin.nix` injects three things every Darwin build gets unconditionally:

- `nix.distributedBuilds = true` against `ssh://builder@localhost` for `aarch64-linux` cross-builds.
- `documentation.enable = false`.
- home-manager wiring that imports `users/default/home-manager.nix` for the `${user}` defined in `flake.nix`.

## System-level (rebuilt by `darwin-rebuild switch`)

| File | Purpose |
|---|---|
| `machines/macbook-m1.nix` | hostname (`mattias-macbook`), nerd fonts (JetBrains Mono, Iosevka). Per-host file — `machines/macbook-x86.nix` is the Intel sibling. |
| `machines/shared.nix` | Nix daemon settings: `trusted-users`, GC (`--delete-older-than 7d`), `auto-optimise-store`, `experimental-features = nix-command flakes`. Also loaded by NixOS hosts. |
| `darwin/configuration.nix` | **The big one.** Homebrew taps/brews/casks, yabai + skhd + jankyborders config, `system.defaults` (dock, finder, trackpad, NSGlobalDomain), Touch ID for sudo, `system.activationScripts` (chsh to zsh, reload yabai SA). Also imports `modules/desktop/hyprland/default.nix` — dead weight on Darwin but currently still wired in. |

## Home-manager (`users/default/home-manager.nix`)

Shared with NixOS desktop builds; the imports are gated by `lib.optionals pkgs.stdenv.isDarwin`.

**Always loaded (Mac + Linux):**

```
modules/shell/git.nix              ── git identity, GPG signing
modules/shell/zsh.nix              ── zsh + starship + atuin + aliases/functions/exports
modules/editors/nvim/nvim.nix      ── AstroNvim submodule + config
modules/archive-downloads/         ── periodic ~/Downloads archiver
pkgs/default.nix                   ── imports core.nix + dev.nix + kube.nix + ssc.nix
darwin/modules/kitty/kitty.nix     ── Kitty config (loaded on Linux too, despite the path)
darwin/modules/ghostty/ghostty.nix ── Ghostty config (same)
```

**Darwin-only:**

```
darwin/modules/sketchybar/         ── menu-bar replacement (uses the Dynamic-Island submodule)
darwin/modules/yabai/              ── home-manager side of yabai
darwin/modules/skhd/               ── home-manager side of skhd
darwin/modules/syncthing/          ── syncthing service config
pkgs/macos.nix                     ── macOS-only package list
```

`darwin/modules/archive/` exists but isn't imported anywhere — treat as legacy.

## Packages (`pkgs/`)

Imported as home-manager modules, not derivations:

- `core.nix` / `dev.nix` / `kube.nix` / `ssc.nix` — pulled in via `pkgs/default.nix`, shared with the server config.
- `macos.nix` — only loaded on Darwin.
- `linux.nix`, `nixos.nix` — never loaded on Darwin.

Custom derivations in `pkgs/nordpass/` and `pkgs/waterfox/` are exposed by the overlay in `flake.nix`, but that overlay is only applied to the NixOS desktop `pkgs` — Darwin gets an un-overlaid `pkgs`.

## `nixConfigDir` symlinks

Several home-manager modules construct out-of-store symlinks back into the repo so live edits don't require a rebuild:

```nix
nixConfigDir = "${config.home.homeDirectory}/Documents/git/nixos-config";
```

Files that do this and matter on Mac:

- `darwin/modules/{sketchybar,yabai,skhd,ghostty,kitty}/*.nix`
- `modules/shell/zsh.nix`, `modules/editors/nvim/nvim.nix`
- `modules/archive-downloads/archive-downloads.nix`

The path is hardcoded — if the repo moves, every one of these breaks.

## Submodules required for a Mac build

```
modules/editors/nvim/AstroNvim                                           (AstroNvim upstream)
darwin/modules/sketchybar/config/plugins/Dynamic-Island-Sketchybar       (sketchybar plugin)
```

Run `git submodule update --init --recursive` after cloning.

## What you can ignore on Mac

Not loaded by the Darwin build path:

- `hardware/` — NixOS only
- `users/default/nixos.nix`, `nixos-server.nix`, `home-manager-server.nix`
- `lib/mksys.nix`, `mkserver.nix`, `mkhm.nix`, `mkvm.nix`
- `modules/desktop/{hyprland,river,waybar,dunst,gtk}/` — Wayland
- `modules/hardware/`, `modules/vm/`, `modules/services/syncthing/` (Linux service variant)
- `bootstrap-server.sh`, `install-home-manager.sh`, `SERVER-SETUP.md`, `SERVER_SETUP.md`
- Overlays in `flake.nix` (only applied to `nixosConfigurations.desktop`)

## Build / iterate loop

```bash
make switch                # NIXNAME defaults to macbook-m1 on Darwin
make switch NIXNAME=macbook-x86
make update                # refresh flake.lock
nix build ".#darwinConfigurations.macbook-m1.system" --impure   # build-only, no activation
```

`--impure` is required because `users/default/home-manager-server.nix` reads `builtins.getEnv "USER"`. Even though that file isn't loaded on Darwin, the flake evaluates it at the top level.

## Gotchas before editing

1. **Homebrew is declarative.** `darwin/configuration.nix` has `onActivation.cleanup = "zap"` — anything not listed in `brews` / `casks` / `taps` gets uninstalled on `darwin-rebuild switch`. Don't `brew install` something and expect it to survive.
2. **Yabai SA reloads on every rebuild.** The activation script runs `sudo yabai --load-sa`, so the sudoers entry for that command must stay in place or activation will prompt.
3. **The remote Linux builder.** `mkdarwin.nix` hardwires `ssh://builder@localhost` as an `aarch64-linux` build machine. Any derivation that needs a Linux build (e.g. cross-system packages) will hang if that builder isn't reachable.

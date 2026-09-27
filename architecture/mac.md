# Mac (Darwin) build structure

What actually gets loaded for `darwinConfigurations.{macbook-m1,pacesetter,macbook-x86}`.

## Entry point

```
flake.nix
└── darwinConfigurations.<host>  ──► lib/mkdarwin.nix
                                     ├── system-level modules
                                     └── home-manager (darwinModules.home-manager)
```

Besides the modules below, `lib/mkdarwin.nix` sets `documentation.enable = false`, `allowUnfree`, and home-manager's `backupFileExtension = "backup"`.

## System-level (`darwin-rebuild switch`)

| File | Purpose |
|---|---|
| `machines/<host>.nix` | Hostname and nerd fonts. `pacesetter.nix` imports `macbook-m1.nix` and only overrides the name. |
| `machines/shared.nix` | Nix settings shared with NixOS: trusted users, automatic GC (`--delete-older-than 7d`), `auto-optimise-store`, flakes. |
| `darwin/configuration.nix` | **The big one.** Homebrew taps/brews/casks, yabai + skhd + jankyborders, `system.defaults` (dock, finder, trackpad, NSGlobalDomain), Touch ID for sudo, activation script (chsh to zsh, reload the yabai scripting addition). |
| `darwin/paseo.nix` | Rewrites `daemon.listen` in `~/.paseo/config.json` to this Mac's Tailscale IP; leaves the rest of Paseo's runtime-owned file alone. |

## Home-manager (`users/default/home-manager.nix`)

Shared with the NixOS desktop; platform imports are gated with `lib.optionals pkgs.stdenv.hostPlatform.isDarwin`.

**Mac + Linux desktop:**

```
modules/shell/git.nix                ── git identity, GPG signing
modules/shell/zsh.nix                ── zsh + starship + atuin + aliases/functions/exports
modules/shell/direnv-hm.nix          ── direnv + nix-direnv
modules/archive-downloads/           ── periodic ~/Downloads archiver
pkgs/default.nix                     ── core.nix + dev.nix + kube.nix
darwin/modules/kitty/kitty.nix       ── Kitty config (loaded on Linux too, despite the path)
darwin/modules/ghostty/ghostty.nix   ── Ghostty config (same)
```

`modules/editors/nvim/nvim.nix` is currently commented out.

**Darwin-only:**

```
darwin/modules/sketchybar/           ── SbarLua menu bar; C helpers built at activation
darwin/modules/yabai/, skhd/         ── out-of-store symlinks to the rc files
darwin/modules/vscode/               ── declarative VSCode settings, seeded extensions
modules/programs/claude-code-bootstrap.nix ── runs bootstrap-claude-code.sh on activation
pkgs/macos.nix                       ── macOS-only packages
```

`darwin/modules/syncthing/` is commented out; `darwin/modules/archive/` isn't imported anywhere.

## Packages

`pkgs/*.nix` are home-manager modules, not derivations. Darwin gets an un-overlaid `pkgs` — the overlays in `flake.nix` apply only to the x86_64-linux hosts.

## Live-edit symlinks

Several modules link back into the repo with `mkOutOfStoreSymlink` so edits apply without a rebuild:

```nix
nixConfigDir = "${config.home.homeDirectory}/Documents/git/nixos-config";
```

Used by `darwin/modules/{sketchybar,yabai,skhd,ghostty,kitty}`, `modules/shell/zsh.nix` and `modules/archive-downloads/`. The path is hardcoded — if the repo moves, these all break.

## Not loaded on Mac

- `hardware/`, `lib/mksys.nix`, `mkserver.nix`, `mkhm.nix`, `mkvm.nix`
- `users/default/nixos.nix`, `nixos-server.nix`, `home-manager-server.nix`
- `modules/{desktop,hardware,vm,server,media,services}/`
- `bootstrap-server.sh`, `install-home-manager.sh`, `SERVER-SETUP.md`

## Build loop

```bash
make switch                     # NIXNAME defaults to macbook-m1
make switch NIXNAME=pacesetter
nix build ".#darwinConfigurations.macbook-m1.system" --impure   # build only
```

`--impure` is needed because the flake's `homeConfigurations` read `builtins.getEnv "USER"` / `"HOME"` at evaluation time.

## Gotchas

1. **Homebrew is declarative.** `onActivation.cleanup = "zap"` uninstalls anything not listed in `brews` / `casks` / `taps`. A manual `brew install` won't survive a switch.
2. **yabai scripting addition.** `services.yabai.enableScriptingAddition` installs the sudoers entry that the activation script and `yabairc` rely on for `yabai --load-sa`.
3. **Manual steps on a fresh Mac:** grant Accessibility to sketchybar's `helpers/menus/bin/menus`, and install SF Pro / SF Mono from https://developer.apple.com/fonts/ (the Homebrew casks are broken).

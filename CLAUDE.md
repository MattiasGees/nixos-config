# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build / switch commands

All builds go through the `Makefile`, which dispatches based on `uname` and the `NIXNAME` variable. There is no test suite — verification means a successful `nix build` / rebuild on the relevant host.

```bash
make switch                       # Linux → nixosConfigurations.server; macOS → darwinConfigurations.macbook-m1
make switch NIXNAME=desktop       # NixOS desktop
make switch NIXNAME=macbook-m1    # Darwin (aarch64)
make build-server                 # nix build the server toplevel without activating
make home-manager                 # Apply standalone home-manager (non-NixOS / non-Darwin Linux)
make setup-home-manager           # Same, but backs up existing dotfiles with `.backup`
make update                       # nix flake update
```

Notes:
- All `nix build` / `*-rebuild` calls pass `--impure` (the flake reads `builtins.getEnv "USER"` / `"HOME"` for the standalone home configuration). Reproduce manually with the same flag.
- `NIX_CONFIG="experimental-features = nix-command flakes"` is set inline by the Makefile; mirror that when invoking nix commands directly.
- Darwin builds enable `nix.distributedBuilds` against `ssh://builder@localhost` for `aarch64-linux`. Cross-system builds from the MacBook assume that builder is reachable.
- There is no CI, linter, or formatter wired in. `nix flake check` is not part of the workflow.

## Architecture

This is a single flake covering NixOS hosts, nix-darwin hosts, and standalone home-manager — every host wires the same module library together via small builder functions.

**Builders (`lib/`)** — each takes a `name` plus inputs and returns a system:
- `mksys.nix` → full NixOS desktop (hyprland + xremap + GUI home-manager).
- `mkserver.nix` → headless NixOS (no GUI imports, uses `users/default/nixos-server.nix` + `home-manager-server.nix`).
- `mkdarwin.nix` → nix-darwin; injects the distributed-build settings and imports `darwin/configuration.nix`.
- `mkhm.nix` / `mkvm.nix` exist but `flake.nix` does not call them — treat as legacy unless wiring something new.

**Host wiring (`flake.nix`)** — declares `nixosConfigurations.{desktop,server,server-arm64}`, `darwinConfigurations.{macbook-m1,macbook-x86}`, and `homeConfigurations.${user}` (plus `${user}@x86_64-linux` / `${user}@aarch64-linux`). The builder imports `hardware/${name}.nix`, `machines/${name}.nix`, and `machines/shared.nix` — so adding a host means creating those three files and a builder call in `flake.nix`.

**Layered configuration:**
- `hardware/<host>.nix` — disk, filesystems, kernel modules. Host-specific.
- `machines/<host>.nix` — per-host system options (hostname, fonts, etc.). `machines/shared.nix` is imported by every host and sets `nix.gc`, `nix.extraOptions`, trusted users.
- `users/default/nixos.nix` / `nixos-server.nix` — system-level user/services (full desktop vs. minimal SSH+docker server). The username `mattias` is hardcoded across these files; renaming it touches multiple places.
- `users/default/home-manager.nix` — full home-manager profile, gated with `lib.optionals pkgs.stdenv.isDarwin` / `isLinux` so the same file feeds both NixOS and Darwin hosts. `home-manager-server.nix` is a deliberately stripped variant for headless Linux.
- `darwin/configuration.nix` — Homebrew taps/brews/casks, yabai/skhd/jankyborders, macOS `system.defaults`.

**Package lists (`pkgs/`)** are imported as home-manager modules, not as derivations:
- `core.nix` / `dev.nix` / `kube.nix` — used by both server and full configs.
- `linux.nix`, `nixos.nix`, `macos.nix` — platform-specific, imported conditionally from `users/default/home-manager.nix`.
- `pkgs/default.nix` is unused — top-level `pkgs/` callPackages live in the overlay block of `flake.nix`.
- Custom derivations live in `pkgs/nordpass/` and `pkgs/waterfox/`.

**Overlays** are defined inline in `flake.nix` for the desktop `pkgs`: they expose `nordpass` and `waterfox` as new attrs, and pin a list of packages (waybar, swww, slack, steam, go, …) to `nixpkgs-unstable`. Darwin uses an un-overlaid `pkgs`. There is also an in-system overlay in `users/default/nixos.nix` that rebuilds `waybar` with `-Dexperimental=true`.

**Modules (`modules/`, `darwin/modules/`)** are reusable home-manager / system pieces (hyprland, dunst, waybar, kitty, ghostty, sketchybar, yabai, syncthing, nvim, zsh, git, …). They are imported by `users/default/home-manager*.nix` and `machines/shared.nix` rather than auto-discovered — adding a new module means adding an explicit `imports = [ ... ]` entry somewhere.

## Submodules

Two git submodules are required for a complete build:
- `modules/editors/nvim/AstroNvim` (upstream AstroNvim).
- `darwin/modules/sketchybar/config/plugins/Dynamic-Island-Sketchybar`.

Run `git submodule update --init --recursive` after cloning.

## Bootstrap scripts

`bootstrap-server.sh` / `install-home-manager.sh` are one-shot provisioning scripts for fresh non-NixOS Linux servers. They hardcode the username `mattias` and the repo URL `github.com/mattiasgees/nixos-config` — update both if reusing.

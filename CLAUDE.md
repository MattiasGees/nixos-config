# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Build / switch

Everything goes through the `Makefile`, which picks a target by `uname` and `NIXNAME` (default: `server` on Linux, `macbook-m1` on macOS). There is no test suite — verification means a successful `nix build` of the affected host.

```bash
make switch NIXNAME=<host>   # build as the user, then activate with sudo
make build-server            # build nixosConfigurations.server without activating
make home-manager            # standalone home-manager (non-NixOS Linux)
make setup-home-manager      # same, backing up existing dotfiles with `.backup`
make update                  # nix flake update
```

To build without activating, mirror the Makefile:

```bash
NIX_CONFIG="experimental-features = nix-command flakes" \
  nix build ".#nixosConfigurations.<host>.config.system.build.toplevel" --impure
NIX_CONFIG="experimental-features = nix-command flakes" \
  nix build ".#darwinConfigurations.<host>.system" --impure
```

- `--impure` is required: `homeConfigurations` reads `builtins.getEnv "USER"` / `"HOME"`.
- The `vmctl` input is a **private** `git+ssh` repo. Evaluate as a user with GitHub SSH access, never as root — this is why `make switch` on Linux builds unprivileged and only uses sudo to activate.
- The only flake check is `checks.x86_64-linux.polaris-zfs` (a NixOS VM test of `scripts/create-zfs-pools.sh`). No CI, linter or formatter.
- PRs target the `mattias` branch.

## Hosts (`flake.nix`)

| Output | Builder | Notes |
|---|---|---|
| `nixosConfigurations.desktop` | `lib/mksys.nix` | Hyprland + xremap + full GUI home-manager. **Currently doesn't evaluate** (bit-rotted: removed NixOS options, `waterfox` isn't in nixpkgs and no overlay provides it) |
| `nixosConfigurations.server` / `server-arm64` | `lib/mkserver.nix` | Generic headless box; both use `hardware/server.nix` + `machines/server.nix` |
| `nixosConfigurations.polaris` | `lib/mkserver.nix` | Home server (ZFS, media stack, self-hosted services). `extraModules` adds `hardware/polaris-extra.nix` (NVIDIA, ZFS pools) and `modules/server/vmctl.nix` |
| `nixosConfigurations.polaris-vm` | `lib/mkserver.nix` | aarch64 throwaway VM of polaris: `machines/polaris-vm.nix` imports `polaris.nix` and overrides networking/hostname |
| `darwinConfigurations.macbook-m1` / `pacesetter` / `macbook-x86` | `lib/mkdarwin.nix` | `pacesetter` is `macbook-m1` with a different hostname |
| `homeConfigurations.mattias[@<arch>-linux]` | inline | `users/default/home-manager-server.nix` for non-NixOS Linux |

NixOS builders import `hardware/<name>.nix`, `machines/<name>.nix` and `machines/shared.nix`; Darwin skips `hardware/`. Adding a host means creating those files and a builder call in `flake.nix`. `lib/mkhm.nix` and `lib/mkvm.nix` are not called (legacy).

## Layout

- `machines/shared.nix` — imported by every host (NixOS and Darwin): nix GC/settings, trusted users.
- `users/default/`
  - `nixos.nix` / `nixos-server.nix` — system-level user + services (desktop vs. SSH/mosh/docker server).
  - `home-manager.nix` — desktop/Mac profile; platform-specific imports are gated with `lib.optionals pkgs.stdenv.hostPlatform.isDarwin` / `isLinux`.
  - `home-manager-server.nix` — stripped headless profile (servers, polaris, standalone).
- `darwin/configuration.nix` — Homebrew (declarative, `cleanup = "zap"`: anything unlisted is uninstalled), yabai/skhd/jankyborders (configured inline here; `scripts/setup-brew-wm.sh` is a Homebrew-only copy for the nix-less work laptop — keep in sync), `system.defaults`. `darwin/paseo.nix` binds the Paseo daemon to the Tailscale IP.
- `pkgs/` — package lists imported as **home-manager modules**, not derivations. `pkgs/default.nix` bundles `core.nix` + `dev.nix` + `kube.nix` for the desktop/Mac profile; the server profile imports those three directly. `linux.nix`, `nixos.nix`, `macos.nix` are platform-specific.
- `modules/` — reusable pieces, always imported explicitly (nothing is auto-discovered):
  - `shell/`, `editors/`, `desktop/`, `programs/`, `archive-downloads/`, `vm/` — home-manager / workstation.
  - `server/`, `media/`, `services/` — polaris system modules (ZFS, restic, NFS, tailscale, cloudflared, Caddy, *arr stack, Immich, Outline, …), wired in from `machines/polaris.nix`.
- `darwin/modules/` — Mac home-manager modules (sketchybar, kitty, ghostty, vscode). `darwin/modules/archive/` is unused.
- `hardware/polaris.nix` is raw `nixos-generate-config` output and may be overwritten; hand-maintained hardware bits go in `hardware/polaris-extra.nix`.
- Human docs: `docs/polaris/` runbooks, `docs/workstation-manual.md` (desktop), `architecture/mac.md` (Darwin), `SERVER-SETUP.md` (generic servers / non-NixOS).

## Conventions and gotchas

- **Overlays** live inline in `flake.nix` and apply only to the shared x86_64-linux `pkgs` (desktop, server, polaris): a few packages pinned to `nixpkgs-unstable` and `onnxruntime` built without OpenVINO (for Immich). Darwin, aarch64 hosts and standalone home-manager get un-overlaid `pkgs`. `overlays/` is unused.
- **Secrets** on polaris come from 1Password at activation (`modules/server/op-secrets.nix`), rendered from the `*.tpl` files next to each module. Never put secrets in Nix strings — the store is world-readable.
- **Live-edit symlinks:** many home-manager modules use `mkOutOfStoreSymlink` to `~/Documents/git/nixos-config/...`, so config edits apply without a rebuild — and break if the repo lives elsewhere.
- The username `mattias` is hardcoded in several places (`flake.nix`, `machines/shared.nix`, `users/default/nixos*.nix`, `machines/polaris.nix`, bootstrap scripts).
- **Claude Code** config on the Macs and polaris is set up imperatively by `bootstrap-claude-code.sh`, run on activation via `modules/programs/claude-code-bootstrap.nix` (Claude Code rewrites its own config files, so home-manager can't own them).
- **sketchybar** is a vendored SbarLua config from FelixKratz/dotfiles; its C helpers are built at activation. The menu-bar helper `helpers/menus/bin/menus` needs a manual macOS Accessibility grant. SF Pro / SF Mono must be installed manually from https://developer.apple.com/fonts/ (the Homebrew casks are broken).
- Vendored trees — don't restyle: `modules/desktop/hyprland/rofi/`, `darwin/modules/sketchybar/config/`, `modules/editors/nvim/{AstroNvim,LazyNvim}`.

## Submodules

`modules/editors/nvim/AstroNvim` is a git submodule. Run `git submodule update --init --recursive` after cloning.

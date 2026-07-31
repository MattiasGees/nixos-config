# NixOS Workstation Manual — How Everything Is Glued Together

A start-to-finish walkthrough of how the **desktop** workstation
(`nixosConfigurations.desktop`) is built and applied in this repo, written for
someone new to NixOS. It explains the mental model first, then traces one
`make switch` from the command you type all the way to a booted, running
desktop, and finally shows how the individual modules fit in.

> Scope: this focuses on the NixOS desktop. The macOS (Darwin) and headless
> server paths reuse most of the same ideas — differences are called out at the
> end.

---

## Part 1 — The NixOS mental model (read this first)

If you come from a normal Linux distro, four ideas are new and everything else
follows from them.

### 1. It's declarative, not imperative

You never run `apt install firefox` or edit files in `/etc` by hand. Instead you
**describe the entire machine** — packages, services, users, kernel modules — in
`.nix` files. Then you run one command that makes the running system *match* that
description. If you delete a package from the description and rebuild, it's gone.
The files are the single source of truth.

### 2. The Nix store and "nothing is installed in place"

Every package, config file, and even the whole system is built into
`/nix/store/<hash>-<name>/`. That hash is derived from *all* the inputs used to
build it. Two consequences:

- **Nothing is ever mutated in place.** A new version of a package is a new store
  path with a new hash; the old one stays until garbage-collected.
- **Your running system is just a symlink** — `/run/current-system` points at one
  specific store path (a "generation"). Switching configs = building a new store
  path and repointing that symlink.

### 3. Generations and atomic switching

Each time you rebuild, NixOS creates a new **generation**. The switch is atomic:
either the new generation fully activates or you stay on the old one. Old
generations appear in the bootloader menu, so a broken config is a reboot away
from recovery. `nix.gc` in `machines/shared.nix` deletes generations older than
7 days automatically.

### 4. The module system merges everything into one config

This is the part that confuses newcomers most. You will see dozens of `.nix`
files each setting things like `environment.systemPackages` or
`services.openssh.enable`. They are **not** applied one-after-another and
overwriting each other. Instead NixOS **merges** them all into a single giant
attribute set (`config`) using typed rules:

- Lists (like `systemPackages`) are **concatenated**.
- Booleans/enables are OR-ed or take a defined value.
- `lib.mkDefault x` sets a low-priority value that another module can override.
- `lib.mkForce x` sets a high-priority value that wins.

So "which file sets the hostname?" has one answer, but "which files add system
packages?" can be many — they all contribute. Keep this in mind for the rest of
the manual: **imports don't run, they contribute options to one merged result.**

---

## Part 2 — The big picture

This repo is **one flake** (`flake.nix`) that can build three kinds of system:

| Output | Builder (`lib/`) | What it produces |
|--------|------------------|------------------|
| `nixosConfigurations.desktop` | `mksys.nix` | Full NixOS desktop (this manual) |
| `nixosConfigurations.server` | `mkserver.nix` | Headless NixOS server |
| `darwinConfigurations.macbook-m1` | `mkdarwin.nix` | macOS via nix-darwin |
| `homeConfigurations.mattias` | (inline) | Standalone home-manager, non-NixOS Linux |

A **builder** is just a function: give it a name + some inputs, it returns a
fully-evaluated system. The desktop uses `mkSys`.

Everything is wired **explicitly**. There is no auto-discovery of files — a
module only takes effect if some `imports = [ ... ]` list points at it. When you
add a feature, you add both the module file *and* an import line.

---

## Part 3 — Start to finish: one `make switch NIXNAME=desktop`

Here is the entire journey, in order.

```
make switch NIXNAME=desktop
        │
        ▼
[1] Makefile picks the command for your OS
        │
        ▼
[2] sudo nixos-rebuild switch --flake .#desktop --impure
        │
        ▼
[3] Nix evaluates flake.nix → builds the overlaid `pkgs`
        │
        ▼
[4] mkSys assembles the module list
        │
        ▼
[5] The module system merges all modules → one `config`
        │
        ▼
[6] Nix realises (builds) config.system.build.toplevel in /nix/store
        │
        ▼
[7] The activation script runs: symlinks /run/current-system, writes
    bootloader entry, (re)starts systemd units, activates home-manager
        │
        ▼
[8] On next login: greetd → Hyprland → autostart apps
```

### Step 1 — The Makefile chooses the command

`make switch` dispatches on `uname`. On Linux it runs:

```make
sudo NIX_CONFIG="experimental-features = nix-command flakes" \
  NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 \
  nixos-rebuild switch --flake ".#${NIXNAME}" --impure
```

- `NIXNAME=desktop` selects `nixosConfigurations.desktop`.
- `--impure` is required because `flake.nix` reads `builtins.getEnv "USER"` /
  `"HOME"` (used by the standalone home-manager config). Pure evaluation would
  forbid reading the environment.
- `NIX_CONFIG=…flakes` turns on the still-"experimental" flake commands.

`nixos-rebuild switch` = **build the new system, then activate it**. (`build`
alone would build without activating; `boot` would activate only on next reboot.)

### Step 2–3 — Flake evaluation and building `pkgs`

`nixos-rebuild` asks the flake for `nixosConfigurations.desktop`. Evaluating
`flake.nix` first constructs the package set that the whole desktop will use:

```nix
pkgs = import nixpkgs {
  system = "x86_64-linux";
  config = { allowUnfree = true; allowInsecure = true; };
  overlays = [ (final: prev: { ... }) ];
};
```

Two important things happen here:

- **`allowUnfree`** lets you install Slack, Spotify, Steam, etc. (non-free
  licenses are rejected by default).
- **Overlays** modify the package set. This one:
  - adds new packages that don't exist upstream: `nordpass`, `waterfox`
    (built from `pkgs/nordpass/` and `pkgs/waterfox/`);
  - **pins specific packages to `nixpkgs-unstable`**: `waybar`, `swww`, `slack`,
    `steam`, `go`, `dunst`, `_1password-gui`, `nwg-look`, etc. — so those follow
    bleeding-edge while the rest of the system tracks the main `nixpkgs`.

This overlaid `pkgs` is then **passed by hand** into the builder
(`inherit pkgs`). That's why every module downstream sees the same package set
with the same overlays — they don't each re-import nixpkgs.

### Step 4 — `mkSys` assembles the module list

`lib/mksys.nix` is short and worth reading in full:

```nix
name: { pkgs, nixpkgs, lib, home-manager, system, user, hyprland, xremap-flake }:
nixpkgs.lib.nixosSystem {
  inherit system pkgs;
  modules = [
    ../hardware/${name}.nix          # hardware/desktop.nix
    ../machines/${name}.nix          # machines/desktop.nix
    ../machines/shared.nix
    hyprland.nixosModules.default    # from the flake input
    xremap-flake.nixosModules.default
    ../users/default/nixos.nix
    home-manager.nixosModules.home-manager {
      home-manager.users.${user} =
        import ../users/default/home-manager.nix { inherit lib pkgs user; };
    }
  ];
}
```

`nixosSystem` is the NixOS entry point. Everything in `modules = [ ... ]` is a
module that will be merged. Note that `${name}` is `"desktop"`, so it pulls in
`hardware/desktop.nix` and `machines/desktop.nix` automatically — **that naming
convention is the contract for adding a host.**

### Step 5 — The module system merges everything

Now the key event. NixOS evaluates every module and merges their options into one
`config`. Here's who contributes what for the desktop:

| Layer | File | Answers the question | Examples |
|-------|------|----------------------|----------|
| **Hardware** | `hardware/desktop.nix` | *What physical machine is this?* | disk UUIDs, `ext4`/`vfat`, `kvm-amd` + Broadcom Wi-Fi modules, AMD microcode |
| **Host** | `machines/desktop.nix` | *What does THIS host do?* | hostname `nixos`, AMD GPU + **VFIO passthrough** of the GTX 1660, IOMMU kernel params, autologin |
| **Shared** | `machines/shared.nix` | *Settings for every host* | `nix.gc`, `auto-optimise-store`, flakes, trusted users |
| **Flake modules** | `hyprland` / `xremap` | *Third-party NixOS modules* | defines `programs.hyprland`, `services.xremap` options |
| **System + user** | `users/default/nixos.nix` | *OS services + the login user* | bootloader, PipeWire, greetd→Hyprland, docker, libvirtd/KVM, ssh, gnupg, the `mattias` user |
| **Home-manager** | `users/default/home-manager.nix` | *The user's `$HOME`* | dotfiles + per-user packages (see Part 4) |

Because everything merges, some concerns are deliberately spread across files.
The clearest example is **GPU passthrough (VFIO)**, which touches three places:

1. `machines/desktop.nix` — binds the GTX 1660's PCI IDs to `vfio-pci` at the
   kernel level and blacklists the `nvidia`/`nouveau` drivers.
2. `users/default/nixos.nix` — enables `libvirtd` + QEMU/OVMF/swtpm so a VM can
   use the passed-through card.
3. `modules/vm/vfio/default.nix` — the home-manager side (helper tooling).

None of these "wins" over the others; together they form the feature.

Also note `users/default/nixos.nix` contains an **in-system overlay** that
rebuilds `waybar` with `-Dexperimental=true`. That's separate from the flake-level
overlays and applies only inside this system.

### Step 6 — Nix builds the toplevel

The merged config has an attribute `config.system.build.toplevel`. Nix
**realises** it: it builds (or downloads from a binary cache) every store path
needed — the kernel, every package, generated config files under `/etc`, systemd
units — and produces one top-level store path representing the whole system. This
is the step that can take a while and print lots of `building '/nix/store/…'`
lines. If anything fails to build, nothing is activated and your current system is
untouched.

### Step 7 — Activation

Once the toplevel is built, `nixos-rebuild switch` runs its **activation script**:

1. Repoints `/run/current-system` at the new store path (this is the atomic
   switch — a new **generation**).
2. Writes a new **systemd-boot** entry (bootloader config comes from
   `boot.loader.systemd-boot.enable = true` in `nixos.nix`).
3. Reloads/restarts changed **systemd services** — e.g. if you changed the
   PipeWire or docker config, those units restart now.
4. Runs the **home-manager activation** for user `mattias` (because home-manager
   is wired in as a NixOS module via `home-manager.nixosModules.home-manager`).
   This is what writes/updates the user's dotfiles and per-user profile.

After this, most system changes are live immediately. Changes that only apply at
login or boot (your Hyprland session, kernel params) take effect next time.

### Step 8 — Boot and login: how the desktop actually starts

The running desktop is produced by a small chain, all declared in the config:

```
systemd-boot                     (boot.loader.systemd-boot)
    │  boots the kernel + params (amd_iommu=on, video=efifb:off …)
    ▼
greetd                           (services.greetd in users/default/nixos.nix)
    │  initial_session runs Hyprland as user `mattias`
    ▼
Hyprland                         (programs.hyprland, from the hyprland flake module)
    │  reads ~/.config/hypr/hyprland.conf   ← generated by home-manager
    ▼
exec-once autostart chain        (from modules/desktop/hyprland/home.nix)
    ├─ systemctl --user start waybar.service   (status bar)
    ├─ systemctl --user start xremap.service    (Super→Ctrl remaps)
    ├─ wpaperd                                  (wallpaper)
    └─ apps pinned to workspaces: kitty→1/2, firefox→3, slack→4, spotify→6 …
```

Two subtle points:

- **Hyprland is launched two ways.** `greetd`'s `initial_session` is the real one
  at boot. There is *also* a fallback in `modules/desktop/hyprland/default.nix`
  that execs Hyprland if you log in on `tty1`. Under normal boot, greetd wins.
- **`hyprland.conf` is a generated file.** `modules/desktop/hyprland/home.nix`
  builds the whole config as a Nix string and writes it via
  `xdg.configFile."hypr/hyprland.conf".text = …`. You edit the Nix, rebuild, and
  the file is regenerated — you don't edit `~/.config/hypr/hyprland.conf`
  directly (it's managed).

---

## Part 4 — How home-manager plugs in

**NixOS** manages the system (services, users, kernel). **home-manager** manages a
user's `$HOME` (dotfiles, per-user packages, shell). In this repo home-manager
runs *inside* NixOS as a module, so a single `make switch` applies both.

`users/default/home-manager.nix` is the profile. Its cleverness is that the
**same file serves both NixOS and macOS**, gated by platform:

```nix
imports = [
  # --- shared on every platform ---
  ../../modules/shell/git.nix
  ../../modules/shell/zsh.nix
  ../../modules/archive-downloads/archive-downloads.nix
  ../../darwin/modules/kitty/kitty.nix
  ../../darwin/modules/ghostty/ghostty.nix
  ../../pkgs/default.nix               # → core.nix + dev.nix + kube.nix
]
++ lib.optionals pkgs.stdenv.isDarwin [
  ../../darwin/modules/sketchybar/sketchybar.nix
  ../../darwin/modules/yabai/yabai.nix
  ../../pkgs/macos.nix                 # colima, lima
]
++ lib.optionals pkgs.stdenv.isLinux [
  ../../modules/desktop/hyprland/home.nix
  ../../modules/desktop/hyprland/extras.nix
  ../../modules/desktop/dunst/dunst.nix
  ../../modules/vm/vfio/default.nix
  ../../pkgs/nixos.nix                 # GUI apps via Nix
  ../../pkgs/linux.nix
];
```

`lib.optionals cond list` returns the list if `cond` is true, else `[]`. So on the
desktop the Darwin branch evaluates to nothing and the Linux branch is added.

**Package lists are modules, not derivations.** Files like `pkgs/core.nix` look
like this:

```nix
{ pkgs, ... }: {
  home.packages = with pkgs; [ fzf ripgrep bat htop starship git … ];
}
```

They're imported as home-manager modules that each *contribute to*
`home.packages`. Because of list-merging (Part 1), all of them add up:

- `pkgs/core.nix` — CLI basics (fzf, ripgrep, starship, atuin, mosh…)
- `pkgs/dev.nix` — dev toolchain (go, python, docker, gh, claude-code…)
- `pkgs/kube.nix` — Kubernetes (kubectl, k9s, helm, flux, gcloud…)
- `pkgs/nixos.nix` — **Linux GUI apps installed via Nix** (spotify, slack,
  1password-gui, chrome, nordpass, waterfox…)

> Note the difference from macOS: on Linux, GUI apps are installed **declaratively
> via Nix** (`pkgs/nixos.nix`). On macOS the same apps come from **Homebrew
> casks** in `darwin/configuration.nix`.

---

## Part 5 — Anatomy of a single module (`modules/shell/zsh.nix`)

To make "a module contributes options" concrete, here's what one real module
does. `modules/shell/zsh.nix` configures zsh **and** demonstrates two patterns
you'll see across the repo:

```nix
{ config, pkgs, ... }:
let
  nixConfigDir = "${config.home.homeDirectory}/Documents/git/nixos-config";
  extras = [ ./zshrc ./shell_exports ./shell_aliases ./shell_functions ];
  extraInitExtra = builtins.foldl'
    (soFar: new: soFar + "\n" + builtins.readFile new) "" extras;
in {
  # 1) A live symlink to a file in your repo (NOT copied into the store):
  xdg.configFile."global-gitignore".source =
    mkOutOfStoreSymlink "${nixConfigDir}/modules/shell/gitignore";

  # 2) Normal home-manager options that get merged:
  programs.zsh = {
    enable = true;
    oh-my-zsh = { enable = true; plugins = [ "git" "z" ]; };
    initContent = ''source ${pkgs.spaceship-prompt}/…/prompt_spaceship_setup'' 
                  + extraInitExtra;
    plugins = [ { name = "zsh-syntax-highlighting"; src = pkgs.fetchFromGitHub { … }; } ];
  };
}
```

Two techniques worth knowing:

- **`builtins.readFile`** slurps plain shell files (`shell_aliases`, etc.) into
  the generated `.zshrc`. This lets you keep ordinary shell snippets as ordinary
  files and fold them into the Nix-managed config.
- **`mkOutOfStoreSymlink`** creates a symlink pointing at the file *in your git
  checkout* instead of copying it into the immutable `/nix/store`. That means you
  can edit that file and see changes without a rebuild. Most config in this repo
  is the opposite (store-managed, needs a rebuild) — this is a deliberate
  exception for a file you tweak often.

---

## Part 6 — Overlays and the unstable pin (why some packages are newer)

You'll see the same package name in several places; here's the precedence:

1. **Base `nixpkgs`** (pinned to `nixos-unstable` in `flake.nix` inputs) — the
   default source for most packages.
2. **Flake-level overlay** (in `flake.nix`) — adds `nordpass`/`waterfox` and
   **repoints** a handful of packages (`waybar`, `swww`, `slack`, `steam`, `go`,
   …) at `nixpkgs-unstable.legacyPackages`. This is how you keep *those specific*
   packages bleeding-edge without moving everything.
3. **In-system overlay** (in `users/default/nixos.nix`) — rebuilds `waybar` again
   with `-Dexperimental=true` to enable extra features.

If you ever wonder "why is my waybar different from stock nixpkgs?", it's these
two overlays stacking.

---

## Part 7 — How to make changes (cookbook)

| I want to… | Do this |
|------------|---------|
| Add a CLI tool for all machines | Add it to `pkgs/core.nix` (or `dev.nix`/`kube.nix`), `make switch` |
| Add a Linux-only GUI app | Add it to `pkgs/nixos.nix`, `make switch` |
| Change a Hyprland keybind | Edit `modules/desktop/hyprland/home.nix`, `make switch`, restart session |
| Enable a system service | Add `services.foo.enable = true;` to `users/default/nixos.nix` |
| Add a whole new host | Create `hardware/<name>.nix` + `machines/<name>.nix`, add a builder call in `flake.nix` |
| Try a build without activating | `make build-server`, or `nixos-rebuild build --flake .#desktop --impure` |
| Roll back a bad change | Reboot and pick the previous generation in systemd-boot, or `nixos-rebuild switch --rollback` |
| Update all packages | `make update` (runs `nix flake update`) then `make switch` |

**There is no test suite, linter, or CI.** "Verification" means a successful
`nixos-rebuild build`/`switch`. If it builds and activates, it's correct by
construction.

---

## Part 8 — How the other platforms differ (quick reference)

Same flake, same module library, different glue:

| Concern | Desktop (NixOS) | Server (NixOS) | macOS (Darwin) |
|---------|-----------------|----------------|----------------|
| Builder | `mkSys` | `mkServer` | `mkDarwin` |
| System file | `users/default/nixos.nix` | `nixos-server.nix` (minimal) | `darwin/configuration.nix` |
| Home file | `home-manager.nix` (Linux branch) | `home-manager-server.nix` (no GUI) | `home-manager.nix` (Darwin branch) |
| Window manager | Hyprland | none (headless) | yabai + skhd |
| Status bar | waybar | none | sketchybar |
| GUI apps from | Nix (`pkgs/nixos.nix`) | none | Homebrew casks |
| Containers | docker + libvirt/KVM | docker | colima/lima VM |
| Apply command | `make switch NIXNAME=desktop` | `make switch NIXNAME=server` | `make switch NIXNAME=macbook-m1` |

`machines/shared.nix` is imported by **all** of them (including Darwin), which is
why nix GC and flake settings are consistent everywhere.

---

## Glossary

- **Flake** — a repo with a standard `flake.nix` that declares pinned inputs and
  named outputs. Gives reproducible, lock-filed builds (`flake.lock`).
- **Derivation** — a build recipe for one store path. "Realising" it produces the
  actual `/nix/store/<hash>-name`.
- **Module** — a `.nix` file taking `{ config, pkgs, lib, ... }` and returning
  option settings (and/or `imports`). Merged with all other modules.
- **Option** — a typed setting like `services.openssh.enable` or
  `home.packages`. Modules set options; the module system merges them.
- **Overlay** — a function `final: prev: { … }` that adds to or overrides the
  package set.
- **home-manager** — manages a user's dotfiles and per-user packages; here it runs
  as a NixOS module so one rebuild does both.
- **Generation** — one built version of the whole system, symlinked at
  `/run/current-system`; selectable at boot for rollback.
- **toplevel** — `config.system.build.toplevel`, the single store path
  representing the entire built system.
- **Activation** — the script that switches the running system to a new
  generation (symlink, bootloader, systemd, home-manager).

---

*Generated as a reading aid for this repo. The authoritative source is always the
`.nix` files themselves — when in doubt, follow the `imports` chain starting at
`flake.nix`.*

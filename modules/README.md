# modules

Reusable NixOS / home-manager modules. Nothing here is auto-discovered — each module is imported explicitly from `users/default/*.nix` or `machines/<host>.nix`.

- `shell/`, `editors/nvim/`, `programs/`, `archive-downloads/` — home-manager
- `desktop/hyprland/`, `desktop/dunst/`, `vm/vfio/` — NixOS desktop
- `server/`, `media/`, `services/` — polaris

Not imported anywhere (kept as prior art): `desktop/{river,waybar,gtk}/`, `hardware/`, `editors/default.nix`, `programs/alacritty.nix`, `services/syncthing/`, `vm/parallels-guest.nix`. Grep for a module's path before assuming it's live.

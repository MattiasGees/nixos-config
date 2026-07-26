# Helper function to create server/headless NixOS configurations
# Uses shell-only home-manager config without GUI dependencies
name: { pkgs, nixpkgs, lib, home-manager, system, user, extraModules ? [] }:
nixpkgs.lib.nixosSystem {
  inherit system pkgs;

  modules = [
    ../hardware/${name}.nix
    ../machines/${name}.nix
    ../machines/shared.nix
    ../users/default/nixos-server.nix

    home-manager.nixosModules.home-manager {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.${user} = import ../users/default/home-manager-server.nix {
        inherit lib pkgs user;
      };
    }
  ] ++ extraModules;
}

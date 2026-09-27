# Legacy: VM builder, not called from flake.nix.
name: { nixpkgs, pkgs, lib, home-manager, system, user, }:

nixpkgs.lib.nixosSystem {
  inherit system;

  modules = [

    ../hardware/${name}.nix
    ../machines/${name}.nix
    # hyprland.nixosModules.default
    ../users/default/nixos.nix

    home-manager.nixosModules.home-manager {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.${user} = import ../users/default/home-manager.nix {
          inherit lib pkgs user;
        };
    }

  ];
}

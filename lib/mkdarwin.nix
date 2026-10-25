# This function creates a nix-darwin system.
name: { darwin, pkgs, lib, home-manager, system, user, githubKeys ? null }:

darwin.lib.darwinSystem {
  inherit system;

  specialArgs = { inherit system user githubKeys; };
  modules = [

    ../machines/${name}.nix
    ../machines/shared.nix
    ../darwin/configuration.nix
    ../darwin/paseo.nix
    ../darwin/paseo-agent.nix

    {
      documentation.enable = false;
      nixpkgs.config = { allowUnfree = true; };
    }

    home-manager.darwinModules.home-manager {
      home-manager.useUserPackages = true;
      home-manager.useGlobalPkgs = true;
      home-manager.backupFileExtension = "backup";
      home-manager.users.${user} = import ../users/default/home-manager.nix {
          inherit lib pkgs;
      };
    }

  ];
}

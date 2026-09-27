# Legacy: standalone home-manager builder, not called from flake.nix.
name: { pkgs, lib, home-manager, user }:

  home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    extraSpecialArgs = { inherit lib pkgs user; };
    modules = [
      ../users/default/home-manager.nix
      {
        home = {
          username = "${user}";
          homeDirectory = "/home/${user}";
          packages = [ pkgs.home-manager ];
          stateVersion = "23.05";
        };
      }
    ];
  }

# Cross-platform package set for the full home-manager profile
# (imported by users/default/home-manager.nix on desktop and Darwin).
{ pkgs, ... }:
let
in {
    imports = [
      ./core.nix
      ./dev.nix
      ./kube.nix
      # ./ssc.nix
    ];
	
     programs.zsh.enable = true;                            # Shell needs to be enabled
     programs.neovim.enable = false;
  }

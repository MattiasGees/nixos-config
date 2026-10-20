{
  description = "Mattias's Personal NixOS and Darwin System Flake Configuration";

  inputs =
    {
      nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
      nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
      nixpkgs-wayland.url = "github:nix-community/nixpkgs-wayland";

      home-manager = {
        url = "github:nix-community/home-manager/master";
        inputs.nixpkgs.follows = "nixpkgs-unstable";
      };

      darwin = {
        url = "github:lnl7/nix-darwin/master";
        inputs.nixpkgs.follows = "nixpkgs-unstable";
      };

      hyprland = {
        url = "github:hyprwm/Hyprland";
        inputs.nixpkgs.follows = "nixpkgs-unstable";
      };

      xremap-flake.url = "github:xremap/nix-flake";

      vmctl = {
        # vmctl is a PRIVATE repo — use git+ssh (SSH-key auth) rather than
        # github: (whose API fetcher needs a token for private repos). If vmctl
        # is ever made public, this can revert to "github:MattiasGees/vmctl".
        url = "git+ssh://git@github.com/MattiasGees/vmctl?ref=main";
        inputs.nixpkgs.follows = "nixpkgs-unstable";
      };

      conductor = {
        # conductor (the home dashboard) is PRIVATE too, hence git+ssh. polaris
        # runs a release: pin a tag, and `make update-conductor` moves the pin to
        # the newest one (docs/polaris/conductor.md). No `follows`: conductor
        # builds with its own pinned nixpkgs, as its CI tested it.
        url = "git+ssh://git@github.com/MattiasGees/conductor?ref=refs/tags/v0.4.0";
      };

      # SSH public keys published on GitHub, authorized for login on the Macs
      # and polaris. Pinned by hash in flake.lock; refresh after adding/removing
      # a key on GitHub with `nix flake update github-keys` (or `make update`).
      github-keys = {
        url = "file+https://github.com/mattiasgees.keys";
        flake = false;
      };

      nixpkgs-wayland.inputs.nixpkgs.follows = "nixpkgs";
    };

  outputs = inputs @ { self, xremap-flake, hyprland, nixpkgs, nixpkgs-unstable, home-manager, darwin, ... }:
    let
      mkDarwin = import ./lib/mkdarwin.nix;
      mkSys = import ./lib/mksys.nix;
      mkServer = import ./lib/mkserver.nix;
      user = "mattias";
      githubKeys = inputs.github-keys;
      system = "x86_64-linux";
      pkgs  = import nixpkgs {
      inherit system; 
      # allowUnsupportedSystem stays false: NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1
      # (formerly exported by the Makefile) forces meta.available = true for every
      # package, which makes Nix try to BUILD aarch64/Jetson-only redistributables
      # like cudaPackages.cuda_compat on x86_64 — they have no x86_64 src and die
      # with "variable $src or $srcs should point to the source" (nixpkgs#458799).
      # Pinning it here prunes them from the closure regardless of how the build is
      # invoked; without this, ollama-cuda fails to build on polaris.
      config = { allowUnfree = true; allowUnsupportedSystem = false; };
      overlays = [
        # Pin these to nixpkgs-unstable. Both inputs currently track
        # nixos-unstable, so this only matters if `nixpkgs` moves to a release branch.
        (final: prev: {
          waybar = inputs.nixpkgs-unstable.legacyPackages.${system}.waybar;
          swww = inputs.nixpkgs-unstable.legacyPackages.${system}.swww;
          _1password-gui = inputs.nixpkgs-unstable.legacyPackages.${system}._1password-gui;
          dunst = inputs.nixpkgs-unstable.legacyPackages.${system}.dunst;
          slack = inputs.nixpkgs-unstable.legacyPackages.${system}.slack;
          nwg-look = inputs.nixpkgs-unstable.legacyPackages.${system}.nwg-look;
          cartridges = inputs.nixpkgs-unstable.legacyPackages.${system}.cartridges;
          steam = inputs.nixpkgs-unstable.legacyPackages.${system}.steam;
          lutris = inputs.nixpkgs-unstable.legacyPackages.${system}.lutris;
          looking-glass = inputs.nixpkgs-unstable.legacyPackages.${system}.looking-glass;
          go = inputs.nixpkgs-unstable.legacyPackages.${system}.go;
        })
        # Immich ML on polaris: build onnxruntime WITH CUDA (RTX 3080) and WITHOUT
        # OpenVINO. Immich's provider preference is [CUDA, MIGraphX, OpenVINO, …,
        # CPU]. nixpkgs defaults openvinoSupport = stdenv.isLinux (on); with it
        # compiled in, Immich auto-selected OpenVINO, grabbed a GPU device, and
        # failed to compile the face/OCR models ([GPU] ProgramBuilder build failed)
        # -> HTTP 500 on every ML request. cudaSupport adds the
        # CUDAExecutionProvider (much faster than CPU for the face/CLIP/OCR
        # backlog); openvinoSupport=false keeps the broken provider out. Immich
        # then picks CUDA first.
        #
        # NB: the ML systemd unit ALSO needs the NVIDIA driver lib (libcuda.so),
        # which is not in the store — see modules/media/immich.nix (LD_LIBRARY_PATH
        # -> /run/opengl-driver/lib). Device access comes from accelerationDevices.
        #
        # Override the TOP-LEVEL (C++) onnxruntime, NOT python3Packages.onnxruntime:
        # the python module is a wheel built from `onnxruntime.dist` and only the C++
        # package carries these args (the python one errors on them). It takes the
        # C++ package as input via python-packages.nix (`onnxruntime =
        # pkgs.onnxruntime.override { python3Packages = self; pythonSupport = true;
        # }`), so this `.override` merges and the flags propagate into the wheel,
        # which then auto-links the CUDA runtime libs (gated on cudaSupport).
        # Heavy build: pulls the CUDA toolkit + cuDNN and compiles from source.
        (final: prev: {
          onnxruntime = prev.onnxruntime.override {
            openvinoSupport = false;
            cudaSupport = true;
          };
        })
      ];
      };
    in
    {

      nixosConfigurations.desktop = mkSys "desktop" rec {
         inherit home-manager user nixpkgs xremap-flake hyprland system pkgs;
         lib = pkgs.lib;
      };

      nixosConfigurations.server = mkServer "server" rec {
         inherit home-manager user nixpkgs system pkgs;
         lib = pkgs.lib;
      };

      nixosConfigurations.server-arm64 = mkServer "server" rec {
         inherit home-manager user nixpkgs;
         system = "aarch64-linux";
         pkgs = import nixpkgs {
           system = "aarch64-linux";
           config = { allowUnfree = true; };
         };
         lib = pkgs.lib;
      };

      nixosConfigurations.polaris = mkServer "polaris" rec {
         inherit home-manager user nixpkgs githubKeys system pkgs;
         lib = pkgs.lib;
         # Hand-maintained hardware extras (GPU + ZFS/swap) kept separate so
         # hardware/polaris.nix can be overwritten wholesale from
         # nixos-generate-config, and so the aarch64 VM doesn't inherit them.
         extraModules = [
           ./hardware/polaris-extra.nix
           ./modules/server/vmctl.nix
           { _module.args.vmctlPackages = inputs.vmctl.packages.${system}; }
           # The conductor flake's module brings its own package (the tagged release);
           # conductor.nix takes the house config template from the same input.
           inputs.conductor.nixosModules.default
           { _module.args.conductorSrc = inputs.conductor; }
           ./modules/services/conductor.nix
         ];
      };

      nixosConfigurations.polaris-vm = mkServer "polaris-vm" rec {
         inherit home-manager user nixpkgs githubKeys;
         system = "aarch64-linux";
         pkgs = import nixpkgs {
           system = "aarch64-linux";
           config = { allowUnfree = true; };
         };
         lib = pkgs.lib;
      };

      # Standalone home-manager configurations for non-NixOS systems
      # Automatically available for both x86_64-linux and aarch64-linux
      homeConfigurations =
        let
          mkHomeConfig = systemArch:
            let
              systemPkgs = import nixpkgs {
                system = systemArch;
                config = { allowUnfree = true; };
              };
            in
            home-manager.lib.homeManagerConfiguration {
              pkgs = systemPkgs;
              modules = [
                ./users/default/home-manager-server.nix
                {
                  home = {
                    username = builtins.getEnv "USER";
                    homeDirectory = builtins.getEnv "HOME";
                    stateVersion = "23.05";
                  };
                }
              ];
            };
        in
        {
          # Generate configs for all Linux architectures
          "${user}@x86_64-linux" = mkHomeConfig "x86_64-linux";
          "${user}@aarch64-linux" = mkHomeConfig "aarch64-linux";

          # Default to current system
          ${user} = mkHomeConfig builtins.currentSystem;
        };

      darwinConfigurations.macbook-m1 = mkDarwin "macbook-m1" rec {
        inherit darwin home-manager user githubKeys;
        system = "aarch64-darwin";
        pkgs = import nixpkgs {
          inherit system;
          config = { allowUnfree = true; };
        };
        lib = pkgs.lib;
      };

      darwinConfigurations.pacesetter = mkDarwin "pacesetter" rec {
        inherit darwin home-manager user githubKeys;
        system = "aarch64-darwin";
        pkgs = import nixpkgs {
          inherit system;
          config = { allowUnfree = true; };
        };
        lib = pkgs.lib;
      };

      darwinConfigurations.macbook-x86 = mkDarwin "macbook-x86" rec {
        inherit darwin home-manager user;
        system = "x86_64-darwin";
        pkgs = import nixpkgs {
          inherit system;
          config = { allowUnfree = true; };
        };
        lib = pkgs.lib;
      };

      checks.x86_64-linux.polaris-zfs =
        import ./tests/polaris-zfs.nix { inherit pkgs; };

    };
}

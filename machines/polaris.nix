{ config, pkgs, lib, githubKeys, ... }:
{
  imports = [
    ../modules/server/zfs.nix
    ../modules/server/virtualisation.nix
    ../modules/server/tailscale.nix
    ../modules/server/cloudflared.nix
    ../modules/server/postgresql.nix
    ../modules/server/restic.nix
    ../modules/server/monitoring.nix
    ../modules/server/data-nfs-backup.nix
    ../modules/server/mattias-nfs.nix
    ../modules/server/op-secrets.nix
    # No nvidia.nix here: polaris-vm (aarch64) inherits this file, so the
    # driver is wired via hardware/polaris-extra.nix instead.
    ../modules/media/common.nix
    ../modules/media/plex.nix
    ../modules/media/sonarr.nix
    ../modules/media/radarr.nix
    ../modules/media/prowlarr.nix
    ../modules/media/bazarr.nix
    ../modules/media/seerr.nix
    ../modules/media/immich.nix
    ../modules/services/miniflux.nix
    ../modules/services/karakeep.nix
    ../modules/services/outline.nix
    ../modules/services/filebrowser.nix
    ../modules/media/ollama.nix
    ../modules/media/open-webui.nix
    ../modules/services/pihole/pihole.nix
    ../modules/media/caddy.nix
    ../modules/media/seedbox-downloads.nix
    ../modules/media/recyclarr.nix
  ];

  networking.hostName = "polaris";

  # Stable kernel, not linuxPackages_latest: ZFS often lags the newest kernel.
  boot.kernelPackages = pkgs.linuxPackages;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # IOMMU passthrough mode, ready for future GPU passthrough. IOMMU itself is
  # on via BIOS + the AMD kernel default; `amd_iommu=on` is NOT a valid option
  # ("AMD-Vi: Unknown option - 'on'" in dmesg), so only iommu=pt is set.
  boot.kernelParams = [ "iommu=pt" ];

  # Static networking. nixos-server.nix enables NetworkManager; force it off so
  # it doesn't fight the declarative config below.
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = lib.mkDefault false;
  # Bridge the NIC (enp6s0) so KVM guests (vmctl) get first-class LAN
  # addresses: the host's static IP lives on br0, enp6s0 is an IP-less port.
  networking.bridges.br0.interfaces = [ "enp6s0" ];
  networking.interfaces.br0.ipv4.addresses = [
    { address = "192.168.1.50"; prefixLength = 24; }
  ];
  networking.defaultGateway = "192.168.1.1";
  # Pi-hole on the Pi first, Google as fallback (tried in order). Not the
  # router: it returned SERVFAIL for some public domains, which silently broke
  # Karakeep's crawler ("Failed to resolve hostname").
  networking.nameservers = [ "192.168.1.86" "8.8.8.8" ];

  # SSH: key-only, with the keys from github.com/mattiasgees.keys (the
  # `github-keys` flake input).
  users.users.mattias.openssh.authorizedKeys.keyFiles = [ githubKeys ];
  services.openssh.settings.PasswordAuthentication = false;

  # Read-only login for the Paseo investigation agent. systemd-journal lets it
  # read logs; deliberately NOT in wheel/docker/libvirtd, and NOT in
  # nix.settings.trusted-users. The private key is held by the agent user on the
  # Mac; only the public key is declared here.
  users.users.paseo-agent = {
    isNormalUser = true;
    home = "/home/paseo-agent";
    group = "users";
    extraGroups = [ "systemd-journal" ];
    shell = pkgs.zsh;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBdx8VAsOS3SjaTZgvKnfRdg6fyQ1AfUmcQsASzhqbyA paseo-agent@mattias-macbook"
    ];
  };
  # Lock down what the agent's SSH session can do: no forwarding or tunnels.
  services.openssh.extraConfig = lib.mkAfter ''
    Match User paseo-agent
      AllowTcpForwarding no
      AllowAgentForwarding no
      X11Forwarding no
      PermitTunnel no
  '';

  # Claude Code plugins/marketplaces/MCP servers, set up on each switch by the
  # same bootstrap the Mac uses (claude-code itself comes from pkgs/dev.nix).
  home-manager.users.mattias.imports = [ ../modules/programs/claude-code-bootstrap.nix ];

  # Terminfo for kitty/alacritty/foot/wezterm/… so SSH sessions from those
  # terminals don't fail with "can't find terminal definition for xterm-kitty".
  environment.enableAllTerminfo = true;
}

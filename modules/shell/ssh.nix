# Optimized SSH client configuration
{ config, lib, ... }:

{
  programs.ssh = {
    enable = true;
    # Opt out of home-manager's soon-to-be-removed implicit defaults; we set the
    # ones we want explicitly under settings."*" (the `Host *` block) below.
    enableDefaultConfig = false;

    settings."*" = {
      # Connection multiplexing - reuse existing connections for new sessions
      ControlMaster = "auto";
      ControlPath = "~/.ssh/control-%C";
      ControlPersist = "10m";

      # Compression can help on slower networks
      Compression = true;

      # Keep connections alive
      ServerAliveInterval = 60;
      ServerAliveCountMax = 3;
    };

    extraConfig = ''
      # Use faster ciphers (AES-GCM is hardware accelerated on modern CPUs)
      Ciphers chacha20-poly1305@openssh.com,aes128-gcm@openssh.com,aes256-gcm@openssh.com

      # Auto-accept first-seen Tailscale host keys (changed keys are still
      # rejected). Remove for strict checking.
      Host *.ts.net
        StrictHostKeyChecking accept-new
        UserKnownHostsFile ~/.ssh/known_hosts

      # Reuse connections for git operations
      Host github.com gitlab.com
        ControlMaster auto
        ControlPersist 600
    '';
  };
}

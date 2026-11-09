# Nightly mirror of every GitHub repo I own (+ wikis) and all my gists onto
# polaris, so a GitHub lockout loses no code: bare `git clone --mirror`s under
# /srv/data/backups/github, covered by restic and the NFS mirror like the rest
# of /srv/data. Repos deleted on GitHub keep their last mirror. Design archived
# in the Homecluster/NixOS wiki (Specs, 2026-10-16); runbook in the wiki
# (Documentation › Cloud backups).
#
# Own script (github-backup.sh) rather than nixpkgs' github-backup: that tool
# can't limit itself to owned repos and stores repos by bare name, so
# same-named repos of different owners collide. Token from
# op://polaris/github-backup/token.
{ pkgs, ... }:
{
  # Shared with gdrive-backup.nix (identical definitions merge).
  users.users.cloud-backup = {
    isSystemUser = true;
    group = "cloud-backup";
  };
  users.groups.cloud-backup = { };

  opSecrets.github-backup = {
    template = ./github-backup.env.tpl;
    path = "/var/lib/secrets/github-backup.env";
    owner = "cloud-backup";
  };

  systemd.tmpfiles.rules = [
    "d /srv/data/backups/github 0750 cloud-backup cloud-backup - -"
  ];

  systemd.services.github-backup = {
    description = "Mirror owned GitHub repos and gists to /srv/data/backups";
    after = [ "network-online.target" "zfs-mount.service" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.gh pkgs.git pkgs.gnugrep pkgs.coreutils ];
    environment = {
      HOME = "/var/lib/github-backup";
      GH_CONFIG_DIR = "/var/lib/github-backup/gh";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "cloud-backup";
      Group = "cloud-backup";
      StateDirectory = "github-backup";
      EnvironmentFile = "/var/lib/secrets/github-backup.env";
      # See gdrive-backup.nix: never fill the root disk if tank/data is locked.
      ExecStartPre = "${pkgs.util-linux}/bin/mountpoint -q /srv/data";
      ExecStart = "${pkgs.bash}/bin/bash ${./github-backup.sh}";
      ProtectSystem = "strict";
      ReadWritePaths = [ "/srv/data/backups/github" ];
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };

  systemd.timers.github-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "01:30";
      Persistent = true;
    };
  };
}

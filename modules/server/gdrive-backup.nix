# Nightly pull of Google Drive (two accounts) onto polaris, so being locked out
# of either account loses nothing: My Drive, Shared with me and every shared
# drive, with native Docs/Sheets/Slides exported to docx/xlsx/pptx. Lands under
# /srv/data/backups, which restic (03:00, offsite) and the NFS mirror already
# cover. Design archived in the Homecluster/NixOS wiki (Specs, 2026-10-16);
# setup/restore in the wiki runbook (Documentation › Cloud backups).
#
# Read-only OAuth scope, one OAuth client shared by both accounts. It must be
# "In production": in "Testing", Google expires refresh tokens after 7 days.
# Deletion handling (.deleted/<date>, 90 days; --max-delete) lives in
# gdrive-backup.sh. Secrets: op://polaris/gdrive-{oauth,personal,work}.
{ pkgs, lib, ... }:
let
  # account (= rclone remote in rclone-gdrive.conf.tpl) → nightly start time,
  # staggered and ahead of restic at 03:00.
  accounts = {
    personal = "01:00";
    work = "01:15";
  };
in
{
  # Shared with github-backup.nix (identical definitions merge).
  users.users.cloud-backup = {
    isSystemUser = true;
    group = "cloud-backup";
  };
  users.groups.cloud-backup = { };

  opSecrets.rclone-gdrive = {
    template = ./rclone-gdrive.conf.tpl;
    path = "/var/lib/secrets/rclone-gdrive.conf";
    owner = "cloud-backup";
  };

  systemd.tmpfiles.rules = lib.mapAttrsToList
    (acct: _: "d /srv/data/backups/gdrive-${acct} 0750 cloud-backup cloud-backup - -")
    accounts;

  systemd.services = lib.mapAttrs' (acct: _: lib.nameValuePair "gdrive-backup-${acct}" {
    description = "Back up Google Drive (${acct}) to /srv/data/backups";
    after = [ "network-online.target" "zfs-mount.service" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.rclone pkgs.jq pkgs.coreutils ];
    environment = {
      RCLONE_CONF_SRC = "/var/lib/secrets/rclone-gdrive.conf";
      HOME = "/var/lib/gdrive-backup/${acct}";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "cloud-backup";
      Group = "cloud-backup";
      StateDirectory = "gdrive-backup/${acct}";
      # tank/data is encrypted: if its key didn't load, /srv/data is a plain
      # dir on the root disk. Refuse to fill that.
      ExecStartPre = "${pkgs.util-linux}/bin/mountpoint -q /srv/data";
      ExecStart = "${pkgs.bash}/bin/bash ${./gdrive-backup.sh} ${acct}";
      ProtectSystem = "strict";
      ReadWritePaths = [ "/srv/data/backups/gdrive-${acct}" ];
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  }) accounts;

  systemd.timers = lib.mapAttrs' (acct: time: lib.nameValuePair "gdrive-backup-${acct}" {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = time;
      Persistent = true;
    };
  }) accounts;
}

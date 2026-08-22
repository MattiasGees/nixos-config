{ config, pkgs, lib, ... }:

let
  nixConfigDir = "${config.home.homeDirectory}/Documents/git/nixos-config";
  archiveScript = "${nixConfigDir}/scripts/archive-downloads.sh";
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
in

{
  # macOS: Use launchd
  launchd.agents.archive-downloads = lib.mkIf isDarwin {
    enable = true;
    config = {
      ProgramArguments = [ archiveScript ];

      StartCalendarInterval = [{
        Weekday = 1;  # Monday
        Hour = 9;
        Minute = 0;
      }];

      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/archive-downloads-stdout.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/archive-downloads-stderr.log";

      RunAtLoad = false;
    };
  };

  # Linux: Use systemd
  systemd.user.services.archive-downloads = lib.mkIf isLinux {
    Unit = {
      Description = "Archive Downloads folder";
    };

    Service = {
      Type = "oneshot";
      ExecStart = archiveScript;
    };
  };

  systemd.user.timers.archive-downloads = lib.mkIf isLinux {
    Unit = {
      Description = "Archive Downloads folder weekly";
    };

    Timer = {
      OnCalendar = "Mon *-*-* 09:00:00";
      Persistent = true;  # Run on next boot if missed
    };

    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}

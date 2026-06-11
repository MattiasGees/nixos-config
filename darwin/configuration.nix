#
#  Specific system configuration settings for MacBook
#
#  flake.nix
#   └─ ./darwin
#       ├─ ./default.nix
#       └─ ./configuration.nix *
#

{ config, pkgs, user, system, ... }:
{
  security.pam.services.sudo_local.touchIdAuth = true;

  users.users."${user}" = {               # macOS user
    home = "/Users/${user}";
    shell = pkgs.zsh;                     # Default shell
  };
  # environment.systemPackages = [ 
  #   (import (fetchTarball https://install.devenv.sh/latest)).default
  # ];

  # Moved all the global package setup to pkgs/default.nix

  nixpkgs.config.allowBroken = true;

  homebrew = {                            # Declare Homebrew using Nix-Darwin
    enable = true;
    onActivation = {
      autoUpdate = false;                 # Auto update packages
      upgrade = false;
      cleanup = "zap";                    # Uninstall not listed packages and casks
    };
    taps = [
      "FelixKratz/formulae"
      # "homebrew/cask-drivers"
      "koekeishiya/formulae"
      "theseal/ssh-askpass"
    ];
    brews = [
      "FelixKratz/formulae/sketchybar"
      "theseal/ssh-askpass/ssh-askpass"
      "ddcctl"
      "ykman"
      "gpg"
      "openssh"
      "pinentry"
      "blueutil"
      "node"
      "wifi-password"
      "switchaudio-osx"
      "oras"
      "coreutils"
      "mosh"
    ];
    casks = [
      "firefox"
      "akiflow"
      "corelocationcli"
      "beeper"
      "launchcontrol"
      "orbstack"
      "kitty"
      "gpg-suite"
      "google-chrome"
      "now-tv-player"
      "plex"
      "steam"
      "ghostty"
      "alacritty"
      "slack"
      "spotify"
      "claude-code"
      "notion"
      "raycast"
      "transmission"
      "gitify"
      "via"
      "vlc"
      "visual-studio-code"
      "tidal"
      "insomnia"
      "nordvpn"
      "nordpass"
      "iterm2"
      # installs new version that I do not like
      # "readdle-spark"
      "element"
      "zoom"
      "microsoft-teams"
      "sf-symbols"
      "hiddenbar"
    ];
  };

  services = {
    yabai = {                             # Tiling window manager
      enable = true;
      enableScriptingAddition = true;     # Loads SA on startup & sets up sudoers
      config = {                          # Other configuration options
        layout = "bsp";
        auto_balance = "on";
        split_ratio = "0.50";
        window_border = "on";
        window_placement = "second_child";
        focus_follows_mouse = "off";
        mouse_follows_focus = "on";
        mouse_action1 = "move";
        mouse_action2 = "resize";
        mouse_drop_action = "swap";
        top_padding = "10";
        bottom_padding = "10";
        left_padding = "10";
        right_padding = "10";
        window_gap = "10";
        external_bar = "all:28:0";
        insert_feedback_color = "0xffd75f5f";
        active_window_border_color = "0xffAFDCA4";
        normal_window_border_color = "0xffaaaaaa";
        active_window_border_topmost = "on";
        window_shadow = "on";
        window_opacity = "off";
        window_border_width = 5;
      };
      extraConfig = ''
        yabai -m rule --add app='^Emacs$' manage=on
        yabai -m rule --add title='Preferences' manage=off layer=above
        yabai -m rule --add title='NordPass Password Manager' manage=off layer=above
        yabai -m rule --add title='^(Opening)' manage=off layer=above
        yabai -m rule --add title='Library' manage=off layer=above
        yabai -m rule --add app='^System Preferences$' manage=off layer=above
        yabai -m rule --add app='Activity Monitor' manage=off layer=above
        yabai -m rule --add app='Finder' manage=off layer=above
        yabai -m rule --add app='^System Information$' manage=off layer=above
      '';                                 # Specific rules for what is managed and layered.
    };
    skhd = {
      enable = true;
      skhdConfig = ''
        shift + alt - r : sudo launchctl kickstart -k system/org.nixos.yabai-sa && launchctl kickstart -k gui/$(id -u)/org.nixos.skhd && brew services restart sketchybar
        shift + alt - y : launchctl kickstart -k gui/$(id -u)/org.nixos.yabai && sudo launchctl kickstart -k system/org.nixos.yabai-sa

        shift + alt - t : ghostty

        shift + alt - f : firefox

        alt - h : yabai -m window --focus west
        alt - j : yabai -m window --focus south
        alt - k : yabai -m window --focus north
        alt - l : yabai -m window --focus east

        shift + alt - h : yabai -m window --warp west
        shift + alt - j : yabai -m window --warp south
        shift + alt - k : yabai -m window --warp north
        shift + alt - l : yabai -m window --warp east

        shift + alt - 1 : yabai -m window --space 1
        shift + alt - 2 : yabai -m window --space 2
        shift + alt - 3 : yabai -m window --space 3
        shift + alt - 4 : yabai -m window --space 4
        shift + alt - 5 : yabai -m window --space 5
        shift + alt - 6 : yabai -m window --space 6
        shift + alt - 7 : yabai -m window --space 7
        shift + alt - 8 : yabai -m window --space 8
        shift + alt - 9 : yabai -m window --space 9
        shift + alt - 0 : yabai -m window --space 10

        alt - r : yabai -m space --rotate 90

        ctrl + alt - h : \
            yabai -m window --resize left:-100:0 ; \
            yabai -m window --resize right:-100:0

        ctrl + alt - j : \
            yabai -m window --resize bottom:0:100 ; \
            yabai -m window --resize top:0:100

        ctrl + alt - k : \
            yabai -m window --resize top:0:-100 ; \
            yabai -m window --resize bottom:0:-100

        ctrl + alt - l : \
            yabai -m window --resize right:100:0 ; \
            yabai -m window --resize left:100:0

        alt - s : yabai -m window --toggle split

        alt - f : yabai -m window --toggle zoom-fullscreen

        alt - g : yabai -m space --toggle padding; yabai -m space --toggle gap

        alt - c : yabai -m window --toggle float;\
                  yabai -m window --grid 4:4:1:1:2:2

        shift + alt - 0 : yabai -m space --balance

        shift + ctrl + alt - h : yabai -m window --insert west
        shift + ctrl + alt - j : yabai -m window --insert south
        shift + ctrl + alt - k : yabai -m window --insert north
        shift + ctrl + alt - l : yabai -m window --insert east

        shift + alt - n : osascript -e 'tell application "Spotify" to Next Track'
        shift + alt - p : osascript -e 'tell application "Spotify" to Previous Track'

        shift + ctrl + alt - up : osascript -e 'tell application "Spotify" to set sound volume to 100'
        shift + ctrl + alt - down : osascript -e 'tell application "Spotify" to set sound volume to 20'

        shift + alt - down : osascript -e "set volume output volume ((output volume of (get volume settings)) - 3)"
        shift + alt - up : osascript -e "set volume output volume ((output volume of (get volume settings)) + 3)"

        shift + ctrl + alt - c : echo "https://calendly.com/tpmeadows1/30min" | pbcopy

        shift + alt - space : osascript -e 'tell application "Spotify" to playpause'

        shift + alt - p : osascript ~/.config/scripts/flow.applescript

        shift + ctrl - 1 : m1ddc display 1 set input 17
        shift + ctrl - 2 : m1ddc display 1 set input 15
        shift + ctrl - 3 : m1ddc display 1 set input 27

        ctrl + alt - 1  : yabai -m display --focus 1
        ctrl + alt - 2  : yabai -m display --focus 2

        lalt - space : yabai -m window --toggle float; sketchybar --trigger window_focus
        shift + lalt - f : yabai -m window --toggle zoom-fullscreen; sketchybar --trigger window_focus
        lalt - f : yabai -m window --toggle zoom-parent; sketchybar --trigger window_focus
      '';                                 # Hotkey config
    };
    jankyborders = {
      enable = true;
      active_color = "0xffAFDCA4";
      inactive_color = "0xffaaaaaa";
      hidpi = true;
      ax_focus = true;
      width = 9.0;
    };
  }; 

  system = {
    primaryUser = "mattias";
    defaults = {
      NSGlobalDomain = {                  # Global macOS system settings
        KeyRepeat = 1;
        NSAutomaticCapitalizationEnabled = false;
        NSAutomaticSpellingCorrectionEnabled = false;
        NSAutomaticWindowAnimationsEnabled = false;
        _HIHideMenuBar = true;
        "com.apple.swipescrolldirection" = false;
        AppleTemperatureUnit = "Celsius";

      };
      dock = {               # Dock settings
        autohide = true;
        autohide-delay = 0.0;
        autohide-time-modifier = 0.0;
        dashboard-in-overlay = true;
        expose-animation-duration = 0.0;
        launchanim = false;
        orientation = "left";
        showhidden = true;
        mru-spaces = false;
        show-recents = false;
        static-only = true;
        tilesize = 40;
      };
      finder = {                          # Finder settings
        QuitMenuItem = true;              # I believe this probably will need to be true if using spacebar
        AppleShowAllExtensions = true; 
      };  
      trackpad = {                        # Trackpad settings
        Clicking = true;
        TrackpadRightClick = true;
      };
      SoftwareUpdate = {
        AutomaticallyInstallMacOSUpdates = true;
      };
    };
    activationScripts.postActivation.text = ''
      sudo chsh -s ${pkgs.zsh}/bin/zsh
      # Reload yabai scripting addition after rebuild
      sudo /run/current-system/sw/bin/yabai --load-sa 2>/dev/null || true
    ''; # Since it's not possible to declare default shell, run this command after build
    stateVersion = 5;
  };
}

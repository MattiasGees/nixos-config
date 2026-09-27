{ config, lib, pkgs, ... }:

let
  touchpad = ''
        touchpad {
          natural_scroll=true
          middle_button_emulation=true
          tap-to-click=true
        }
      '';
  gestures = ''
      gestures {
        workspace_swipe=true
        workspace_swipe_fingers=3
        workspace_swipe_distance=100
      }
    '';
in
let
  hyprlandConf = ''
    #env = MESA_GL_VERSION_OVERRIDE,3.3
    #env = MESA_GLSL_VERSION_OVERRIDE,330
    #env = MESA_GLES_VERSION_OVERRIDE,3.1


    general {
      border_size=5
      no_focus_fallback = true
      gaps_in=5
      gaps_out=7
      col.active_border=0xffAFDCA4
      col.inactive_border=0xffaaaaaa
      layout=dwindle
    }

    decoration {
      rounding=8
      active_opacity=1
      inactive_opacity=1
      fullscreen_opacity=1
      drop_shadow=false
    }

    animations {
      enabled=true
      bezier = myBezier,0.1,0.7,0.1,1.05
      animation=fade,1,7,default
      animation=windows,1,7,myBezier
      animation=windowsOut,1,3,default,popin 60%
      animation=windowsMove,1,7,myBezier
      animation=workspaces,1,8,default,fade
    }

    input {
      kb_layout=us
      follow_mouse=1
      repeat_delay=200
      repeat_rate=50
      numlock_by_default=1
      accel_profile=flat
      sensitivity=0.8
      ${touchpad}
    }

    ${gestures}

    dwindle {
      pseudotile=false
      force_split=2
    }

    misc {
      disable_hyprland_logo = true
      disable_splash_rendering = true
      focus_on_activate = true
    }

    debug {
      damage_tracking=2
    }

    $mainMod = ALT
    bindm=SUPER,mouse:272,movewindow
    bindm=SUPER,mouse:273,resizewindow

    bind=$mainMod SHIFT,T,exec,${pkgs.kitty}/bin/kitty
    bind=SUPER,W,killactive,
    bind=SUPER,Escape,exit,
    bind=SUPER,E,exec,${pkgs.pcmanfm}/bin/pcmanfm
    bind=$mainMod,S,togglefloating,
    bind=SUPER,Space,exec,rofi -show drun
    bind=SUPER,P,pseudo,
    bind=SUPER,R,forcerendererreload
    bind=SUPER SHIFT,R,exec,${pkgs.hyprland}/bin/hyprctl reload
    bind = $mainMod SHIFT, F, exec, firefox

    #windowrule=float,^(Rofi)$
    windowrule=float,title:^(Volume Control)$
    windowrule=float,title:^(Picture-in-Picture)$
    windowrule=pin,title:^(Picture-in-Picture)$
    windowrule=move 75% 75% ,title:^(Picture-in-Picture)$
    windowrule=size 24% 24% ,title:^(Picture-in-Picture)$

# Core binds
    bind = $mainMod, S, togglefloating,
    bind = $mainMod, J, togglesplit, # dwindle
    bind=  $mainMod,F,fullscreen,0

# Screenshot binds
    bind = $mainMod SHIFT, S, exec, grimblast copy area
    bind = $mainMod, S, exec, grimblast copy window
    bind = $mainMod SHIFT, D, exec, grimblast save area
    bind = $mainMod, D, exec, grimblast save window

# Move focus with mainMod + h/j/k/l
    bind = $mainMod, h, movefocus, l
    bind = $mainMod, l, movefocus, r
    bind = $mainMod, k, movefocus, u
    bind = $mainMod, j, movefocus, d

# Switch workspaces with Control + [0-9]
    bind = Control, 1, workspace, 1
    bind = Control, 2, workspace, 2
    bind = Control, 3, workspace, 3
    bind = Control, 4, workspace, 4
    bind = Control, 5, workspace, 5
    bind = Control, 6, workspace, 6
    bind = Control, 7, workspace, 7
    bind = Control, 8, workspace, 8
    bind = Control, 9, workspace, 9
    bind = Control, 0, workspace, 10

# Move active window to a workspace with mainMod + SHIFT + [0-9]
    bind = $mainMod SHIFT, 1, movetoworkspacesilent, 1
    bind = $mainMod SHIFT, 2, movetoworkspacesilent, 2
    bind = $mainMod SHIFT, 3, movetoworkspacesilent, 3
    bind = $mainMod SHIFT, 4, movetoworkspacesilent, 4
    bind = $mainMod SHIFT, 5, movetoworkspacesilent, 5
    bind = $mainMod SHIFT, 6, movetoworkspacesilent, 6
    bind = $mainMod SHIFT, 7, movetoworkspacesilent, 7
    bind = $mainMod SHIFT, 8, movetoworkspacesilent, 8
    bind = $mainMod SHIFT, 9, movetoworkspacesilent, 9
    bind = $mainMod SHIFT, 0, movetoworkspacesilent, 10

# Media controls (playerctl)
    bind = $mainMod SHIFT, n, exec, playerctl next
    bind = $mainMod SHIFT, p, exec, playerctl previous
    bind = $mainMod SHIFT, space, exec, playerctl play-pause

# Resize active window with mainMod + Control + h/j/k/l, then volume (pamixer)
    binde = $mainMod Control,l,resizeactive,50 0
    binde = $mainMod Control,h,resizeactive,-50 0
    binde = $mainMod Control,k,resizeactive,0 -50
    binde = $mainMod Control,j,resizeactive,0 50

    binde = $mainMod SHIFT, up, exec, pamixer --increase 10
    binde = $mainMod SHIFT, down, exec, pamixer --decrease 10
    binde = $mainMod Control, space, exec, pamixer --toggle-mute

    exec-once=dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
    exec=hyprctl setcursor Bibata-Modern-Classic 24
    exec-once=systemctl --user start waybar.service
    exec-once=systemctl --user start xremap.service
    exec-once=wpaperd

    exec-once=hyprctl dispatch exec "[workspace 1 silent]" kitty
    exec-once=hyprctl dispatch exec "[workspace 2 silent]" kitty
    exec-once=hyprctl dispatch exec "[workspace 3 silent]" firefox
    exec-once=hyprctl dispatch exec "[workspace 4 silent]" slack
    exec-once=hyprctl dispatch exec "[workspace 6 silent]" spotify
    exec-once=hyprctl dispatch exec "[workspace 7 silent]" firefox
    exec-once=hyprctl dispatch exec "[workspace 8 silent]" mailspring
    exec-once=hyprctl dispatch exec "[workspace 9 silent]" nordpass

  '';
in
{
  xdg.configFile."hypr/hyprland.conf".text = hyprlandConf;

}

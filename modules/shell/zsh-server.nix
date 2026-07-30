# Server-friendly zsh config without out-of-store symlinks
{ config, pkgs, lib, ... }:
let
  # Read the extra config files directly (now cross-platform)
  extras = [
    ./zshrc  # Now cross-platform with defensive checks
    ./shell_exports
    ./shell_aliases
    ./shell_functions  # portable halp (reads ~/.config/nixos-shell), no repo-path dep
  ];
  extraInitExtra = builtins.foldl' (soFar: new: soFar + "\n" + builtins.readFile new) "" extras;
in
{
  # Create gitignore inline instead of symlinking
  xdg.configFile."global-gitignore".text = builtins.readFile ./gitignore;

  # Copy shell config files for halp to read
  xdg.configFile."nixos-shell/shell_aliases".source = ./shell_aliases;
  xdg.configFile."nixos-shell/shell_functions".source = ./shell_functions;

  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    enableCompletion = false;
    history.size = 10000;
    shellAliases = {
      cls = "clear";
    };

    oh-my-zsh = {
      enable = true;
      plugins = [ "git" "z" ];
      custom = "$HOME/.config/zsh_nix/custom";
    };

    initContent = ''
      # Spaceship
      source ${pkgs.spaceship-prompt}/share/zsh/site-functions/prompt_spaceship_setup
      autoload -U promptinit; promptinit
      # Display red dots while waiting for completion
      COMPLETION_WAITING_DOTS="true"
    '' + extraInitExtra;

    plugins = [
      {
        name = "zsh-syntax-highlighting";
        src = pkgs.fetchFromGitHub {
          owner = "zsh-users";
          repo = "zsh-syntax-highlighting";
          rev = "0.6.0";
          sha256 = "0zmq66dzasmr5pwribyh4kbkk23jxbpdw4rjxx0i7dx8jjp2lzl4";
        };
      }
    ];
  };
}

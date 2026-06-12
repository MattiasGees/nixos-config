# taken from https://github.com/aywrite/nix-config
{ config, pkgs, ... }:
let
  # stuffing the gitignore stuff in here as well
  nixConfigDir = "${config.home.homeDirectory}/Documents/git/nixos-config";
  inherit (config.lib.file) mkOutOfStoreSymlink;

  # this idea is from https://github.com/BrianHicks/dotfiles.nix/blob/master/dotfiles/zsh.nix
  extras = [
    ./zshrc
    ./shell_exports
    ./shell_aliases
    ./shell_functions
  ];
  extraInitExtra = builtins.foldl' (soFar: new: soFar + "\n" + builtins.readFile new) "" extras;
in
{
  xdg.configFile."global-gitignore".source = mkOutOfStoreSymlink "${nixConfigDir}/modules/shell/gitignore";

  # .zshenv
  programs.zsh = {
    enable = true;
    autosuggestion.enable = true;
    enableCompletion = false;
    history.size = 10000;
    shellAliases = {
      cls = "clear";
    };

    oh-my-zsh = {                               # Extra plugins for zsh
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
    '' + extraInitExtra;                                         # Zsh theme

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

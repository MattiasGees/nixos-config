#
# Git
#

{
  programs = {
    git = {
      enable = true;
      userName = "Mattias Gees";
      userEmail = "mattias@gees.dev";
      extraConfig = {
        core = { askpass = "/opt/homebrew/bin/ssh-askpass"; excludesFile = "~/.config/global-gitignore"; };
        pull = { rebase = "true"; };
        user = { signingkey = "84B6049F3398724F3300230C9A98F924E51C73A8"; };
        commit = { gpgsign = "true"; };
      };
    };
  };
}

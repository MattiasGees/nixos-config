#
# Git
#

{
  programs = {
    git = {
      enable = true;
      settings = {
        core = { askpass = "/opt/homebrew/bin/ssh-askpass"; excludesFile = "~/.config/global-gitignore"; };
        pull = { rebase = "true"; };
        user = {
          name = "Mattias Gees";
          email = "mattias@gees.dev";
          signingkey = "84B6049F3398724F3300230C9A98F924E51C73A8";
        };
        commit = { gpgsign = "true"; };
      };
    };
  };
}

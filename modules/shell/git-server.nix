# Git config for servers without GUI dependencies
{
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Mattias Gees";
        email = "mattias@gees.dev";
        # Signing (add on a server if needed):
        # signingkey = "84B6049F3398724F3300230C9A98F924E51C73A8";
      };
      core.excludesFile = "~/.config/global-gitignore";
      pull.rebase = "true";
      # commit.gpgsign = true;
    };
  };
}

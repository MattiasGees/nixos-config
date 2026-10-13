{ pkgs, ... }:
with pkgs;

let
  # atuin 18.23.0's bash-preexec e2e PTY tests fail in the Darwin build sandbox
  # ("bash: atuin: command not found"); the zsh/fish/ble.sh variants pass, as
  # does everything on Linux, where Hydra caches the build. Drop this override
  # once nixpkgs' atuin builds on macOS again.
  atuinPkg =
    if stdenv.hostPlatform.isDarwin then
      atuin.overrideAttrs (old: {
        checkFlags = old.checkFlags ++ [
          "--skip=filtered_commands_leave_no_captured_output"
          "--skip=bash_preexec"
        ];
      })
    else
      atuin;
in
{

  home = {
    packages = with pkgs; [
      # Terminal
      yq coreutils-full fzf ripgrep bat colordiff htop tree wget diceware
      keychain watch jq starship git gnumake gawk fastfetch
      glow step-ca openssl asciinema asciinema-agg objconv atuinPkg mosh
    ]
    # gcc is Linux-only: on macOS the Nix gcc/ld land ahead of Apple's
    # toolchain on PATH and break native compiles (SbarLua, sketchybar's C
    # event providers) because GNU gcc drives the Nix ld, which cannot parse
    # the macOS SDK's .tbd stubs. Apple's clang (/usr/bin) is used instead.
    ++ lib.optionals stdenv.hostPlatform.isLinux [ gcc ];
  };
  
}

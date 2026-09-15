{ pkgs, ... }:
with pkgs;

{

  home = {
    packages = with pkgs; [
      # Terminal
      yq coreutils-full fzf ripgrep bat colordiff htop tree wget diceware
      keychain watch jq starship git gnumake gawk tmate fastfetch
      glow step-ca openssl asciinema asciinema-agg objconv atuin mosh
    ]
    # gcc is Linux-only: on macOS the Nix gcc/ld land ahead of Apple's
    # toolchain on PATH and break native compiles (SbarLua, sketchybar's C
    # event providers) because GNU gcc drives the Nix ld, which cannot parse
    # the macOS SDK's .tbd stubs. Apple's clang (/usr/bin) is used instead.
    ++ lib.optionals stdenv.isLinux [ gcc ];
  };
  
}

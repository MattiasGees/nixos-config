{ pkgs, ... }:
with pkgs;

{

  home = {
    packages = with pkgs; [
      # Terminal
      yq coreutils-full fzf ripgrep bat colordiff htop tree wget diceware
      keychain watch jq starship git gnumake gawk fastfetch
      glow step-ca openssl asciinema asciinema-agg objconv mosh
      # TEMP: atuin 18.23.0's e2e tests read nix-darwin's /etc/bashrc in
      # unsandboxed darwin builds and time out. The harness clears the env, so
      # NOSYSBASHRC goes through a wrapper that must be named bash. Mirrors
      # upstream nixpkgs 34f4a531e8 (NixOS/nixpkgs#574509); drop once
      # nixos-unstable has it.
      (if stdenv.hostPlatform.isDarwin
       then atuin.overrideAttrs { env.ATUIN_E2E_BASH = lib.getExe (writeShellScriptBin "bash" ''
         NOSYSBASHRC=1 exec ${lib.getExe bashInteractive} "$@"
       ''); }
       else atuin)
    ]
    # gcc is Linux-only: on macOS the Nix gcc/ld land ahead of Apple's
    # toolchain on PATH and break native compiles (SbarLua, sketchybar's C
    # event providers) because GNU gcc drives the Nix ld, which cannot parse
    # the macOS SDK's .tbd stubs. Apple's clang (/usr/bin) is used instead.
    ++ lib.optionals stdenv.hostPlatform.isLinux [ gcc ];
  };
  
}

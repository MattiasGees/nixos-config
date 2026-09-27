{ pkgs, lib, ... }:
with pkgs;

{
  home = {
    packages = with pkgs; [
      # Command-line tools (cross-platform)
      git-crypt cargo yarn protobuf docker goreleaser vulnix hugo
      go_1_26 python3 niv golangci-lint gh protoc-gen-go
      gnused grpcurl uv terraform yubikey-agent

      # Occasionally needed for Java builds (not a day-to-day toolchain)
      openjdk maven
    ] ++ lib.optionals (!pkgs.stdenv.hostPlatform.isDarwin) [
      # vibes -- on Darwin claude-code comes from the Homebrew cask (nixpkgs
      # lags behind); Linux hosts have no Homebrew, so keep the nixpkgs build.
      claude-code
    ];
  };
}

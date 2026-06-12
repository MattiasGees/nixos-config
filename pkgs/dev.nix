{ pkgs, ... }:
with pkgs;

{
  home = {
    packages = with pkgs; [
      # Command-line tools (cross-platform)
      git-crypt cargo yarn protobuf docker goreleaser vulnix hugo
      go_1_24 python3 niv golangci-lint gh protoc-gen-go

      ## Tools that I have needed to install in weird circumstances. I don't actually write
      ## hehehe
      openjdk maven

      # vibes
      gemini-cli claude-code
    ];
  };
}

# macOS-specific packages
{ pkgs, ... }:

{
  home = {
    packages = with pkgs; [
      colima
      lima
      docker-buildx
      docker-compose
    ];

    # The docker CLI (from pkgs/dev.nix) doesn't search the Nix profile for
    # plugins, so expose buildx/compose as CLI plugins so `docker buildx` /
    # `docker compose` resolve.
    file.".docker/cli-plugins/docker-buildx".source = "${pkgs.docker-buildx}/bin/docker-buildx";
    file.".docker/cli-plugins/docker-compose".source = "${pkgs.docker-compose}/bin/docker-compose";
  };
}

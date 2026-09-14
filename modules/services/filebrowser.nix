# Filebrowser Quantum — web file manager, fronted by Caddy at
# files.polaris.mattiasgees.be. Runs as a Docker container (not in nixpkgs).
{ lib, ... }:
{
  opSecrets.filebrowser-config = {
    template = ./filebrowser.config.yaml.tpl;
    path = "/var/lib/secrets/filebrowser-config.yaml";
    # Container runs as UID 1000, which maps to mattias:users on polaris.
    owner = "mattias";
    group = "users";
  };

  # mkDefault so this coexists with pihole.nix, which also sets the backend.
  virtualisation.oci-containers.backend = lib.mkDefault "docker";

  virtualisation.oci-containers.containers.filebrowser = {
    image = "gtstef/filebrowser:2.0.6-beta";
    ports = [ "127.0.0.1:8083:80" ];
    # Config as a sibling of the data-dir volume, not nested inside it: runc
    # can't create a file mountpoint inside another bind mount's empty volume.
    environment.FILEBROWSER_CONFIG = "/home/filebrowser/config.yaml";
    volumes = [
      # Sources, bind-mounted at the same paths they carry in the config template.
      "/srv/media:/srv/media:ro"
      "/srv/data/files:/srv/data/files"
      "/var/lib/filebrowser:/home/filebrowser/data"
      "/var/lib/secrets/filebrowser-config.yaml:/home/filebrowser/config.yaml:ro"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /srv/data/files 0755 mattias users - -"
    "d /var/lib/filebrowser 0700 mattias users - -"
  ];
}

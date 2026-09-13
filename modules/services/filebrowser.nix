# Filebrowser Quantum (gtsteffaniak/filebrowser) — a simple, nice-looking web
# file manager for polaris: log in, upload/download and organise files under a
# specific folder (/srv/files), e.g. camera RAWs. Chosen over Nextcloud/ownCloud
# (too heavy), Copyparty (dated UI) and Caby (v0.1.0) — it's the actively
# maintained successor to the archived filebrowser/filebrowser, with a modern UI
# (grid/list, photo thumbnails) and native per-folder scoping.
#
# Not packaged in nixpkgs, so it runs as a container via virtualisation.oci-
# containers on the Docker backend (same pattern as pihole.nix). Single container.
#
# Image runs as the non-root `filebrowser` user, UID 1000 — which on polaris maps
# to `mattias:users`. So the data dir, the managed files and the rendered config
# are all owned by mattias(1000) so that UID can read/write them. The image's
# FILEBROWSER_CONFIG / FILEBROWSER_DATABASE_PATH default to /home/filebrowser/data/
# {config.yaml,database.sqlite}; we bind /var/lib/filebrowser there for the DB and
# bind the op-secrets-rendered config read-only on top.
#
# Ingress is Caddy only (files.polaris.mattiasgees.be -> localhost:8083, wired in
# caddy.nix); the port binds to loopback and no firewall port is opened. LAN /
# tailnet reachable via the *.polaris wildcard, not exposed publicly.
#
# Auth: a single local `admin` account. Its initial password is rendered from
# op://polaris/filebrowser/admin-password by op-secrets; log in over Tailscale to
# use it (see auth.adminPassword note in the config template).
{ lib, ... }:
{
  opSecrets.filebrowser-config = {
    template = ./filebrowser.config.yaml.tpl;
    path = "/var/lib/secrets/filebrowser-config.yaml";
    # UID 1000 (container's filebrowser user) == mattias on polaris, so the
    # container can read this bind-mounted config.
    owner = "mattias";
    group = "users";
  };

  # Docker, not the NixOS-default podman — matches virtualisation.docker.enable in
  # modules/server/virtualisation.nix. pihole.nix sets this too; mkDefault lets
  # both modules coexist without a conflicting-definition error.
  virtualisation.oci-containers.backend = lib.mkDefault "docker";

  virtualisation.oci-containers.containers.filebrowser = {
    image = "gtstef/filebrowser:2.0.6-beta";
    # Loopback-only publish; Caddy fronts it for TLS on the LAN/tailnet.
    ports = [ "127.0.0.1:8083:80" ];
    volumes = [
      # Files the app manages (host /srv/files -> container /srv, matches the
      # single `sources` entry in the config template).
      "/srv/files:/srv"
      # Persistent state (database.sqlite lives here per FILEBROWSER_DATABASE_PATH).
      "/var/lib/filebrowser:/home/filebrowser/data"
      # Rendered config, mounted read-only on top of the data dir.
      "/var/lib/secrets/filebrowser-config.yaml:/home/filebrowser/data/config.yaml:ro"
    ];
  };

  # Bind-mount sources, owned by UID 1000 (mattias) so the non-root container can
  # write them. Declared here (not left to Docker auto-create) to stay in-repo and
  # reproducible — same pattern as plex.nix/immich.nix/pihole.nix.
  systemd.tmpfiles.rules = [
    "d /srv/files 0755 mattias users - -"
    "d /var/lib/filebrowser 0700 mattias users - -"
  ];
}

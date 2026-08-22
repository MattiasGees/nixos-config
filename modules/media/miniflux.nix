# Miniflux (self-hosted RSS reader) — second tenant of the shared PostgreSQL
# from modules/server/postgresql.nix, migrated off the Hetzner k8s cluster.
#
# `createDatabaseLocally = true` (default) makes the module add the `miniflux`
# role + DB to the existing pg18 cluster via services.postgresql.ensure*, and
# connect over the unix socket (/run/postgresql, peer auth, no password) — the
# same tenant pattern as immich.nix. Nothing is added to postgresql.nix.
#
# Ingress is Caddy only (miniflux.polaris.mattiasgees.be -> localhost:8080, wired
# in caddy.nix); LISTEN_ADDR stays on localhost and no firewall port is opened.
#
# Secret: `adminCredentialsFile` is an EnvironmentFile with ADMIN_USERNAME and
# ADMIN_PASSWORD. After the data migration the `miniflux` admin already exists
# in the restored DB, so CREATE_ADMIN is a no-op; the file is the module's
# requirement and a break-glass admin.
#
# The file is rendered from op://polaris/miniflux/* by op-secrets.
{ ... }:
{
  opSecrets.miniflux-admin = {
    template = ./miniflux.admin.env.tpl;
    path = "/var/lib/secrets/miniflux-admin.env";
    owner = "miniflux";
  };

  services.miniflux = {
    enable = true;
    adminCredentialsFile = "/var/lib/secrets/miniflux-admin.env";
    config = {
      LISTEN_ADDR = "localhost:8080";
      BASE_URL = "https://miniflux.polaris.mattiasgees.be";
    };
  };
}

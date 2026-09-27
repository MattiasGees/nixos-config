# Miniflux (RSS reader) — a tenant of the shared PostgreSQL (postgresql.nix),
# migrated off the Hetzner k8s cluster (migrate-miniflux.sh). The default
# createDatabaseLocally adds the `miniflux` role/DB via ensure* and connects
# over the unix socket with peer auth. Localhost only; Caddy is the ingress.
#
# adminCredentialsFile (ADMIN_USERNAME/ADMIN_PASSWORD, rendered by op-secrets)
# is required by the module; since the admin already exists in the migrated
# DB, CREATE_ADMIN is a no-op and the file is just a break-glass credential.
{ ... }:
{
  opSecrets.miniflux-admin = {
    template = ./miniflux.admin.env.tpl;
    path = "/var/lib/secrets/miniflux-admin.env";
    owner = "root";
  };

  services.miniflux = {
    enable = true;
    adminCredentialsFile = "/var/lib/secrets/miniflux-admin.env";
    config = {
      LISTEN_ADDR = "localhost:8080";
      BASE_URL = "https://miniflux.polaris.mattiasgees.be";
      # Karakeep (karakeep.polaris.mattiasgees.be) resolves to a private LAN IP.
      # Since Miniflux 2.2.18, third-party integrations to private networks are
      # blocked by default (SSRF protection), so the Karakeep integration fails
      # with "connection to private network is blocked". Opt back in for it.
      INTEGRATION_ALLOW_PRIVATE_NETWORKS = "1";
    };
  };
}

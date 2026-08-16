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
# ADMIN_PASSWORD, hand-placed at /etc/miniflux/admin.env (0600, out of git) —
# same out-of-band pattern as caddy's route53.env. After the data migration the
# `miniflux` admin already exists in the restored DB, so CREATE_ADMIN is a no-op;
# the file is the module's requirement and a break-glass admin. Place it with:
#
#   PW=$(kubectl get secret miniflux-secrets -n miniflux \
#         -o jsonpath='{.data.minifluxPassword}' | base64 -d)
#   sudo install -d -m 0755 /etc/miniflux
#   printf 'ADMIN_USERNAME=miniflux\nADMIN_PASSWORD=%s\n' "$PW" \
#     | sudo install -m 0600 /dev/stdin /etc/miniflux/admin.env
#
# (Moving this secret into sops-nix is a queued follow-up.)
{ ... }:
{
  services.miniflux = {
    enable = true;
    adminCredentialsFile = "/etc/miniflux/admin.env";
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

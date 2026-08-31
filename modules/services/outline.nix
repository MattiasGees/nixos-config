# Outline (self-hosted team wiki / knowledge base), migrated off the Hetzner
# Kubernetes cluster. Design archived in the Homecluster/NixOS wiki (Specs); the
# bootstrap/operator steps (1Password `outline` item, public route) live in the
# Outline service doc (Homecluster/NixOS wiki → Documentation). setup.md carries
# only the op-secrets vault verification refs.
#
# Third tenant of the shared PostgreSQL from modules/server/postgresql.nix (after
# immich + miniflux). `databaseUrl = "local"` makes the upstream module add the
# `outline` role + DB to the pg18 cluster via services.postgresql.ensure* and
# connect over the unix socket (/run/postgresql, peer auth, no password) — the
# same tenant pattern as immich/miniflux, nothing added to postgresql.nix.
#
# pgvector is layered onto the shared cluster here via
# `services.postgresql.extensions` (Immich is the precedent). That option is a
# `functionTo (listOf path)`, which the module system *merges*: immich.nix's
# upstream module already contributes `[ pgvector vectorchord ]`, this adds
# `[ pgvector ]`, and the merged list is fed to `postgresql.withPackages`. The
# duplicate pgvector is harmless — withPackages is a buildEnv and identical store
# paths symlink to the same target (no collision). So this stays a single,
# coherent definition without touching immich or postgresql.nix.
#
# `redisUrl = "local"` brings up a **dedicated** Redis (Valkey) on its own unix
# socket (TCP disabled), the same per-app Redis tradeoff immich makes — the
# BullMQ queue/cache state in it is ephemeral and needs no backups.
#
# Storage: local filesystem (no S3). Attachments/avatars are irreplaceable, so
# they live on the **fast** pool (mirrored, encrypted NVMe) at
# /srv/fast/appdata/outline — a plain subdir of the existing fast/appdata dataset
# (same as the *arr apps / karakeep), created by tmpfiles and bind-mounted onto
# /var/lib/outline. The module hardcodes /var/lib/outline as its StateDirectory
# and puts FILE_STORAGE_LOCAL_ROOT_DIR at /var/lib/outline/data, so — exactly like
# karakeep — we back that path with a bind mount instead of repointing it. Because
# the bind mount comes up *after* systemd-tmpfiles-setup (the module's own
# `d /var/lib/outline/data` rule would otherwise land on the empty root-disk dir,
# shadowed by the mount), we also create the data/ subdir on the fast pool so it
# survives on the mounted source. /srv/fast/appdata is swept offsite by
# modules/server/restic.nix, so no per-app restic path is needed; the pg data
# itself is captured by the cluster-wide pg_dumpall in postgresql.nix.
#
# Secrets: SECRET_KEY, UTILS_SECRET, the OIDC + Google client secrets and the SES
# SMTP password are rendered from op://polaris/outline/* by op-secrets to flat
# files under /var/lib/secrets, owned by the `outline` service user. The module
# reads each with `head -n1` (trailing newline stripped, so the .tpl newline is
# harmless) and — crucially — only *generates* SECRET_KEY/UTILS_SECRET when the
# file is empty (`[ ! -s ]` in preStart). Those two are carried VERBATIM from the
# old AWS Secrets Manager `outline` secret: they key the at-rest encryption and
# signed cookies, so regenerating them corrupts every migrated document. op-secrets
# renders the real values before first start, so the preStart no-ops.
#
# Ingress: TLS is terminated upstream. Caddy fronts wiki.polaris.mattiasgees.be on
# the tailnet (caddy.nix), proxying plain HTTP to localhost:3002 (3000/3001 are
# taken by karakeep/open-webui), so `forceHttps = false` (the module would
# otherwise 301-loop behind the proxy). The public https://wiki.gees.dev endpoint
# is a one-line follow-up on the shared polaris Cloudflare tunnel
# (modules/server/cloudflared.nix), landed separately.
{ ... }:
{
  opSecrets.outline-secret-key = {
    template = ./outline-secret-key.tpl;
    path = "/var/lib/secrets/outline-secret-key";
    owner = "outline";
  };
  opSecrets.outline-utils-secret = {
    template = ./outline-utils-secret.tpl;
    path = "/var/lib/secrets/outline-utils-secret";
    owner = "outline";
  };
  opSecrets.outline-oidc-secret = {
    template = ./outline-oidc-secret.tpl;
    path = "/var/lib/secrets/outline-oidc-secret";
    owner = "outline";
  };
  opSecrets.outline-google-secret = {
    template = ./outline-google-secret.tpl;
    path = "/var/lib/secrets/outline-google-secret";
    owner = "outline";
  };
  opSecrets.outline-smtp-password = {
    template = ./outline-smtp-password.tpl;
    path = "/var/lib/secrets/outline-smtp-password";
    owner = "outline";
  };

  services.outline = {
    enable = true;
    publicUrl = "https://wiki.gees.dev";
    # 3002, not 3000 — karakeep already binds 0.0.0.0:3000 (and open-webui 3001).
    port = 3002;
    # TLS terminated upstream (Cloudflare tunnel + Caddy); don't 301-loop.
    forceHttps = false;
    # Shared pg18 tenant + dedicated local Redis (see header).
    databaseUrl = "local";
    redisUrl = "local";
    enableUpdateCheck = false;

    storage = {
      storageType = "local";
      localRootDir = "/var/lib/outline/data";
      uploadMaxSize = 262144000; # 250 MiB
    };

    # SECRET_KEY / UTILS_SECRET carried VERBATIM from the old deployment — see the
    # header. Rendered by op-secrets; the module only regenerates when empty.
    secretKeyFile = "/var/lib/secrets/outline-secret-key";
    utilsSecretFile = "/var/lib/secrets/outline-utils-secret";

    # Generic OIDC against the self-hosted IdP (login.gees.dev). clientId is a
    # public identifier; the secret is rendered by op-secrets.
    oidcAuthentication = {
      clientId = "outline";
      clientSecretFile = "/var/lib/secrets/outline-oidc-secret";
      authUrl = "https://login.gees.dev/auth";
      tokenUrl = "https://login.gees.dev/token";
      userinfoUrl = "https://login.gees.dev/userinfo";
    };

    # Google OAuth. The client *id* is a public OAuth identifier (not a secret),
    # so it lives inline here; the paired secret is rendered by op-secrets.
    googleAuthentication = {
      clientId = "903008356341-icmiuqd9na7eusr0b08e173cl3afct1a.apps.googleusercontent.com";
      clientSecretFile = "/var/lib/secrets/outline-google-secret";
    };

    # Transactional email via Amazon SES SMTP. The SES SMTP *username* is not a
    # secret but is account-specific, so it lives inline here; the password is
    # rendered by op-secrets. replyEmail has no module default and is read
    # unconditionally when smtp is set, so it must be provided.
    smtp = {
      host = "email-smtp.eu-west-1.amazonaws.com";
      port = 465;
      secure = true;
      username = "AKIAVAZUDRQP5443B6JK";
      passwordFile = "/var/lib/secrets/outline-smtp-password";
      fromEmail = "mattias@gees.dev";
      replyEmail = "mattias@gees.dev";
    };
  };

  # pgvector onto the shared pg18 cluster. Mergeable with immich's definition —
  # see the header. This only makes the extension *available* in the package; the
  # `outline` DB's own CREATE EXTENSION comes across with the restored dump.
  services.postgresql.extensions = ps: [ ps.pgvector ];

  # Fast-pool storage, bind-mounted onto the module's hardcoded /var/lib/outline
  # (karakeep pattern — read modules/media/karakeep.nix for the full rationale).
  # No dedicated dataset: plain subdirs of the existing fast/appdata dataset,
  # owned by the outline user. We create data/ too: the bind mount comes up after
  # systemd-tmpfiles-setup, so the module's own `d /var/lib/outline/data` rule
  # would land on the (shadowed) root-disk dir — creating it on the source here
  # guarantees FILE_STORAGE_LOCAL_ROOT_DIR exists on the mounted fast pool. Modes
  # mirror the module: 0750 parent (StateDirectoryMode), 0700 data.
  systemd.tmpfiles.rules = [
    "d /srv/fast/appdata/outline      0750 outline outline - -"
    "d /srv/fast/appdata/outline/data 0700 outline outline - -"
  ];

  # Hand-rolled bind mount (not a fileSystems entry) so it can be ordered After
  # systemd-tmpfiles-setup — a fileSystems bind mounts at local-fs.target and
  # would race tmpfiles, binding an empty dir. See karakeep.nix.
  systemd.mounts = [{
    what = "/srv/fast/appdata/outline";
    where = "/var/lib/outline";
    type = "none";
    options = "bind";
    requires = [ "systemd-tmpfiles-setup.service" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    wantedBy = [ "multi-user.target" ];
  }];

  # Never let outline start (and write to the empty underlying /var/lib/outline on
  # the root disk) before the bind mount is up.
  systemd.services.outline.unitConfig.RequiresMountsFor = "/var/lib/outline";
}

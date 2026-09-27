# Outline (team wiki), migrated off the Hetzner k8s cluster. Design archived
# in the Homecluster/NixOS wiki (Specs); bootstrap/operator steps (1Password
# `outline` item, public route) in the Outline service doc there.
#
# Postgres: `databaseUrl = "local"` adds the `outline` role/DB to the shared
# cluster (postgresql.nix) via ensure* and connects over the unix socket with
# peer auth; the cluster pg_dumpall backs it up.
#
# Redis: `redisUrl = "local"` is a dedicated Valkey on a unix socket — same
# per-app tradeoff as immich.nix; its state is ephemeral.
#
# Storage: local filesystem (no S3). Attachments are irreplaceable, so they
# live on the fast pool at /srv/fast/appdata/outline, bind-mounted onto the
# module's hardcoded /var/lib/outline (karakeep.nix pattern; swept by restic).
#
# Secrets: rendered by op-secrets from op://polaris/outline/*, owned by the
# `outline` user (hence op-secrets' 0711 dir mode). The module reads each with
# `head -n1` (so the .tpl's trailing newline is harmless) and only *generates*
# SECRET_KEY/UTILS_SECRET when the file is empty — op-secrets renders them
# before first start, so that never fires. Those two are carried VERBATIM from
# the old AWS Secrets Manager `outline` secret: they key at-rest encryption and
# signed cookies, so regenerating them corrupts every migrated document.
#
# Ingress: TLS terminates upstream — Caddy on the tailnet
# (wiki.polaris.mattiasgees.be) and the Cloudflare tunnel publicly
# (wiki.gees.dev, cloudflared.nix) — both proxy plain HTTP to :3002, hence
# forceHttps = false (it would 301-loop).
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

    # Carried VERBATIM from the old deployment — never regenerate (see header).
    secretKeyFile = "/var/lib/secrets/outline-secret-key";
    utilsSecretFile = "/var/lib/secrets/outline-utils-secret";

    # Generic OIDC against the self-hosted IdP (login.gees.dev).
    oidcAuthentication = {
      clientId = "outline";
      clientSecretFile = "/var/lib/secrets/outline-oidc-secret";
      authUrl = "https://login.gees.dev/auth";
      tokenUrl = "https://login.gees.dev/token";
      userinfoUrl = "https://login.gees.dev/userinfo";
    };

    # Client IDs (here and above) are public identifiers, not secrets.
    googleAuthentication = {
      clientId = "903008356341-icmiuqd9na7eusr0b08e173cl3afct1a.apps.googleusercontent.com";
      clientSecretFile = "/var/lib/secrets/outline-google-secret";
    };

    # Amazon SES SMTP. The username isn't a secret (the password is).
    # replyEmail has no module default but is read whenever smtp is set.
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

  # Makes pgvector *available* in the shared cluster's package; the `outline`
  # DB's CREATE EXTENSION came with the restored dump. The option merges with
  # immich's `[ pgvector vectorchord ]` into one withPackages buildEnv, where
  # the duplicate pgvector is harmless (identical store paths).
  services.postgresql.extensions = ps: [ ps.pgvector ];

  # data/ is created on the source too: the bind mount comes up after
  # tmpfiles-setup, so the module's own `d /var/lib/outline/data` rule lands on
  # the shadowed root-disk dir. Modes mirror the module (StateDirectoryMode
  # 0750, data 0700).
  systemd.tmpfiles.rules = [
    "d /srv/fast/appdata/outline      0750 outline outline - -"
    "d /srv/fast/appdata/outline/data 0700 outline outline - -"
  ];

  # Hand-rolled bind mount, ordered after tmpfiles-setup — see karakeep.nix.
  systemd.mounts = [{
    what = "/srv/fast/appdata/outline";
    where = "/var/lib/outline";
    type = "none";
    options = "bind";
    # Same ordering-cycle fix as karakeep.nix: without DefaultDependencies=no
    # systemd drops the mount at boot and outline never starts.
    unitConfig.DefaultDependencies = false;
    requires = [ "systemd-tmpfiles-setup.service" ];
    after = [ "systemd-tmpfiles-setup.service" ];
    before = [ "umount.target" ];
    conflicts = [ "umount.target" ];
    wantedBy = [ "multi-user.target" ];
  }];

  # Never let outline start (and write to the empty underlying /var/lib/outline on
  # the root disk) before the bind mount is up.
  systemd.services.outline.unitConfig.RequiresMountsFor = "/var/lib/outline";
}

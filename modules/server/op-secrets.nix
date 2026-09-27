# op-secrets — render 1Password-backed secrets onto the host at deploy time.
#
# Each service declares `opSecrets.<name>` with a git-committed `.tpl` template
# (plain text around `{{ op://vault/item/field }}` references) and an output
# path under /var/lib/secrets. A single service-account token at /etc/op/token
# unlocks 1Password; `op inject` renders each template on every switch and at
# boot. Rendering is atomic (temp + mv) and last-good-preserving: any failure
# (no token, 1P unreachable, timeout, bad reference) warns and leaves the
# existing file untouched, so a deploy or boot never blocks on 1Password.
#
# Chosen over sops-nix/agenix: no ciphertext in git, rotate in 1Password with no
# commit, no age/host keys. Design archived in the Homecluster/NixOS wiki (Specs);
# operator steps live in docs/polaris/setup.md (op-secrets section).
{ pkgs, lib, config, ... }:
let
  cfg = config.opSecrets;
  op = "${pkgs._1password-cli}/bin/op";
  secretsDir = "/var/lib/secrets";
  tokenFile = "/etc/op/token";

  renderOne = name: s: ''
    if tmp="$(${pkgs.coreutils}/bin/mktemp -p "$(${pkgs.coreutils}/bin/dirname ${lib.escapeShellArg s.path})")" \
       && ${pkgs.coreutils}/bin/timeout 15 ${op} inject --force -i ${s.template} -o "$tmp" </dev/null \
       && ${pkgs.coreutils}/bin/chown ${s.owner}:${s.group} "$tmp" \
       && ${pkgs.coreutils}/bin/chmod ${s.mode} "$tmp" \
       && ${pkgs.coreutils}/bin/mv -f "$tmp" ${lib.escapeShellArg s.path}; then
      echo "op-secrets: rendered ${name} -> ${s.path}"
    else
      echo "op-secrets: WARNING ${name} render failed; keeping last-good ${s.path}" >&2
      [ -n "''${tmp:-}" ] && ${pkgs.coreutils}/bin/rm -f "$tmp"
    fi
  '';
in
{
  options.opSecrets = lib.mkOption {
    description = "1Password-backed secrets rendered to files at deploy time.";
    default = { };
    type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
      options = {
        template = lib.mkOption {
          type = lib.types.path;
          description = "Path to a .env.tpl containing only {{ op://... }} references.";
        };
        path = lib.mkOption {
          type = lib.types.str;
          description = "Absolute output path (must live under ${secretsDir}).";
        };
        owner = lib.mkOption {
          type = lib.types.str;
          description = "Owner of the rendered file (the consuming service's user).";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = config.owner;
          description = "Group of the rendered file (defaults to owner).";
        };
        mode = lib.mkOption {
          type = lib.types.str;
          default = "0600";
          description = "Mode of the rendered file.";
        };
      };
    }));
  };

  config = {
    assertions = lib.mapAttrsToList (name: s: {
      assertion = lib.hasPrefix "${secretsDir}/" s.path;
      message = "opSecrets.${name}.path (${s.path}) must live under ${secretsDir}/.";
    }) cfg;

    environment.systemPackages = [ pkgs._1password-cli ];

    # deps = [ "users" ] so file owners exist before the chown. The dir is
    # created here, not via tmpfiles, to avoid activation-ordering races on a
    # fresh switch.
    #
    # Mode 0711, not 0700: most consumers read secrets via systemd
    # (EnvironmentFile / LoadCredential) as root, but Outline reads its files
    # directly as the unprivileged `outline` user, so it needs traverse (o+x).
    # No o+r means no listing, and the files themselves stay 0600.
    system.activationScripts.opSecrets = {
      deps = [ "users" ];
      text = ''
        ${pkgs.coreutils}/bin/install -d -m 0711 -o root -g root ${secretsDir}
        if [ ! -r ${tokenFile} ]; then
          echo "op-secrets: no token at ${tokenFile}; skipping (services use last-good if present)" >&2
        else
          export OP_SERVICE_ACCOUNT_TOKEN="$(${pkgs.coreutils}/bin/cat ${tokenFile})"
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList renderOne cfg)}
        fi
      '';
    };
  };
}

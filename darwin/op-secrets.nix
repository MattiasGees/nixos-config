# op-secrets (darwin) — render 1Password-backed secrets onto this Mac at
# activation time. Mirrors modules/server/op-secrets.nix (polaris): the same
# `opSecrets.<name>` option schema, git-committed `.tpl` templates holding only
# `{{ op://vault/item/field }}` references, one service-account token at
# /etc/op/token (root 0600, dir 0700), `op inject` with a 15 s timeout, and an
# atomic, last-good-preserving write: any failure (no token, 1Password
# unreachable, timeout, bad reference) warns and leaves the existing file alone,
# so a switch never blocks on 1Password.
#
# Rotation = change the value in 1Password + `make switch`.
#
# Deliberate differences from the polaris module:
#  - Hook: nix-darwin only runs its FIXED activation hooks; a custom-named
#    system.activationScripts.<name> is silently never executed. Renders
#    therefore live in postActivation, mkBefore'd so the files exist before
#    other postActivation steps (home-manager, mkAfter consumers). Users and
#    groups are created earlier in activation, so the owners exist.
#  - Paths: any absolute path (asserted), not just /var/lib/secrets. A missing
#    parent directory is created 0700 <owner>:<group> (any missing ancestors
#    above it are created by the owner too, with install's default 0755); an
#    existing directory is never re-moded or re-owned.
#  - Writes happen AS THE OWNER. On darwin the targets typically sit in a
#    user's own home (which that user controls), so a root write there would
#    follow any symlink the user planted. `op inject` still runs as root (only
#    root can read the token) into a root-only 0700 scratch dir,
#    /var/db/op-secrets (not /tmp; emptied with `find -mindepth 1 -delete` at
#    the start of every run, token or not); the rendered bytes are
#    then streamed on stdin to a small helper run via `sudo -u <owner>` that
#    does install -d/mktemp/chown/chmod/mv. A render can therefore never give the
#    owner a file anywhere they couldn't already write. (owner = "root" skips
#    the sudo.)
#  - op binary: ${pkgs._1password-cli} by store path, NOT added to
#    environment.systemPackages (Homebrew provides `op` for interactive use).
#  - The token is handed to `op` alone (command-prefix env), not exported into
#    the rest of activation.
#  - Empty config (opSecrets == { }) emits nothing at all.
{ pkgs, lib, config, ... }:
let
  cfg = config.opSecrets;
  op = "${pkgs._1password-cli}/bin/op";
  tokenFile = "/etc/op/token";
  cu = "${pkgs.coreutils}/bin";
  findutils = pkgs.findutils;
  # Root-only scratch for `op inject` output (plaintext, briefly) — a fixed dir
  # under /var/db, not /tmp, emptied (hidden files too) at the start of every
  # run, even without a token, and again at the end.
  scratchDir = "/var/db/op-secrets";

  # Runs as the file's owner. Usage: place <dest> <mode> <owner> <group>, with
  # the rendered content on stdin.
  place = pkgs.writeShellScript "op-secrets-place" ''
    set -eu
    umask 077
    dest=$1 mode=$2 owner=$3 group=$4
    dir=$(${cu}/dirname "$dest")
    if [ ! -d "$dir" ]; then
      ${cu}/install -d -m 0700 -o "$owner" -g "$group" "$dir"
    fi
    tmp=$(${cu}/mktemp "$dir/.op-secrets.XXXXXX")
    trap '${cu}/rm -f "$tmp"' EXIT
    ${cu}/cat > "$tmp"
    ${cu}/chown "$owner:$group" "$tmp"
    ${cu}/chmod "$mode" "$tmp"
    ${cu}/mv -fT "$tmp" "$dest"
    trap - EXIT
  '';

  renderOne = name: s:
    let
      rendered = "${scratchDir}/${lib.escapeShellArg name}";
      asOwner = lib.optionalString (s.owner != "root") "/usr/bin/sudo -u ${lib.escapeShellArg s.owner} ";
    in
    ''
      if OP_SERVICE_ACCOUNT_TOKEN="$opSecretsToken" ${cu}/timeout 15 ${op} inject --force -i ${s.template} -o ${rendered} </dev/null \
         && ${cu}/cat ${rendered} | ${asOwner}${place} ${lib.escapeShellArg s.path} ${lib.escapeShellArg s.mode} ${lib.escapeShellArg s.owner} ${lib.escapeShellArg s.group}; then
        echo "op-secrets: rendered ${name} -> ${s.path}"
      else
        echo "op-secrets: WARNING ${name} render failed; keeping last-good ${s.path}" >&2
      fi
      ${cu}/rm -f ${rendered}
    '';
in
{
  options.opSecrets = lib.mkOption {
    description = "1Password-backed secrets rendered to files at activation (make switch).";
    default = { };
    type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
      options = {
        template = lib.mkOption {
          type = lib.types.path;
          description = "Path to a .tpl containing only {{ op://... }} references (plus literal structure).";
        };
        path = lib.mkOption {
          type = lib.types.str;
          description = "Absolute output path. Its parent must be creatable/writable by owner.";
        };
        owner = lib.mkOption {
          type = lib.types.str;
          description = "Owner of the rendered file (the consuming user); the file is written as this user.";
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

  config = lib.mkIf (cfg != { }) {
    assertions = lib.mapAttrsToList (name: s: {
      assertion = lib.hasPrefix "/" s.path;
      message = "opSecrets.${name}.path (${s.path}) must be an absolute path.";
    }) cfg;

    system.activationScripts.postActivation.text = lib.mkBefore ''
      # --- op-secrets (darwin/op-secrets.nix) ---
      # (activation runs under `set -e`: every fallible step below sits in an
      # if/&& so a 1Password problem can only ever warn.)
      # Always (re)assert the root 0700 scratch dir and empty it — hidden files
      # included — even when there's no token, so plaintext from an
      # interrupted run never lingers.
      opSecretsScratch=""
      if ${cu}/install -d -m 0700 -o root -g wheel ${scratchDir} \
         && ${findutils}/bin/find ${scratchDir} -mindepth 1 -delete; then
        opSecretsScratch=1
      fi
      if [ ! -r ${tokenFile} ]; then
        echo "op-secrets: no token at ${tokenFile}; skipping (consumers use last-good if present)" >&2
      elif [ -z "$opSecretsScratch" ] || ! opSecretsToken="$(${cu}/cat ${tokenFile})"; then
        echo "op-secrets: WARNING could not read ${tokenFile} or prepare ${scratchDir}; skipping all renders" >&2
      else
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList renderOne cfg)}
        ${findutils}/bin/find ${scratchDir} -mindepth 1 -delete || true
      fi
      unset opSecretsToken opSecretsScratch
    '';
  };
}

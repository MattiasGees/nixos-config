#
#  Paseo daemon binding for the physical MacBooks.
#
#  The paseo app (installed via the homebrew cask in darwin/configuration.nix)
#  bundles and auto-starts its own daemon, which reads ~/.paseo/config.json.
#  Paseo OWNS that file at runtime — paired devices, hostname allowlists, the
#  bcrypt auth password and provider API keys all accumulate there — so nix must
#  NOT manage it wholesale (it would clobber runtime state and leak secrets into
#  the world-readable nix store).
#
#  Instead, activation only touches the single daemon.listen field: it seeds the
#  file if absent and otherwise surgically rewrites daemon.listen, leaving
#  everything else alone. We bind to this Mac's Tailscale IP (resolved at
#  activation) so the daemon is reachable across the tailnet for direct
#  connections but invisible on untrusted networks — unlike a 0.0.0.0 bind.
#  Hosts that set paseo.listenOnTailscale = false are pinned to localhost
#  instead (actively rewritten, so a previous Tailscale bind is undone).
#
#  Adapted from ChaosInTheCRD/nixos-config darwin/guest-paseo.nix, dropping the
#  VM-guest NAT-PMP publishing (Tailscale reaches a physical Mac directly) and
#  the tailvisor.guest gate. The rewrite logic lives in a writeText script
#  rather than an inline heredoc: shell heredoc terminators do not survive
#  Nix's '' indentation stripping.
#
{ config, lib, pkgs, user, ... }:

let
  # Seed ~/.paseo/config.json if absent, else surgically set only daemon.listen.
  # Runs as the user (via sudo -u); creates ~/.paseo if needed. Skips silently
  # on an unparseable file so a user-corrupted config is never destroyed.
  setListen = pkgs.writeText "paseo-set-listen.py" ''
    import json, os, sys
    path, want = sys.argv[1], sys.argv[2]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        try:
            with open(path) as f:
                cfg = json.load(f)
        except (ValueError, OSError) as e:
            print("paseo: %s unreadable (%s); leaving it alone" % (path, e))
            sys.exit(0)
    else:
        cfg = {}
    daemon = cfg.setdefault("daemon", {})
    cur = daemon.get("listen", "")
    if cur != want:
        daemon["listen"] = want
        with open(path, "w") as f:
            json.dump(cfg, f, indent=2)
        print("paseo: set daemon.listen to %s (was %r)" % (want, cur))
  '';
in
{
  options.paseo.listenOnTailscale = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Bind the Paseo daemon to this Mac's Tailscale IP; when false, bind to localhost only.";
  };

  config.system.activationScripts.postActivation.text = lib.mkAfter (if config.paseo.listenOnTailscale then ''
    PASEO_CFG="/Users/${user}/.paseo/config.json"

    # Locate the tailscale CLI (installed via the cask, not nix).
    TS_BIN=""
    for c in /usr/local/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
      [ -x "$c" ] && TS_BIN="$c" && break
    done

    if [ -z "$TS_BIN" ]; then
      echo "paseo: tailscale CLI not found; leaving $PASEO_CFG alone"
    else
      TS_IP="$("$TS_BIN" ip -4 2>/dev/null | /usr/bin/head -n1)"
      if [ -z "$TS_IP" ]; then
        echo "paseo: could not resolve Tailscale IP; leaving $PASEO_CFG alone"
      else
        sudo -u ${user} ${pkgs.python3}/bin/python3 ${setListen} "$PASEO_CFG" "$TS_IP:6767"
      fi
    fi
  '' else ''
    sudo -u ${user} ${pkgs.python3}/bin/python3 ${setListen} "/Users/${user}/.paseo/config.json" "127.0.0.1:6767"
  '');
}

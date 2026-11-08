#
#  The read-only Paseo *investigation* agent — a SECOND, hidden macOS user that
#  runs its own Paseo daemon and drives Claude Code with a locked-down profile.
#  Enabled on macbook-m1 ONLY (see machines/macbook-m1.nix; pacesetter imports
#  macbook-m1 and force-disables it).
#
#  Design: an alert fires -> the self-hosted Paseo Hub dispatches an
#  investigation to this daemon -> it SSHes/queries the fleet read-only and, at
#  most, opens one PR per repo. It must never mutate a live system and never
#  push to a default branch. Enforcement here is defence-in-depth (a dedicated
#  unprivileged user, no admin home access, a scoped Claude settings file); the
#  hard guarantees come from the read-only logins (ansible/nixos PRs) and remote
#  branch protection.
#
#  Secrets never live in the Nix store (world-readable). The agent's SSH private
#  key, its env file (CLAUDE_CODE_OAUTH_TOKEN, GH_TOKEN), its kubeconfig and the
#  bot's git identity are rendered from the `paseo-agent` 1Password vault by
#  op-secrets (darwin/op-secrets.nix) at every `make switch`; the templates in
#  ./paseo-agent/*.tpl hold only op:// references. The Hub keys are NEVER
#  rendered here — only the `paseo-agent-setup` script (./paseo-agent/setup.sh)
#  reads them. Rotation = change the value in 1Password + `make switch`.
#
{ config, lib, pkgs, user, ... }:

let
  agentUser = "paseo-agent";
  agentHome = "/Users/${agentUser}";
  agentUid = 2001;
  agentGid = 2001;
  envFile = "${agentHome}/.paseo/env";
  paseoBin = "/Applications/Paseo.app/Contents/Resources/bin/paseo";

  # The launchd job: load the rendered env file (if present) into the
  # environment, then exec the daemon. With CLAUDE_CODE_OAUTH_TOKEN set, the
  # Claude processes it spawns use that token instead of the login Keychain.
  daemonWrapper = pkgs.writeShellScript "paseo-agent-daemon" ''
    set -a
    [ -r ${envFile} ] && . ${envFile}
    set +a
    exec ${paseoBin} daemon run --home ${agentHome}/.paseo
  '';

  # Interactive/one-off setup steps (1Password items, GitHub invites, Hub
  # enrollment, verification). Uses the Homebrew `op` on PATH, deliberately
  # not pkgs._1password-cli (signed binary with desktop-app unlock).
  setupScript = pkgs.writeShellApplication {
    name = "paseo-agent-setup";
    runtimeInputs = with pkgs; [
      gh jq kubectl awscli2 fluxcd openssh coreutils gnused curl prometheus-alertmanager
    ];
    text = builtins.readFile ./paseo-agent/setup.sh;
  };

  # Repos the agent works on, cloned into ~/ops at activation (see step 2b).
  agentRepos = [ "k8s-config" "nixos-config" "ansible" "infrastructure" ];

  # Seed ~/.paseo/config.json if absent, else surgically rewrite ONLY
  # daemon.listen — same approach and reasoning as darwin/paseo.nix (Paseo owns
  # that file at runtime; shell heredocs don't survive Nix '' indent stripping,
  # so the logic is a writeText python script run as the agent via sudo -u).
  setListen = pkgs.writeText "paseo-agent-set-listen.py" ''
    import json, os, sys
    path, want = sys.argv[1], sys.argv[2]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        try:
            with open(path) as f:
                cfg = json.load(f)
        except (ValueError, OSError) as e:
            print("paseo-agent: %s unreadable (%s); leaving it alone" % (path, e))
            sys.exit(0)
    else:
        cfg = {}
    daemon = cfg.setdefault("daemon", {})
    cur = daemon.get("listen", "")
    if cur != want:
        daemon["listen"] = want
        with open(path, "w") as f:
            json.dump(cfg, f, indent=2)
        print("paseo-agent: set daemon.listen to %s (was %r)" % (want, cur))
  '';
in
{
  options.paseoAgent.enable =
    lib.mkEnableOption "the read-only Paseo investigation agent user and daemon";

  config = lib.mkIf config.paseoAgent.enable {

    # --- 1. The dedicated user + group ---------------------------------------
    # nix-darwin only touches users/groups it is told it owns (knownUsers /
    # knownGroups) and needs fixed ids for them. programs.zsh.enable defaults
    # true on darwin, so shell = pkgs.zsh satisfies the shell-program check.
    users.knownGroups = [ agentUser ];
    users.groups.paseo-agent.gid = agentGid;

    users.knownUsers = [ agentUser ];
    users.users.paseo-agent = {
      uid = agentUid;
      gid = agentGid;
      home = agentHome;
      shell = pkgs.zsh;
      isHidden = true;
      createHome = true;
      description = "Paseo investigation agent (read-only)";
    };

    # --- 1b. The agent's credentials, rendered from 1Password ----------------
    # darwin/op-secrets.nix renders these (as the agent, from root-run
    # `op inject`) at the START of postActivation, before the steps below.
    # Needs /etc/op/token (`paseo-agent-setup init`); until then each switch
    # warns and keeps whatever was there.
    opSecrets = {
      paseo-agent-ssh = {
        template = ./paseo-agent/ssh-key.tpl;
        path = "${agentHome}/.ssh/id_ed25519";
        owner = agentUser;
      };
      paseo-agent-env = {
        template = ./paseo-agent/env.tpl;
        path = envFile;
        owner = agentUser;
      };
      paseo-agent-kubeconfig = {
        template = ./paseo-agent/kubeconfig.tpl;
        path = "${agentHome}/.kube/config";
        owner = agentUser;
      };
      paseo-agent-git-identity = {
        template = ./paseo-agent/git-identity.tpl;
        path = "${agentHome}/.config/git/identity";
        owner = agentUser;
      };
    };

    # The setup script — macbook-m1 only, because it lives inside this mkIf.
    environment.systemPackages = [ setupScript ];

    # --- 2. Lock the admin home + wire the agent's daemon --------------------
    # postActivation runs last (after user creation), as root. We: create the
    # agent's launchd log dir (launchd won't mkdir -p the parents), point its
    # Paseo daemon at this Mac's Tailscale IP on port 6768 (mattias's own daemon
    # owns 6767), restart the daemon if its rendered env changed, clone the
    # agent's repos, and finally chmod 700 the admin home so the agent can't
    # read mattias's kubeconfig / ssh keys.
    system.activationScripts.postActivation.text = lib.mkAfter ''
      # Agent-owned launchd log directory.
      sudo -u ${agentUser} /bin/mkdir -p "${agentHome}/Library/Logs"

      # Bind the agent's Paseo daemon to this Mac's Tailscale IP, port 6768.
      PASEO_AGENT_CFG="${agentHome}/.paseo/config.json"
      TS_BIN=""
      for c in /usr/local/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
        [ -x "$c" ] && TS_BIN="$c" && break
      done
      if [ -z "$TS_BIN" ]; then
        echo "paseo-agent: tailscale CLI not found; leaving $PASEO_AGENT_CFG alone"
      else
        TS_IP="$("$TS_BIN" ip -4 2>/dev/null | /usr/bin/head -n1)"
        if [ -z "$TS_IP" ]; then
          echo "paseo-agent: could not resolve Tailscale IP; leaving $PASEO_AGENT_CFG alone"
        else
          sudo -u ${agentUser} ${pkgs.python3}/bin/python3 ${setListen} "$PASEO_AGENT_CFG" "$TS_IP:6768"
        fi
      fi

      # Restart the agent daemon when its rendered env changed (first render or
      # a rotation): launchd (re)started it earlier in activation, before
      # op-secrets ran, and it only reads the env file at start. The file is
      # read as the agent (never by root through an agent-controlled path); the
      # last-seen checksum is kept root-only.
      PASEO_AGENT_ENV_SUM="$(sudo -u ${agentUser} ${pkgs.coreutils}/bin/sha256sum ${envFile} 2>/dev/null | ${pkgs.coreutils}/bin/cut -d' ' -f1 || true)"
      if [ -n "$PASEO_AGENT_ENV_SUM" ] \
         && [ "$(${pkgs.coreutils}/bin/cat /var/db/paseo-agent-env.sha256 2>/dev/null || true)" != "$PASEO_AGENT_ENV_SUM" ]; then
        if /bin/launchctl kickstart -k system/dev.paseo.agent; then
          (umask 077; echo "$PASEO_AGENT_ENV_SUM" > /var/db/paseo-agent-env.sha256)
          echo "paseo-agent: env changed; restarted system/dev.paseo.agent"
        else
          echo "paseo-agent: WARNING env changed but restarting system/dev.paseo.agent failed" >&2
        fi
      fi
      unset PASEO_AGENT_ENV_SUM

      # --- 2b. Clone the agent's repos (once) ---------------------------------
      # Needs GH_TOKEN in the rendered env file (op-secrets ran at the start of
      # postActivation). Run as the agent; the token is read as the agent with
      # a plain sed, never echoed, and handed to gh via the environment. gh
      # injects its own credential helper for the clone, so the token never
      # lands in a URL or .git/config. A repo the bot can't see yet (e.g.
      # infrastructure before it's invited) warns; a later switch retries.
      sudo -u ${agentUser} /bin/mkdir -p "${agentHome}/ops/worktrees"
      PASEO_AGENT_GH_TOKEN="$(sudo -u ${agentUser} ${pkgs.gnused}/bin/sed -n 's/^GH_TOKEN=//p' ${envFile} 2>/dev/null || true)"
      if [ -z "$PASEO_AGENT_GH_TOKEN" ]; then
        echo "paseo-agent: no GH_TOKEN in ${envFile} yet; skipping repo clones"
      else
        for repo in ${lib.concatStringsSep " " agentRepos}; do
          if [ -d "${agentHome}/ops/$repo/.git" ]; then continue; fi
          if GH_TOKEN="$PASEO_AGENT_GH_TOKEN" ${pkgs.coreutils}/bin/timeout 300 \
               sudo --preserve-env=GH_TOKEN -u ${agentUser} -H \
               /usr/bin/env PATH="${pkgs.git}/bin:/usr/bin:/bin" GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
               ${pkgs.gh}/bin/gh repo clone "MattiasGees/$repo" "${agentHome}/ops/$repo" </dev/null; then
            echo "paseo-agent: cloned MattiasGees/$repo into ${agentHome}/ops/$repo"
          else
            echo "paseo-agent: WARNING could not clone MattiasGees/$repo (bot not invited yet?); a later switch retries" >&2
          fi
        done
      fi
      unset PASEO_AGENT_GH_TOKEN

      # Make the admin home private to mattias (hides kubeconfig / ssh keys from
      # the new unprivileged user).
      chmod 700 /Users/${user}
    '';

    # --- 3. The Paseo daemon under launchd, running as the agent -------------
    # The daemon reads daemon.listen from ${agentHome}/.paseo/config.json (seeded
    # above). The bundled binary comes from the Paseo.app cask in
    # darwin/configuration.nix. The command is a wrapper that first loads the
    # op-secrets-rendered env file (CLAUDE_CODE_OAUTH_TOKEN, GH_TOKEN).
    launchd.daemons.paseo-agent = {
      serviceConfig = {
        Label = "dev.paseo.agent";
        UserName = agentUser;
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${agentHome}/Library/Logs/paseo-agent.log";
        StandardErrorPath = "${agentHome}/Library/Logs/paseo-agent.err.log";
      };
      command = "${daemonWrapper}";
      # A launchd daemon has no login shell, so it sees only this literal PATH.
      # home-manager useUserPackages = true installs home.packages to
      # /etc/profiles/per-user/<user>/bin (NOT ~/.nix-profile/bin), so that must
      # come first or the claude processes the daemon spawns can't find
      # kubectl/gh/jq/yq-go/kustomize/promtool/ansible. /opt/homebrew/bin stays
      # for the `claude` CLI (Homebrew cask).
      path = [
        "/etc/profiles/per-user/${agentUser}/bin"
        "/run/current-system/sw/bin"
        "/opt/homebrew/bin"
        "/usr/bin"
        "/bin"
        "/usr/sbin"
      ];
      environment = {
        HOME = agentHome;
        PASEO_HOME = "${agentHome}/.paseo";
      };
    };

    # --- 4. The agent's home-manager profile ---------------------------------
    home-manager.users.paseo-agent = { pkgs, ... }: {
      home.stateVersion = "23.05";
      home.homeDirectory = agentHome;

      # Read-only investigation toolkit. prometheus.cli provides promtool.
      home.packages = with pkgs; [
        kubectl gh git jq yq-go curl kustomize prometheus.cli ansible python3
      ];

      # Bot git identity: user.name/user.email live in ~/.config/git/identity,
      # rendered from 1Password (github-bot/username, github-bot/email) by
      # op-secrets, so nothing identifying sits in the world-readable store.
      # GitHub HTTPS auth goes through gh, which reads GH_TOKEN from the
      # environment (the daemon and interactive shells load ~/.paseo/env). The
      # empty helper first resets any inherited helper, as `gh auth setup-git`
      # does.
      programs.git = {
        enable = true;
        settings = {
          init.defaultBranch = "main";
          credential."https://github.com".helper = [
            ""
            "!${pkgs.gh}/bin/gh auth git-credential"
          ];
        };
        includes = [ { path = "${agentHome}/.config/git/identity"; } ];
      };

      # Interactive shells (`sudo -iu paseo-agent`) load the same env file as
      # the daemon, so gh/claude work when testing by hand.
      programs.zsh = {
        enable = true;
        initContent = ''
          [ -r ~/.paseo/env ] && { set -a; . ~/.paseo/env; set +a; }
        '';
      };

      # SSH to the read-only fleet logins. This repo's pinned home-manager uses
      # the new programs.ssh.settings schema (capitalised ssh_config directives;
      # matchBlocks is a deprecated alias), mirroring modules/shell/ssh.nix, so
      # per-host blocks go under settings.<alias>. The private key
      # ~/.ssh/id_ed25519 is rendered from 1Password (ssh-key/private_key) by
      # op-secrets.
      programs.ssh = {
        enable = true;
        enableDefaultConfig = false;
        settings =
          let
            common = {
              User = agentUser;
              IdentityFile = "~/.ssh/id_ed25519";
              IdentitiesOnly = true;
              BatchMode = "yes";
              StrictHostKeyChecking = "accept-new";
            };
          in
          {
            "polaris" = common // { HostName = "polaris.orca-lionfish.ts.net"; };
            "pi1" = common // { HostName = "pi1.orca-lionfish.ts.net"; };
            "atni" = common // { HostName = "atni.orca-lionfish.ts.net"; };
            "seedbox" = common // { HostName = "100.101.146.28"; };
          };
      };

      home.sessionVariables = {
        KUBECONFIG = "${agentHome}/.kube/config";
      };

      # Claude Code settings for the agent, in Claude Code rule syntax.
      # NOTE: Claude Code may rewrite ~/.claude/settings.json at runtime, so this
      # file is a STARTING posture, not a durable sandbox — durable enforcement
      # is a known open item. We deliberately do NOT ship a machine-global
      # managed-settings file, because that would also bind mattias's own Claude.
      # Prefix-matched Bash rules also can't fully express "HTTP GET only" or a
      # port on a Tailscale IP; the real read-only guarantees come from the
      # unprivileged logins and remote branch protection (see ops/CLAUDE.md).
      # The curl/git deny rules below are a porous speed-bump, not a boundary
      # (curl flag order, shell tricks, alternative clients all evade prefix
      # matching); the durable control — a network egress allowlist for this
      # user — is a documented later item.
      home.file.".claude/settings.json".text = builtins.toJSON {
        disableClaudeAiConnectors = true;
        enabledPlugins = { };
        permissions = {
          allow = [
            # Read-only kubectl.
            "Bash(kubectl get:*)"
            "Bash(kubectl describe:*)"
            "Bash(kubectl logs:*)"
            "Bash(kubectl top:*)"
            "Bash(kubectl events:*)"
            "Bash(kubectl explain:*)"
            "Bash(kubectl api-resources:*)"
            "Bash(kubectl version:*)"
            "Bash(kubectl cluster-info:*)"
            "Bash(kubectl config get-contexts:*)"
            "Bash(kubectl config current-context:*)"
            "Bash(kubectl config view:*)"
            # Read-only fleet logins (ssh <host> <cmd>).
            "Bash(ssh polaris:*)"
            "Bash(ssh pi1:*)"
            "Bash(ssh atni:*)"
            "Bash(ssh seedbox:*)"
            # Prometheus read-only API (GET; -s-prefixed consistently).
            "Bash(curl -s https://prometheus.k8s.mattiasgees.be:*)"
            "Bash(curl -s https://grafana.k8s.mattiasgees.be:*)"
            # Alertmanager: read PATHS only, never the whole host — a host-wide
            # allow would let a silence POST ride in on top of it.
            "Bash(curl -s https://alertmanager.k8s.mattiasgees.be/api/v2/alerts:*)"
            "Bash(curl -s https://alertmanager.k8s.mattiasgees.be/api/v2/status:*)"
            # Git, gh (read + PR open), build/verify tools.
            "Bash(git:*)"
            "Bash(gh pr create:*)"
            "Bash(gh pr view:*)"
            "Bash(gh pr list:*)"
            "Bash(gh pr diff:*)"
            "Bash(gh pr status:*)"
            "Bash(kustomize build:*)"
            "Bash(promtool:*)"
            "Bash(jq:*)"
            "Bash(terraform fmt:*)"
            "Bash(terraform validate:*)"
            "Bash(ansible-playbook --syntax-check:*)"
            # Writes confined to the agent's working tree.
            "Read(//Users/paseo-agent/**)"
            "Edit(//Users/paseo-agent/ops/**)"
            "Write(//Users/paseo-agent/ops/**)"
            # Runbook references.
            "WebFetch(domain:runbooks.prometheus-operator.dev)"
          ];
          deny = [
            # Speed-bump against pushing to a default branch or using
            # `git -c <cfg>=<exec>` for arbitrary exec. NOT a boundary: the agent
            # must still push its own agent/<name> branch (plain `git push` is
            # allowed) so `gh pr create` can open the PR. A refspec like
            # `git push origin HEAD:main` evades these prefixes — remote branch
            # protection (deferred) is the real control.
            "Bash(git -c:*)"
            "Bash(git push origin main:*)"
            "Bash(git push origin master:*)"
            "Bash(git push origin mattias:*)"
            "Bash(git push --force:*)"
            "Bash(git push -f:*)"
            # No privileged / state-changing gh.
            "Bash(gh pr merge:*)"
            "Bash(gh api:*)"
            "Bash(gh repo:*)"
            "Bash(gh gist:*)"
            "Bash(gh workflow:*)"
            "Bash(gh run:*)"
            # Terraform is CI-only for this agent (plan included).
            "Bash(terraform plan:*)"
            "Bash(terraform apply:*)"
            "Bash(terraform destroy:*)"
            "Bash(terraform import:*)"
            "Bash(terraform state:*)"
            # The Paseo CLI and both daemon ports are off-limits.
            "Bash(paseo:*)"
            "Bash(curl http://localhost:6767:*)"
            "Bash(curl http://localhost:6768:*)"
            "Bash(curl http://127.0.0.1:6767:*)"
            "Bash(curl http://127.0.0.1:6768:*)"
            # No mutating HTTP (covers Alertmanager silences and any seedbox
            # write): deny every curl flag that sets a method or sends a body.
            "Bash(curl -X:*)"
            "Bash(curl -XPOST:*)"
            "Bash(curl -X POST:*)"
            "Bash(curl -X PUT:*)"
            "Bash(curl -X DELETE:*)"
            "Bash(curl -X PATCH:*)"
            "Bash(curl --request:*)"
            "Bash(curl -d:*)"
            "Bash(curl --data:*)"
            "Bash(curl --data-raw:*)"
            "Bash(curl --data-binary:*)"
            "Bash(curl -F:*)"
            "Bash(curl --form:*)"
            "Bash(curl -T:*)"
            "Bash(curl --upload-file:*)"
            "Bash(amtool:*)"
            # No web search.
            "WebSearch"
            # No reading the admin's home or system secret stores.
            "Read(//Users/mattias/**)"
            "Read(//Users/Shared/**)"
            "Read(//etc/**)"
            "Read(//private/etc/**)"
            "Read(//var/root/**)"
          ];
        };
      };

      # The agent's operating runbook.
      home.file."ops/CLAUDE.md".source = ./paseo-agent/CLAUDE.md;
    };
  };
}

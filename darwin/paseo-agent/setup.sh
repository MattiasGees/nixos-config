# shellcheck shell=bash
#
# paseo-agent-setup — script every remaining setup step (that has an API) for
# the read-only Paseo investigation agent declared in darwin/paseo-agent.nix.
# Packaged with writeShellApplication (set -euo pipefail, shellcheck at build).
# Run it as mattias (the admin), NOT as root and NOT as the agent.
#
# Secret handling: nothing here echoes a secret. Secrets travel via stdin or
# environment variables (never argv where avoidable); agent-side commands run
# with `sudo -u paseo-agent -H`, receiving secrets via --preserve-env=<VAR>.
# The Hub keys are only ever handed to a single command, never written to the
# agent's files.
#
# 1Password contract (vault paseo-agent; must match darwin/paseo-agent/*.tpl):
#   ssh-key     private_key                     -> rendered ~/.ssh/id_ed25519
#   github-bot  username, email, token          -> rendered git identity + GH_TOKEN
#   claude      oauth_token                     -> rendered CLAUDE_CODE_OAUTH_TOKEN
#   kubeconfig  kubeconfig                      -> rendered ~/.kube/config
#   hetzner     k8s_readonly_token, atni_readonly_token  (pushed to GitHub secrets)
#   hub         dispatch_key, admin_key                  (script only, never rendered)

umask 077

VAULT=paseo-agent
AGENT=paseo-agent
AGENT_HOME=/Users/paseo-agent
AGENT_BIN=/etc/profiles/per-user/paseo-agent/bin
AGENT_PATH="$AGENT_BIN:/run/current-system/sw/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
ADMIN_HOME=/Users/mattias
HUB=https://paseo.k8s.mattiasgees.be
PASEO=/Applications/Paseo.app/Contents/Resources/bin/paseo
GH_OWNER=MattiasGees
EXPECTED_FP='SHA256:mkLMyBqIppY4PsJhLnBLpwFDdHiD4ZeJp7ipkGQXE+E'
DEFAULT_SSH_KEY=/Users/mattias/.claude/projects/-Users-mattias-Documents-git-k8s-config/sdd-paseo/agent-key/id_ed25519
ADMIN_CONTEXT=${PASEO_ADMIN_CONTEXT:-hetzner-master1}
K8S_SERVER=https://195.201.228.14:6443
AM_URL=https://alertmanager.k8s.mattiasgees.be
TOKEN_FILE=/etc/op/token
AWS_REGION=eu-west-1
AWS_SECRET_NAME=paseo-hub-api-key
FLEET_HOSTS=(polaris pi1 atni seedbox)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
say() { printf 'paseo-agent-setup: %s\n' "$*"; }
skip() { printf 'paseo-agent-setup: skip: %s\n' "$*"; }
die() {
  printf 'paseo-agent-setup: ERROR: %s\n' "$*" >&2
  exit 1
}

# Absolute path of a command (sudo may not search our PATH).
bin() { command -v "$1" || die "$1 not found on PATH"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# agent [-e VAR]... [-C DIR] CMD [ARG]...
# Run CMD (an absolute path) as the agent with HOME=its home and a fixed PATH.
# -e preserves VAR, which the caller has set via a command prefix, e.g.
#   GH_TOKEN="$tok" agent -e GH_TOKEN /path/to/gh ...
# so secrets reach the agent's process via its environment, not argv.
agent() {
  local keep="" dir=/
  while [ $# -gt 0 ]; do
    case $1 in
      -e) keep="${keep:+$keep,}$2"; shift 2 ;;
      -C) dir=$2; shift 2 ;;
      *) break ;;
    esac
  done
  local opts=(-u "$AGENT" -H)
  if [ -n "$keep" ]; then
    opts=(--preserve-env="$keep" "${opts[@]}")
  fi
  (
    cd / &&
      sudo "${opts[@]}" /usr/bin/env PATH="$AGENT_PATH" \
        /bin/sh -c 'cd "$1" || exit 1; shift; exec "$@"' sh "$dir" "$@"
  )
}

require_not_root() {
  [ "$(id -u)" -ne 0 ] || die "run as your admin user (mattias), not root"
}

require_op() {
  command -v op >/dev/null 2>&1 ||
    die "1Password CLI 'op' not on PATH (Homebrew cask 1password-cli; enable Settings > Developer > Integrate with 1Password CLI)"
  if ! op whoami >/dev/null 2>&1; then
    # With the desktop-app integration this triggers the unlock prompt.
    op signin >/dev/null || true
    op whoami >/dev/null 2>&1 ||
      die "'op whoami' failed: unlock the 1Password app (Settings > Developer > Integrate with 1Password CLI) or run: eval \"\$(op signin)\""
  fi
}

OP_ITEMS=""
load_items() {
  OP_ITEMS="$(op item list --vault "$VAULT" --format json | jq -r '.[].title')" ||
    die "could not list items in vault $VAULT"
}

item_exists() {
  case $'\n'"$OP_ITEMS"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

# field_set ITEM FIELD -> success if FIELD exists on ITEM with a non-empty value.
field_set() {
  item_exists "$1" || return 1
  local out
  out="$(op item get "$1" --vault "$VAULT" --format json --reveal |
    jq -r --arg f "$2" 'if any(.fields[]?; .label == $f and ((.value // "") != "")) then "yes" else "no" end')" ||
    die "could not read item $1 from vault $VAULT"
  [ "$out" = yes ]
}

# op_put ITEM FIELD TYPE — make FIELD on ITEM hold $OP_VALUE, creating ITEM (a
# Secure Note) if needed. The caller sets OP_VALUE via a command prefix; it is
# fed to op as a JSON item template on stdin (multi-line values survive intact).
op_put() {
  local item=$1 field=$2 type=$3
  [ -n "${OP_VALUE:-}" ] || die "internal: empty value for $item/$field"
  if item_exists "$item"; then
    op item get "$item" --vault "$VAULT" --format json --reveal |
      jq --arg f "$field" --arg t "$type" '
        if any(.fields[]?; .label == $f)
        then .fields |= map(if .label == $f then (.value = $ENV.OP_VALUE | .type = $t) else . end)
        else .fields += [{id: $f, label: $f, type: $t, value: $ENV.OP_VALUE}]
        end' |
      op item edit "$item" --vault "$VAULT" >/dev/null
    say "1Password: updated $item/$field"
  else
    jq -n --arg title "$item" --arg f "$field" --arg t "$type" \
      '{title: $title, category: "SECURE_NOTE", fields: [{id: $f, label: $f, type: $t, value: $ENV.OP_VALUE}]}' |
      op item create - --vault "$VAULT" >/dev/null
    OP_ITEMS="${OP_ITEMS:+$OP_ITEMS$'\n'}$item"
    say "1Password: created $item with field $field"
  fi
}

# op_get ITEM/FIELD -> the value on stdout (callers capture it; never printed).
op_get() {
  op read --no-newline "op://$VAULT/$1" 2>/dev/null ||
    die "1Password: op://$VAULT/$1 is missing or unreadable (run: paseo-agent-setup init)"
}

# prompt_field ITEM FIELD TYPE HINT — ask for a missing value (empty = skip).
prompt_field() {
  local item=$1 field=$2 type=$3 hint=$4 val=""
  if field_set "$item" "$field"; then
    skip "$item/$field already in 1Password"
    return 0
  fi
  # (`|| val=""`: EOF on stdin counts as "skip", not a set -e abort.)
  if [ "$type" = CONCEALED ]; then
    read -rsp "$item/$field ($hint). Paste it, hidden; empty = skip for now: " val || val=""
    printf '\n' >&2
  else
    read -rp "$item/$field ($hint); empty = skip for now: " val || val=""
  fi
  if [ -z "$val" ]; then
    skip "$item/$field left empty for now"
    return 0
  fi
  OP_VALUE="$val" op_put "$item" "$field" "$type"
}

# fp_of_private FILE -> SHA256 fingerprint of its public half.
fp_of_private() {
  ssh-keygen -y -P '' -f "$1" >"$WORK/pub" 2>/dev/null || return 1
  ssh-keygen -l -f "$WORK/pub" | cut -d' ' -f2
}

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------
init_ssh_key() {
  local src=$1 key fp ans
  if field_set ssh-key private_key; then
    skip "ssh-key/private_key already in 1Password"
  else
    [ -r "$src" ] || die "ssh-key: private key $src not readable (pass --ssh-key PATH)"
    key="$(cat "$src")"
    printf '%s\n' "$key" >"$WORK/key"
    fp="$(fp_of_private "$WORK/key")" || die "ssh-key: $src is not an unencrypted OpenSSH private key"
    [ "$fp" = "$EXPECTED_FP" ] || die "ssh-key: $src has fingerprint $fp, expected $EXPECTED_FP"
    say "ssh-key: $src matches $EXPECTED_FP"
    OP_VALUE="$key" op_put ssh-key private_key CONCEALED
    key=""
  fi

  # Round-trip: what op-secrets will render must be the expected key.
  rm -f "$WORK/key" "$WORK/pub"
  op read "op://$VAULT/ssh-key/private_key" >"$WORK/key" ||
    die "ssh-key: could not read op://$VAULT/ssh-key/private_key back"
  fp="$(fp_of_private "$WORK/key")" ||
    die "ssh-key: the value in 1Password is not a valid private key — fix the item before rendering"
  [ "$fp" = "$EXPECTED_FP" ] ||
    die "ssh-key: 1Password holds fingerprint $fp, expected $EXPECTED_FP"
  rm -f "$WORK/key"
  say "ssh-key: round-trip from 1Password OK ($fp)"

  if [ -e "$src" ]; then
    read -rp "Delete the scratch private key $src now (rm -P)? [y/N] " ans || ans=""
    case $ans in
      [yY] | [yY][eE][sS])
        /bin/rm -P "$src"
        say "removed $src"
        ;;
      *) skip "kept $src (delete it yourself once you're happy)" ;;
    esac
  fi
}

init_service_account() {
  local tok inst
  if sudo /bin/test -e "$TOKEN_FILE"; then
    skip "$TOKEN_FILE already present"
    return 0
  fi
  inst="$(bin install)"
  tok="$(op service-account create paseo-agent-mac --vault "$VAULT:read_items" --raw)" ||
    die "could not create service account paseo-agent-mac"
  [ -n "$tok" ] || die "op service-account create returned no token"
  if ! sudo /bin/test -d /etc/op; then
    sudo "$inst" -d -m 0700 -o root -g wheel /etc/op
    say "created /etc/op (root 0700)"
  fi
  printf '%s' "$tok" | sudo "$inst" -m 0600 -o root -g wheel /dev/stdin "$TOKEN_FILE"
  tok=""
  say "created service account paseo-agent-mac (read_items on $VAULT); token written to $TOKEN_FILE (root 0600)"
}

cmd_init() {
  local ssh_key=$DEFAULT_SSH_KEY
  while [ $# -gt 0 ]; do
    case $1 in
      --ssh-key)
        [ $# -ge 2 ] || die "--ssh-key needs a PATH"
        ssh_key=$2
        shift 2
        ;;
      *) die "init: unknown argument $1" ;;
    esac
  done
  require_op

  if op vault get "$VAULT" >/dev/null 2>&1; then
    skip "vault $VAULT exists"
  else
    op vault create "$VAULT" >/dev/null
    say "1Password: created vault $VAULT"
  fi
  load_items

  init_ssh_key "$ssh_key"

  prompt_field github-bot username STRING "the bot's GitHub login"
  prompt_field github-bot email STRING "the bot's commit email (its GitHub noreply address is fine)"
  prompt_field github-bot token CONCEALED "bot classic PAT, repo scope only, no workflow"
  prompt_field claude oauth_token CONCEALED "\`claude setup-token\` output (run it as any user, paste the token)"
  if field_set kubeconfig kubeconfig; then
    skip "kubeconfig/kubeconfig already in 1Password"
  else
    say "kubeconfig/kubeconfig missing: run 'paseo-agent-setup kubeconfig' (builds it from the cluster's paseo-agent-token)"
  fi
  prompt_field hetzner k8s_readonly_token CONCEALED "Hetzner Cloud console > k8s project > Security > API tokens, Read-only"
  prompt_field hetzner atni_readonly_token CONCEALED "Hetzner Cloud console > atni project > Security > API tokens, Read-only"
  prompt_field hub dispatch_key CONCEALED "Hub > Settings > API keys, scope runs:dispatch"
  prompt_field hub admin_key CONCEALED "Hub > Settings > API keys, scopes daemons:enroll, configuration:install, configuration:validate"

  init_service_account
  say "next: make switch NIXNAME=macbook-m1   # renders the agent's secrets from 1Password"
}

# ---------------------------------------------------------------------------
# github
# ---------------------------------------------------------------------------
cmd_github() {
  local repos=(k8s-config nixos-config ansible)
  while [ $# -gt 0 ]; do
    case $1 in
      --infrastructure) repos+=(infrastructure); shift ;;
      *) die "github: unknown argument $1" ;;
    esac
  done
  require_op
  local bot bot_token login r invites id name n=0 existing
  bot="$(op_get github-bot/username)"
  bot_token="$(op_get github-bot/token)"
  login="$(GH_TOKEN="$bot_token" gh api /user --jq .login)" ||
    die "GitHub rejected github-bot/token"
  [ "$login" = "$bot" ] || die "github-bot/token belongs to '$login', not '$bot'"

  for r in "${repos[@]}"; do
    if gh api "repos/$GH_OWNER/$r/collaborators/$bot" --silent >/dev/null 2>&1; then
      skip "$bot is already a collaborator on $GH_OWNER/$r"
    else
      gh api -X PUT "repos/$GH_OWNER/$r/collaborators/$bot" -f permission=push --silent
      say "invited $bot to $GH_OWNER/$r (push)"
    fi
  done

  invites="$(GH_TOKEN="$bot_token" gh api /user/repository_invitations --paginate \
    --jq ".[] | select(.repository.full_name | startswith(\"$GH_OWNER/\")) | \"\(.id) \(.repository.full_name)\"")"
  while read -r id name; do
    [ -n "$id" ] || continue
    GH_TOKEN="$bot_token" gh api -X PATCH "/user/repository_invitations/$id" --silent
    say "accepted the invitation to $name as $bot"
    n=$((n + 1))
  done <<<"$invites"
  [ "$n" -gt 0 ] || skip "no pending $GH_OWNER/* invitations for $bot"

  existing="$(gh api "repos/$GH_OWNER/nixos-config/rulesets" --paginate \
    --jq '.[] | select(.name == "protect-mattias") | .id')"
  if [ -n "$existing" ]; then
    skip "ruleset protect-mattias already exists on $GH_OWNER/nixos-config (id $existing)"
  else
    jq -n '{
      name: "protect-mattias",
      target: "branch",
      enforcement: "active",
      conditions: {ref_name: {include: ["refs/heads/mattias"], exclude: []}},
      rules: [
        {type: "pull_request", parameters: {
          required_approving_review_count: 1,
          dismiss_stale_reviews_on_push: false,
          require_code_owner_review: false,
          require_last_push_approval: false,
          required_review_thread_resolution: false}},
        {type: "deletion"},
        {type: "non_fast_forward"}
      ],
      bypass_actors: [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}]
    }' | gh api -X POST "repos/$GH_OWNER/nixos-config/rulesets" --input - --silent
    say "created ruleset protect-mattias on $GH_OWNER/nixos-config (refs/heads/mattias: 1 approval, no deletion, no force-push; admins bypass)"
  fi
}

# ---------------------------------------------------------------------------
# secrets
# ---------------------------------------------------------------------------
cmd_secrets() {
  require_op
  local v cur
  v="$(op_get hetzner/k8s_readonly_token)"
  printf '%s' "$v" | gh secret set HCLOUD_TOKEN_READONLY -R "$GH_OWNER/infrastructure"
  say "GitHub: set HCLOUD_TOKEN_READONLY on $GH_OWNER/infrastructure (always re-set: Actions secrets can't be read back to compare)"
  v="$(op_get hetzner/atni_readonly_token)"
  printf '%s' "$v" | gh secret set HCLOUD_TOKEN_ATNI_READONLY -R "$GH_OWNER/infrastructure"
  say "GitHub: set HCLOUD_TOKEN_ATNI_READONLY on $GH_OWNER/infrastructure"

  aws sts get-caller-identity >/dev/null 2>&1 ||
    die "AWS credentials don't work — run 'aws login' and re-run 'paseo-agent-setup secrets'"
  v="$(op_get hub/dispatch_key)"
  if aws secretsmanager describe-secret --region "$AWS_REGION" --secret-id "$AWS_SECRET_NAME" >/dev/null 2>&1; then
    cur="$(aws secretsmanager get-secret-value --region "$AWS_REGION" --secret-id "$AWS_SECRET_NAME" \
      --query SecretString --output text 2>/dev/null || true)"
    if [ "$cur" = "$v" ]; then
      skip "AWS: $AWS_SECRET_NAME ($AWS_REGION) already holds hub/dispatch_key"
    else
      printf '%s' "$v" | aws secretsmanager put-secret-value --region "$AWS_REGION" \
        --secret-id "$AWS_SECRET_NAME" --secret-string file:///dev/stdin >/dev/null
      say "AWS: updated $AWS_SECRET_NAME ($AWS_REGION) from hub/dispatch_key"
    fi
  else
    printf '%s' "$v" | aws secretsmanager create-secret --region "$AWS_REGION" \
      --name "$AWS_SECRET_NAME" --secret-string file:///dev/stdin >/dev/null
    say "AWS: created $AWS_SECRET_NAME ($AWS_REGION) from hub/dispatch_key"
  fi
  v=""
  cur=""
}

# ---------------------------------------------------------------------------
# reconcile
# ---------------------------------------------------------------------------
cmd_reconcile() {
  flux --context "$ADMIN_CONTEXT" reconcile kustomization flux-system --with-source
  flux --context "$ADMIN_CONTEXT" reconcile kustomization paseo
  flux --context "$ADMIN_CONTEXT" reconcile kustomization prometheus-csp --with-source
  flux --context "$ADMIN_CONTEXT" reconcile helmrelease prometheus -n monitoring
  kubectl --context "$ADMIN_CONTEXT" -n paseo get pods
}

# ---------------------------------------------------------------------------
# kubeconfig
# ---------------------------------------------------------------------------
cmd_kubeconfig() {
  require_op
  load_items
  local token ca cfg cur
  token="$(kubectl --context "$ADMIN_CONTEXT" -n paseo get secret paseo-agent-token \
    -o jsonpath='{.data.token}' | base64 -d)" ||
    die "could not read Secret paseo/paseo-agent-token via context $ADMIN_CONTEXT"
  [ -n "$token" ] || die "Secret paseo/paseo-agent-token has no token yet"
  ca="$(kubectl config view --raw --minify --context "$ADMIN_CONTEXT" \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  if [ -z "$ca" ]; then
    ca="$(kubectl --context "$ADMIN_CONTEXT" -n paseo get secret paseo-agent-token \
      -o jsonpath='{.data.ca\.crt}')"
  fi
  [ -n "$ca" ] || die "could not determine the cluster CA for context $ADMIN_CONTEXT"

  cfg="$(printf '%s\n' \
    'apiVersion: v1' \
    'kind: Config' \
    'clusters:' \
    '- name: hetzner' \
    '  cluster:' \
    "    server: $K8S_SERVER" \
    "    certificate-authority-data: $ca" \
    'contexts:' \
    '- name: hetzner' \
    '  context:' \
    '    cluster: hetzner' \
    "    user: $AGENT" \
    'current-context: hetzner' \
    'users:' \
    "- name: $AGENT" \
    '  user:' \
    "    token: $token")"
  token=""

  cur=""
  if field_set kubeconfig kubeconfig; then
    cur="$(op_get kubeconfig/kubeconfig)"
  fi
  if [ "$cur" = "$cfg" ]; then
    skip "1Password kubeconfig/kubeconfig is already current"
  else
    OP_VALUE="$cfg" op_put kubeconfig kubeconfig CONCEALED
    say "next: make switch NIXNAME=macbook-m1   # renders it to $AGENT_HOME/.kube/config"
  fi
  cfg=""
  cur=""
}

# ---------------------------------------------------------------------------
# hub-connect
# ---------------------------------------------------------------------------
hub_state() {
  agent "$PASEO" hub status --json --home "$AGENT_HOME/.paseo" 2>/dev/null |
    jq -r "(if type == \"array\" then .[0] else . end) | .$1 // empty" 2>/dev/null || true
}

cmd_hub_connect() {
  require_op
  local admin_key state daemon_id slug
  admin_key="$(op_get hub/admin_key)"
  state="$(hub_state state)"
  case $state in
    connected | connecting | reconnecting)
      skip "agent daemon already enrolled with the Hub (state: $state)"
      ;;
    *)
      PASEO_HUB_API_KEY="$admin_key" agent -e PASEO_HUB_API_KEY \
        "$PASEO" hub connect "$HUB" --permission hub.execute --home "$AGENT_HOME/.paseo"
      say "enrolled the agent daemon with $HUB (permission hub.execute)"
      ;;
  esac

  daemon_id="$(hub_state daemonId)"
  if [ -z "$daemon_id" ]; then
    say "WARNING: 'paseo hub status' reports no daemonId yet; re-run hub-connect in a moment for the slug"
  else
    slug="$(printf 'Authorization: Bearer %s\n' "$admin_key" |
      curl -fsS -H @- "$HUB/api/v1/configuration-resources" |
      jq -r --arg id "$daemon_id" '.daemons[]? | select(.id == $id) | .slug')" ||
      die "could not list Hub configuration resources"
    if [ -n "$slug" ]; then
      say "Hub daemon slug for the agent: $slug (id $daemon_id)"
    else
      say "WARNING: daemon $daemon_id not found in the Hub's configuration resources"
    fi
  fi
  admin_key=""
  say "Pair your phone: sudo -iu paseo-agent /Applications/Paseo.app/Contents/Resources/bin/paseo pair"
}

# ---------------------------------------------------------------------------
# deploy-trigger
# ---------------------------------------------------------------------------
cmd_deploy_trigger() {
  require_op
  local repo="$AGENT_HOME/ops/k8s-config" gh_token admin_key
  [ -x "$AGENT_BIN/git" ] || die "$AGENT_BIN/git missing — has 'make switch NIXNAME=macbook-m1' run?"
  agent /bin/test -d "$repo/.git" ||
    die "$repo is not cloned yet (make switch clones it once github-bot/token is in 1Password)"
  gh_token="$(op_get github-bot/token)"
  GH_TOKEN="$gh_token" agent -e GH_TOKEN -C "$repo" "$AGENT_BIN/git" pull --ff-only
  gh_token=""
  say "pulled $repo (fast-forward only)"
  agent /bin/test -d "$repo/.paseo/triggers" ||
    die "$repo/.paseo/triggers/ does not exist yet — merge the k8s-config trigger PR first"

  admin_key="$(op_get hub/admin_key)"
  PASEO_HUB_API_KEY="$admin_key" agent -e PASEO_HUB_API_KEY -C "$repo" \
    "$PASEO" hub deploy --hub "$HUB" --dry-run
  say "dry-run OK; deploying"
  PASEO_HUB_API_KEY="$admin_key" agent -e PASEO_HUB_API_KEY -C "$repo" \
    "$PASEO" hub deploy --hub "$HUB"
  admin_key=""
  say "deployed $repo/.paseo triggers to $HUB"
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
VERIFY_ROWS=()
VERIFY_FAILS=0
record() {
  VERIFY_ROWS+=("$(printf '%-4s  %s' "$1" "$2")")
  if [ "$1" = FAIL ]; then
    VERIFY_FAILS=$((VERIFY_FAILS + 1))
  fi
}

cmd_verify() {
  local kubectl_bin ssh_bin timeout_bin mode out rc h kcfg
  kubectl_bin="$(bin kubectl)"
  ssh_bin="$(bin ssh)"
  timeout_bin="$(bin timeout)"
  kcfg="KUBECONFIG=$AGENT_HOME/.kube/config"
  agent /usr/bin/true || die "cannot run commands as $AGENT via sudo"

  # (a) admin home is private
  mode="$(stat -c %a "$ADMIN_HOME")"
  if [ "$mode" = 700 ]; then
    record PASS "$ADMIN_HOME is mode 700"
  else
    record FAIL "$ADMIN_HOME is mode $mode (want 700)"
  fi

  # (b) the agent can't read the admin kubeconfig
  if agent /bin/cat "$ADMIN_HOME/.kube/config" >/dev/null 2>&1; then
    record FAIL "agent CAN read $ADMIN_HOME/.kube/config"
  else
    record PASS "agent cannot read $ADMIN_HOME/.kube/config"
  fi

  # (c) the agent's kubeconfig is read-only
  if agent /usr/bin/env "$kcfg" "$kubectl_bin" get nodes >/dev/null 2>&1; then
    record PASS "agent: kubectl get nodes works"
  else
    record FAIL "agent: kubectl get nodes failed"
  fi
  out="$(agent /usr/bin/env "$kcfg" "$kubectl_bin" auth can-i get secrets -A 2>/dev/null || true)"
  if [ "$out" = no ]; then
    record PASS "agent: kubectl auth can-i get secrets -A = no"
  else
    record FAIL "agent: kubectl auth can-i get secrets -A = '${out:-error}' (want no)"
  fi
  out="$(agent /usr/bin/env "$kcfg" "$kubectl_bin" auth can-i create pods --subresource=exec -A 2>/dev/null || true)"
  if [ "$out" = no ]; then
    record PASS "agent: kubectl auth can-i create pods/exec -A = no"
  else
    record FAIL "agent: kubectl auth can-i create pods/exec -A = '${out:-error}' (want no)"
  fi

  # (d) fleet logins: logs readable, no sudo, no forwarding
  for h in "${FLEET_HOSTS[@]}"; do
    if agent "$ssh_bin" -o ConnectTimeout=10 "$h" journalctl -n 1 -q >/dev/null 2>&1; then
      record PASS "$h: agent can read the journal"
    else
      record FAIL "$h: agent ssh journalctl failed"
    fi
    # 255 = ssh itself failed (no connection), which proves nothing about sudo.
    rc=0
    agent "$ssh_bin" -o ConnectTimeout=10 "$h" sudo -n true >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 255 ]; then
      record PASS "$h: sudo -n true refused (exit $rc)"
    elif [ "$rc" -eq 0 ]; then
      record FAIL "$h: agent has passwordless sudo"
    else
      record FAIL "$h: could not connect to test sudo"
    fi
    # -W opens a direct-tcpip channel immediately, so the server's forwarding
    # policy is really exercised (-L only binds a local port and never asks the
    # server until something connects). A remote sshd banner = forwarding works;
    # sshd's "administratively prohibited" = refused; anything else (e.g. no
    # connection at all) proves nothing and fails.
    out="$(agent "$timeout_bin" 20 "$ssh_bin" -o ConnectTimeout=10 -o ExitOnForwardFailure=yes \
      -W localhost:22 "$h" </dev/null 2>&1 | head -c 4096 || true)"
    if [[ $out == *SSH-2.0-* ]]; then
      record FAIL "$h: TCP forwarding to localhost:22 is ALLOWED"
    elif [[ $out == *"prohibited"* || $out == *"open failed"* ]]; then
      record PASS "$h: TCP forwarding refused"
    else
      record FAIL "$h: forwarding test inconclusive (no connection?)"
    fi
  done

  # (e) the agent daemon is running
  out="$(/bin/launchctl print system/dev.paseo.agent 2>/dev/null ||
    sudo /bin/launchctl print system/dev.paseo.agent 2>/dev/null || true)"
  if [[ $out == *"state = running"* ]]; then
    record PASS "launchd system/dev.paseo.agent is running"
  else
    record FAIL "launchd system/dev.paseo.agent is not running"
  fi

  printf '\n%-4s  %s\n' RES CHECK
  printf '%s\n' "${VERIFY_ROWS[@]}"
  printf '\n'
  if [ "$VERIFY_FAILS" -gt 0 ]; then
    die "$VERIFY_FAILS check(s) failed"
  fi
  say "all checks passed"
}

# ---------------------------------------------------------------------------
# smoke-test
# ---------------------------------------------------------------------------
cmd_smoke_test() {
  amtool --alertmanager.url="$AM_URL" alert add PaseoSmokeTest severity=warning namespace=default \
    --annotation=summary="Paseo smoke test" \
    --annotation=description="Synthetic alert to test the investigation pipeline."
  say "fired PaseoSmokeTest at $AM_URL"
  say "look for: a new investigation run in $HUB within ~3 min, executed by the agent daemon;"
  say "then re-run 'paseo-agent-setup smoke-test' — it must NOT start a second run (same alert, deduplicated)."
}

# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
paseo-agent-setup — set up the read-only Paseo investigation agent (run as mattias)

  init [--ssh-key PATH]      create the paseo-agent vault + items (prompts for missing values),
                             store the agent SSH key, write /etc/op/token for make switch
  github [--infrastructure]  invite + accept the bot on the repos; protect-mattias ruleset on nixos-config
  secrets                    Hetzner read-only tokens -> GitHub secrets; Hub dispatch key -> AWS Secrets Manager
  reconcile                  flux reconcile flux-system, paseo, prometheus-csp, prometheus; list paseo pods
  kubeconfig                 build the agent's read-only kubeconfig from the cluster and store it in 1Password
  hub-connect                enroll the agent daemon with the Hub (hub.execute) and print its daemon slug
  deploy-trigger             as the agent: pull k8s-config, paseo hub deploy --dry-run, then deploy
  verify                     PASS/FAIL checks of the agent's read-only posture and its daemon
  smoke-test                 fire a synthetic PaseoSmokeTest alert at Alertmanager
  help                       show this list
EOF
}

main() {
  local cmd=${1:-help}
  if [ $# -gt 0 ]; then shift; fi
  case $cmd in
    help | -h | --help) usage; return 0 ;;
  esac
  require_not_root
  case $cmd in
    init) cmd_init "$@" ;;
    github) cmd_github "$@" ;;
    secrets) cmd_secrets "$@" ;;
    reconcile) cmd_reconcile "$@" ;;
    kubeconfig) cmd_kubeconfig "$@" ;;
    hub-connect) cmd_hub_connect "$@" ;;
    deploy-trigger) cmd_deploy_trigger "$@" ;;
    verify) cmd_verify "$@" ;;
    smoke-test) cmd_smoke_test "$@" ;;
    *)
      usage >&2
      die "unknown subcommand: $cmd"
      ;;
  esac
}

main "$@"

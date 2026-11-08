# shellcheck shell=bash
#
# paseo-agent-setup — script every remaining setup step (that has an API) for
# the read-only Paseo investigation agent declared in darwin/paseo-agent.nix.
# Packaged with writeShellApplication (set -euo pipefail, shellcheck at build).
# Run it as mattias (the admin), NOT as root and NOT as the agent.
#
# Secret handling: nothing here echoes a secret. Secrets travel via stdin or
# environment variables (never argv where avoidable). Agent-side commands run
# with `sudo -u paseo-agent -H`, and on macOS any same-uid process can read
# another's environment (ps -E), so the ONLY secret ever handed to an
# agent-owned process is the single-purpose Hub enroll_key (daemons:enroll),
# once, for `hub connect`. admin_key / dispatch_key / Hetzner tokens are used
# by mattias-side processes only and are never written to the agent's files.
#
# 1Password contract — two vaults:
#   vault paseo-agent (the Mac's service account reads ONLY this; exactly what
#   darwin/paseo-agent/*.tpl renders):
#     ssh-key     private_key             -> ~/.ssh/id_ed25519
#     github-bot  username, email, token  -> git identity + GH_TOKEN
#     claude      oauth_token             -> CLAUDE_CODE_OAUTH_TOKEN
#     kubeconfig  kubeconfig              -> ~/.kube/config
#   vault paseo-agent-admin (script only; the service account has NO access):
#     hub                 dispatch_key (runs:dispatch -> AWS),
#                         admin_key (configuration:install + :validate; mattias only),
#                         enroll_key (daemons:enroll only; the agent sees it once)
#     hetzner             k8s_readonly_token, atni_readonly_token (-> GitHub secrets)
#     op-service-account  token (backup of /etc/op/token)

umask 077

VAULT=paseo-agent
ADMIN_VAULT=paseo-agent-admin
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

# agent [-e VAR]... CMD [ARG]...
# Run CMD (an absolute path) as the agent with HOME=its home and a fixed PATH.
# -e preserves VAR, which the caller has set via a command prefix, e.g.
#   PASEO_HUB_API_KEY="$enroll_key" agent -e PASEO_HUB_API_KEY /path/to/paseo ...
# (env, not argv). The agent can read that environment while CMD runs, so
# only ever pass it the enroll_key — never admin_key or dispatch_key.
agent() {
  local keep=""
  while [ $# -gt 0 ]; do
    case $1 in
      -e) keep="${keep:+$keep,}$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local opts=(-u "$AGENT" -H)
  if [ -n "$keep" ]; then
    opts=(--preserve-env="$keep" "${opts[@]}")
  fi
  (cd / && sudo "${opts[@]}" /usr/bin/env PATH="$AGENT_PATH" "$@")
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

# Item titles per vault (not secret), loaded once per vault by load_items.
declare -A OP_ITEMS=()
load_items() { # VAULT
  OP_ITEMS[$1]="$(op item list --vault "$1" --format json | jq -r '.[].title')" ||
    die "could not list items in vault $1"
}

item_exists() { # VAULT ITEM
  case $'\n'"${OP_ITEMS[$1]:-}"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_vault() { # VAULT
  if op vault get "$1" >/dev/null 2>&1; then
    skip "vault $1 exists"
  else
    op vault create "$1" >/dev/null || die "could not create vault $1"
    say "1Password: created vault $1"
  fi
}

# field_set VAULT ITEM FIELD -> success if FIELD exists on ITEM with a non-empty value.
field_set() {
  item_exists "$1" "$2" || return 1
  local out
  out="$(op item get "$2" --vault "$1" --format json --reveal |
    jq -r --arg f "$3" 'if any(.fields[]?; .label == $f and ((.value // "") != "")) then "yes" else "no" end')" ||
    die "could not read item $2 from vault $1"
  [ "$out" = yes ]
}

# op_put VAULT ITEM FIELD TYPE — make FIELD on ITEM hold $OP_VALUE, creating
# ITEM (a Secure Note) if needed. The caller sets OP_VALUE via a command prefix
# (OP_VALUE="" with OP_ALLOW_EMPTY=1 blanks the field); it is fed to op as a
# JSON item template on stdin, so multi-line values survive intact and nothing
# secret is on argv. Failures die explicitly (callers may run it in an `if`).
op_put() {
  local vault=$1 item=$2 field=$3 type=$4
  if [ -z "${OP_VALUE:-}" ] && [ -z "${OP_ALLOW_EMPTY:-}" ]; then
    die "internal: empty value for $vault/$item/$field"
  fi
  if item_exists "$vault" "$item"; then
    op item get "$item" --vault "$vault" --format json --reveal |
      jq --arg f "$field" --arg t "$type" '
        if any(.fields[]?; .label == $f)
        then .fields |= map(if .label == $f then (.value = $ENV.OP_VALUE | .type = $t) else . end)
        else .fields += [{id: $f, label: $f, type: $t, value: $ENV.OP_VALUE}]
        end' |
      op item edit "$item" --vault "$vault" >/dev/null ||
      die "1Password: could not update $vault/$item/$field"
    say "1Password: updated $vault/$item/$field"
  else
    jq -n --arg title "$item" --arg f "$field" --arg t "$type" \
      '{title: $title, category: "SECURE_NOTE", fields: [{id: $f, label: $f, type: $t, value: $ENV.OP_VALUE}]}' |
      op item create - --vault "$vault" >/dev/null ||
      die "1Password: could not create $vault/$item"
    OP_ITEMS[$vault]="${OP_ITEMS[$vault]:+${OP_ITEMS[$vault]}$'\n'}$item"
    say "1Password: created $vault/$item with field $field"
  fi
}

# op_get VAULT/ITEM/FIELD -> the value on stdout (callers capture it; never printed).
op_get() {
  local v
  v="$(op read --no-newline "op://$1" 2>/dev/null)" ||
    die "1Password: op://$1 is missing or unreadable (run: paseo-agent-setup init)"
  [ -n "$v" ] || die "1Password: op://$1 is empty (run: paseo-agent-setup init)"
  printf '%s' "$v"
}

# prompt_field VAULT ITEM FIELD TYPE HINT — ask for a missing value (empty = skip).
prompt_field() {
  local vault=$1 item=$2 field=$3 type=$4 hint=$5 val=""
  if field_set "$vault" "$item" "$field"; then
    skip "$vault/$item/$field already in 1Password"
    return 0
  fi
  # (`|| val=""`: EOF on stdin counts as "skip", not a set -e abort.)
  if [ "$type" = CONCEALED ]; then
    read -rsp "$vault/$item/$field ($hint). Paste it, hidden; empty = skip for now: " val || val=""
    printf '\n' >&2
  else
    read -rp "$vault/$item/$field ($hint); empty = skip for now: " val || val=""
  fi
  if [ -z "$val" ]; then
    skip "$vault/$item/$field left empty for now"
    return 0
  fi
  OP_VALUE="$val" op_put "$vault" "$item" "$field" "$type"
}

# yes_no PROMPT -> success only on an explicit y/yes (EOF = no).
yes_no() {
  local ans=""
  read -rp "$1 [y/N] " ans || ans=""
  case $ans in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
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
  local src=$1 key fp
  if field_set "$VAULT" ssh-key private_key; then
    skip "$VAULT/ssh-key/private_key already in 1Password"
  else
    [ -r "$src" ] || die "ssh-key: private key $src not readable (pass --ssh-key PATH)"
    key="$(cat "$src")"
    printf '%s\n' "$key" >"$WORK/key"
    fp="$(fp_of_private "$WORK/key")" || die "ssh-key: $src is not an unencrypted OpenSSH private key"
    [ "$fp" = "$EXPECTED_FP" ] || die "ssh-key: $src has fingerprint $fp, expected $EXPECTED_FP"
    say "ssh-key: $src matches $EXPECTED_FP"
    OP_VALUE="$key" op_put "$VAULT" ssh-key private_key CONCEALED
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
    if yes_no "Delete the scratch private key $src now (rm -P)?"; then
      /bin/rm -P "$src"
      say "removed $src"
    else
      skip "kept $src (delete it yourself once you're happy)"
    fi
  fi
}

# The Mac's service account reads ONLY $VAULT. Its token is backed up in
# $ADMIN_VAULT/op-service-account/token, so a lost /etc/op/token is restored
# from there instead of minting a second service account.
init_service_account() {
  local tok inst backed_up=1
  if sudo /bin/test -e "$TOKEN_FILE"; then
    skip "$TOKEN_FILE already present"
    return 0
  fi
  inst="$(bin install)"
  if field_set "$ADMIN_VAULT" op-service-account token; then
    tok="$(op_get "$ADMIN_VAULT/op-service-account/token")"
    say "reusing the service-account token backed up in $ADMIN_VAULT/op-service-account (no new service account)"
  else
    tok="$(op service-account create paseo-agent-mac --vault "$VAULT:read_items" --raw)" ||
      die "could not create service account paseo-agent-mac"
    [ -n "$tok" ] || die "op service-account create returned no token"
    say "created service account paseo-agent-mac (read_items on $VAULT only; no access to $ADMIN_VAULT)"
    # Back it up IMMEDIATELY. If that fails, still write /etc/op/token below so
    # the one-time token isn't lost, then stop loudly.
    if ! (OP_VALUE="$tok" op_put "$ADMIN_VAULT" op-service-account token CONCEALED); then
      backed_up=0
    fi
  fi
  if ! sudo /bin/test -d /etc/op; then
    sudo "$inst" -d -m 0700 -o root -g wheel /etc/op
    say "created /etc/op (root 0700)"
  fi
  printf '%s' "$tok" | sudo "$inst" -m 0600 -o root -g wheel /dev/stdin "$TOKEN_FILE"
  tok=""
  say "wrote $TOKEN_FILE (root 0600)"
  [ "$backed_up" = 1 ] ||
    die "backing the new token up to $ADMIN_VAULT/op-service-account/token FAILED; it exists only in $TOKEN_FILE — store it in 1Password by hand before anything else"
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

  ensure_vault "$VAULT"
  ensure_vault "$ADMIN_VAULT"
  load_items "$VAULT"
  load_items "$ADMIN_VAULT"

  # Rendered onto the Mac (vault the service account reads).
  init_ssh_key "$ssh_key"
  prompt_field "$VAULT" github-bot username STRING "the bot's GitHub login"
  prompt_field "$VAULT" github-bot email STRING "the bot's commit email (its GitHub noreply address is fine)"
  prompt_field "$VAULT" github-bot token CONCEALED "bot classic PAT, repo scope only, no workflow"
  prompt_field "$VAULT" claude oauth_token CONCEALED "\`claude setup-token\` output (run it as any user, paste the token)"
  if field_set "$VAULT" kubeconfig kubeconfig; then
    skip "$VAULT/kubeconfig/kubeconfig already in 1Password"
  else
    say "$VAULT/kubeconfig/kubeconfig missing: run 'paseo-agent-setup kubeconfig' (builds it from the cluster's paseo-agent-token)"
  fi

  # Script-only (admin vault; never rendered, the service account can't read it).
  prompt_field "$ADMIN_VAULT" hetzner k8s_readonly_token CONCEALED "Hetzner Cloud console > k8s project > Security > API tokens, Read-only"
  prompt_field "$ADMIN_VAULT" hetzner atni_readonly_token CONCEALED "Hetzner Cloud console > atni project > Security > API tokens, Read-only"
  prompt_field "$ADMIN_VAULT" hub dispatch_key CONCEALED "Hub > Settings > API keys: a key with ONLY runs:dispatch ticked (goes to AWS Secrets Manager)"
  prompt_field "$ADMIN_VAULT" hub admin_key CONCEALED "Hub > Settings > API keys: a key with ONLY configuration:install + configuration:validate ticked (mattias-side deploy/listing only)"
  prompt_field "$ADMIN_VAULT" hub enroll_key CONCEALED "Hub > Settings > API keys: a key with ONLY daemons:enroll ticked (handed to the agent once by hub-connect; revoke it afterwards)"

  init_service_account
  say "next: make switch NIXNAME=macbook-m1   # renders the agent's secrets from 1Password"
}

# ---------------------------------------------------------------------------
# github
# ---------------------------------------------------------------------------
ensure_protect_mattias() {
  local existing
  existing="$(gh api "repos/$GH_OWNER/nixos-config/rulesets" --paginate \
    --jq '.[] | select(.name == "protect-mattias") | .id')" ||
    die "could not list rulesets on $GH_OWNER/nixos-config; not inviting the bot"
  if [ -n "$existing" ]; then
    skip "ruleset protect-mattias already exists on $GH_OWNER/nixos-config (id $existing)"
    return 0
  fi
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
    }' | gh api -X POST "repos/$GH_OWNER/nixos-config/rulesets" --input - --silent ||
    die "creating ruleset protect-mattias on $GH_OWNER/nixos-config failed; not inviting the bot"
  say "created ruleset protect-mattias on $GH_OWNER/nixos-config (refs/heads/mattias: 1 approval, no deletion, no force-push; admins bypass)"
}

# Transparency only (accepted risk): private repos on GitHub Free can't have
# branch protection, so the bot can push to their default branch.
warn_unprotected() { # REPO
  local branch n
  branch="$(gh api "repos/$GH_OWNER/$1" --jq .default_branch 2>/dev/null || true)"
  [ -n "$branch" ] || branch=main
  n="$(gh api "repos/$GH_OWNER/$1/rules/branches/$branch" \
    --jq '[.[] | select(.type == "pull_request")] | length' 2>/dev/null || true)"
  case $n in '' | *[!0-9]*) n=0 ;; esac
  if [ "$n" = 0 ]; then
    printf '%s\n' "WARNING: $1 $branch has no branch protection (GitHub Free) — the bot can push to it directly. Accepted risk; see wiki \"Security recommendations\" #3."
  fi
}

cmd_github() {
  local repos=(k8s-config nixos-config ansible) private=(k8s-config ansible)
  while [ $# -gt 0 ]; do
    case $1 in
      --infrastructure) repos+=(infrastructure); private+=(infrastructure); shift ;;
      *) die "github: unknown argument $1" ;;
    esac
  done
  require_op
  local bot bot_token login r invites id name n=0
  bot="$(op_get "$VAULT/github-bot/username")"
  bot_token="$(op_get "$VAULT/github-bot/token")"
  login="$(GH_TOKEN="$bot_token" gh api /user --jq .login)" ||
    die "GitHub rejected github-bot/token"
  [ "$login" = "$bot" ] || die "github-bot/token belongs to '$login', not '$bot'"

  # Protect nixos-config's mattias branch BEFORE the bot gets push access.
  ensure_protect_mattias

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
  bot_token=""

  for r in "${private[@]}"; do
    warn_unprotected "$r"
  done
}

# ---------------------------------------------------------------------------
# secrets
# ---------------------------------------------------------------------------
cmd_secrets() {
  require_op
  local v cur
  v="$(op_get "$ADMIN_VAULT/hetzner/k8s_readonly_token")"
  printf '%s' "$v" | gh secret set HCLOUD_TOKEN_READONLY -R "$GH_OWNER/infrastructure"
  say "GitHub: set HCLOUD_TOKEN_READONLY on $GH_OWNER/infrastructure (always re-set: Actions secrets can't be read back to compare)"
  v="$(op_get "$ADMIN_VAULT/hetzner/atni_readonly_token")"
  printf '%s' "$v" | gh secret set HCLOUD_TOKEN_ATNI_READONLY -R "$GH_OWNER/infrastructure"
  say "GitHub: set HCLOUD_TOKEN_ATNI_READONLY on $GH_OWNER/infrastructure"

  aws sts get-caller-identity >/dev/null 2>&1 ||
    die "AWS credentials don't work — run 'aws login' and re-run 'paseo-agent-setup secrets'"
  v="$(op_get "$ADMIN_VAULT/hub/dispatch_key")"
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
  load_items "$VAULT"
  local token ca cfg cur want got
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
  if field_set "$VAULT" kubeconfig kubeconfig; then
    cur="$(op_get "$VAULT/kubeconfig/kubeconfig")"
  fi
  if [ "$cur" = "$cfg" ]; then
    skip "1Password $VAULT/kubeconfig/kubeconfig is already current"
  else
    OP_VALUE="$cfg" op_put "$VAULT" kubeconfig kubeconfig CONCEALED
    # Round-trip: what op-secrets will render must be byte-for-byte what we built.
    want="$(printf '%s' "$cfg" | sha256sum | cut -d' ' -f1)"
    got="$(op read --no-newline "op://$VAULT/kubeconfig/kubeconfig" | sha256sum | cut -d' ' -f1)" ||
      die "kubeconfig: could not read op://$VAULT/kubeconfig/kubeconfig back"
    [ "$want" = "$got" ] ||
      die "kubeconfig: 1Password round-trip MISMATCH (sha256 built $want, stored $got) — fix the item before rendering"
    say "kubeconfig: round-trip from 1Password OK (sha256 $want)"
    say "next: make switch NIXNAME=macbook-m1   # renders it to $AGENT_HOME/.kube/config"
  fi
  cfg=""
  cur=""
}

# ---------------------------------------------------------------------------
# hub-connect
# ---------------------------------------------------------------------------
# hub_state FIELD — read the agent daemon's Hub status AS THE AGENT, no key.
hub_state() {
  agent "$PASEO" hub status --json --home "$AGENT_HOME/.paseo" 2>/dev/null |
    jq -r "(if type == \"array\" then .[0] else . end) | .$1 // empty" 2>/dev/null || true
}

cmd_hub_connect() {
  require_op
  load_items "$ADMIN_VAULT"
  local enroll_key admin_key state daemon_id slug
  state="$(hub_state state)"
  case $state in
    connected | connecting | reconnecting)
      skip "agent daemon already enrolled with the Hub (state: $state)"
      ;;
    *)
      # The agent-owned process can read its own environment, so it gets the
      # single-purpose daemons:enroll key and nothing else.
      enroll_key="$(op_get "$ADMIN_VAULT/hub/enroll_key")"
      PASEO_HUB_API_KEY="$enroll_key" agent -e PASEO_HUB_API_KEY \
        "$PASEO" hub connect "$HUB" --permission hub.execute --home "$AGENT_HOME/.paseo"
      enroll_key=""
      say "enrolled the agent daemon with $HUB (permission hub.execute)"
      say "REMINDER: revoke the enroll key now — Hub > Settings > API keys (it was exposed to the agent's process)"
      if yes_no "Blank $ADMIN_VAULT/hub/enroll_key in 1Password now?"; then
        OP_VALUE="" OP_ALLOW_EMPTY=1 op_put "$ADMIN_VAULT" hub enroll_key CONCEALED
      else
        skip "left $ADMIN_VAULT/hub/enroll_key as is"
      fi
      ;;
  esac

  # Daemon listing runs as mattias with the admin key (never in an agent process).
  daemon_id="$(hub_state daemonId)"
  if [ -z "$daemon_id" ]; then
    say "WARNING: 'paseo hub status' reports no daemonId yet; re-run hub-connect in a moment for the slug"
  else
    admin_key="$(op_get "$ADMIN_VAULT/hub/admin_key")"
    slug="$(printf 'Authorization: Bearer %s\n' "$admin_key" |
      curl -fsS -H @- "$HUB/api/v1/configuration-resources" |
      jq -r --arg id "$daemon_id" '.daemons[]? | select(.id == $id) | .slug')" ||
      die "could not list Hub configuration resources"
    admin_key=""
    if [ -n "$slug" ]; then
      say "Hub daemon slug for the agent: $slug (id $daemon_id)"
    else
      say "WARNING: daemon $daemon_id not found in the Hub's configuration resources"
    fi
  fi
  say "Pair your phone: sudo -iu paseo-agent /Applications/Paseo.app/Contents/Resources/bin/paseo pair"
}

# ---------------------------------------------------------------------------
# deploy-trigger — entirely as mattias, from a fresh clone of origin/main
# (never the agent's checkout: the agent controls its working tree and refs).
# ---------------------------------------------------------------------------
cmd_deploy_trigger() {
  require_op
  local src="$WORK/k8s-config" sha admin_key
  gh repo clone "$GH_OWNER/k8s-config" "$src" -- --depth 1 --branch main --quiet ||
    die "could not clone $GH_OWNER/k8s-config@main with your gh auth"
  sha="$(git -C "$src" rev-parse HEAD)"
  say "cloned $GH_OWNER/k8s-config@main ($sha) into a private temp dir"
  [ -d "$src/.paseo/triggers" ] ||
    die "$GH_OWNER/k8s-config@main has no .paseo/triggers/ yet — merge the k8s-config trigger PR first"

  admin_key="$(op_get "$ADMIN_VAULT/hub/admin_key")"
  (cd "$src" && PASEO_HUB_API_KEY="$admin_key" "$PASEO" hub deploy --hub "$HUB" --dry-run)
  say "dry-run OK; deploying"
  (cd "$src" && PASEO_HUB_API_KEY="$admin_key" "$PASEO" hub deploy --hub "$HUB")
  admin_key=""
  say "deployed $GH_OWNER/k8s-config@$sha (.paseo/triggers) to $HUB"
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
VERIFY_ROWS=()
VERIFY_FAILS=0
record() { # PASS|FAIL|SKIP DESCRIPTION (SKIP doesn't count as a failure)
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

  # (b) the agent can't read the admin kubeconfig (only meaningful if it exists)
  if [ ! -e "$ADMIN_HOME/.kube/config" ]; then
    record SKIP "$ADMIN_HOME/.kube/config does not exist; can't test that the agent is denied"
  elif agent /bin/cat "$ADMIN_HOME/.kube/config" >/dev/null 2>&1; then
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
    # server until something connects). PASS only on sshd's policy refusal,
    # "administratively prohibited". Anything else — a remote banner (forwarding
    # works), "connect failed"/"Connection refused" (forwarding was allowed,
    # the target just wasn't listening), no connection — is FAIL, raw output shown.
    out="$(agent "$timeout_bin" 20 "$ssh_bin" -o ConnectTimeout=10 -o ExitOnForwardFailure=yes \
      -W localhost:22 "$h" </dev/null 2>&1 | head -c 4096 || true)"
    if [[ $out == *"administratively prohibited"* ]]; then
      record PASS "$h: TCP forwarding refused (administratively prohibited)"
    else
      out="${out//$'\r'/}"
      out="${out//$'\n'/ | }"
      record FAIL "$h: TCP forwarding NOT refused by policy; ssh said: '${out:0:200}'"
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

  init [--ssh-key PATH]      create the paseo-agent + paseo-agent-admin vaults and items (prompts for
                             missing values), store the agent SSH key, write /etc/op/token for make switch
  github [--infrastructure]  protect-mattias ruleset on nixos-config, then invite + accept the bot on the repos
  secrets                    Hetzner read-only tokens -> GitHub secrets; Hub dispatch key -> AWS Secrets Manager
  reconcile                  flux reconcile flux-system, paseo, prometheus-csp, prometheus; list paseo pods
  kubeconfig                 build the agent's read-only kubeconfig from the cluster and store it in 1Password
  hub-connect                enroll the agent daemon with the Hub (enroll-only key) and print its daemon slug
  deploy-trigger             as you: fresh clone of k8s-config@main, paseo hub deploy --dry-run, then deploy
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

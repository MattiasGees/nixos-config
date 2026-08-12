#!/usr/bin/env bash
#
# migrate-miniflux.sh — one-shot migration of Miniflux data from the Hetzner
# Kubernetes cluster to polaris.
#
# Run from a workstation that has BOTH:
#   - the hetzner kubectl context active (`kubectl get pods -n miniflux` works)
#   - SSH access to polaris ($POLARIS_HOST)
#
# Prerequisites (must be done first — see design doc §6):
#   1. /etc/miniflux/admin.env placed on polaris (design doc §7).
#   2. `make switch NIXNAME=polaris` deployed — miniflux is up (empty) on polaris.
#
# Flow: count source -> scale k8s to 0 -> pg_dump (custom fmt) streamed to
#       /tmp/miniflux.dump on polaris -> stop/drop/create/restore/start ->
#       re-count -> PASS/FAIL on row-count equality.
#
# Rollback: kubectl scale deploy/miniflux -n miniflux --replicas=1
#   (this script never modifies the k8s database).
#
# sudo note: polaris requires a password for sudo, and only
# /run/wrappers/bin/sudo is setuid. The restore runs in one `ssh -t` session so
# the password is typed once (timestamp cached across the sudo calls).

set -euo pipefail

POLARIS_HOST="${POLARIS_HOST:-mattias@192.168.1.50}"
NS="${NS:-miniflux}"
PG_POD="${PG_POD:-miniflux-postgresql-1}"
DEPLOY="${DEPLOY:-miniflux}"
DUMP_REMOTE="${DUMP_REMOTE:-/tmp/miniflux.dump}"
SUDO="/run/wrappers/bin/sudo"

COUNTS_SQL="SELECT (SELECT count(*) FROM feeds) AS feeds, (SELECT count(*) FROM entries) AS entries, (SELECT count(*) FROM users) AS users;"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

trap 'printf "\n\033[1;31mAborted. If the restore was interrupted, roll back with:\n  kubectl scale deploy/%s -n %s --replicas=1\n(the k8s DB is never modified by this script)\033[0m\n" "$DEPLOY" "$NS" >&2' ERR

# --- 1. Pre-flight -----------------------------------------------------------
say "Pre-flight checks"
kubectl get ns "$NS" >/dev/null 2>&1 || die "kubectl cannot see namespace '$NS' (wrong context?)"
kubectl get pod "$PG_POD" -n "$NS" >/dev/null 2>&1 || die "CNPG pod '$PG_POD' not found in '$NS'"
ssh "$POLARIS_HOST" 'systemctl is-enabled miniflux' >/dev/null 2>&1 \
  || die "miniflux not enabled on $POLARIS_HOST — deploy 'make switch NIXNAME=polaris' first"

# --- 2. Count source ---------------------------------------------------------
say "Counting rows on the k8s source"
src_counts=$(kubectl exec -n "$NS" "$PG_POD" -c postgres -- \
  psql -U postgres -d miniflux -At -F'|' -c "$COUNTS_SQL")
echo "source feeds|entries|users = $src_counts"

# --- 3. Freeze source --------------------------------------------------------
say "Scaling k8s deployment '$DEPLOY' to 0"
kubectl scale deploy/"$DEPLOY" -n "$NS" --replicas=0
kubectl wait --for=delete pod -l app="$DEPLOY" -n "$NS" --timeout=120s || true

# --- 4. Transfer dump (no sudo) ---------------------------------------------
say "Dumping k8s DB -> $POLARIS_HOST:$DUMP_REMOTE"
kubectl exec -n "$NS" "$PG_POD" -c postgres -- \
  pg_dump -U postgres -Fc miniflux \
  | ssh "$POLARIS_HOST" "cat > '$DUMP_REMOTE'"
ssh "$POLARIS_HOST" "test -s '$DUMP_REMOTE'" || die "dump file is empty on polaris"

# --- 5. Restore + verify (interactive; one sudo password) --------------------
say "Restoring on polaris (you will be prompted for your sudo password)"
dst_counts=$(ssh -t "$POLARIS_HOST" "
  set -e
  $SUDO systemctl stop miniflux
  $SUDO -u postgres dropdb --if-exists --force miniflux
  $SUDO -u postgres createdb -O miniflux miniflux
  $SUDO -u postgres pg_restore --no-owner --role=miniflux -d miniflux '$DUMP_REMOTE'
  $SUDO systemctl start miniflux
  printf 'COUNTS:'
  $SUDO -u postgres psql -d miniflux -At -F'|' -c \"$COUNTS_SQL\"
" | tee /dev/tty | tr -d '\r' | sed -n 's/^COUNTS://p')
echo "polaris feeds|entries|users = $dst_counts"

# --- 6. Cleanup + report -----------------------------------------------------
ssh "$POLARIS_HOST" "rm -f '$DUMP_REMOTE'" || true

say "Result"
echo "  source : $src_counts"
echo "  polaris: $dst_counts"
if [[ -n "$dst_counts" && "$src_counts" == "$dst_counts" ]]; then
  printf '\033[1;32mPASS — row counts match.\033[0m\n'
  echo "Log in at https://miniflux.polaris.mattiasgees.be as 'mattias' and trigger a feed refresh."
  echo "Leave k8s at replicas=0 as the rollback net."
else
  printf '\033[1;31mFAIL — counts differ or empty. Investigate before decommissioning k8s.\033[0m\n'
  echo "Rollback: kubectl scale deploy/$DEPLOY -n $NS --replicas=1"
  exit 1
fi

#!/usr/bin/env bash
#
# migrate-karakeep.sh — one-shot migration of Karakeep data (SQLite DB + assets)
# from the Hetzner Kubernetes cluster to polaris.
#
# Run from a workstation that has BOTH:
#   - the hetzner kubectl context active (`kubectl get pods -n karakeep` works)
#   - SSH access to polaris ($POLARIS_HOST)
#
# Prerequisites (must be done first — see docs/polaris/karakeep-migration-runbook.md):
#   1. Storage for /var/lib/karakeep provisioned on the fast pool, the OpenAI key
#      placed at /etc/karakeep/karakeep.env, and `make switch NIXNAME=polaris`
#      deployed — karakeep is up (empty) on polaris.
#
# Unlike miniflux this is a FILE migration, not a pg_dump: Karakeep is SQLite-only,
# so we tar the DATA_DIR (db.db + assets/) out of the k8s data-pvc and unpack it on
# polaris, keeping the module-generated settings.env in place.
#
# Flow: freeze k8s (scale web->0) -> temp pod mounts the PVC -> count source ->
#       tar /data streamed to polaris -> stop/unpack/chown/re-init/start ->
#       re-count -> PASS/FAIL on bookmark-count equality. Then reindex Meilisearch
#       in the UI (not scriptable — needs an authed admin action).
#
# Rollback: kubectl scale deploy/web -n karakeep --replicas=1
#   (the PVC is mounted read-only; this script never modifies the k8s data).
#
# sudo note: polaris requires a password for sudo, and only
# /run/wrappers/bin/sudo is setuid. The unpack runs in one `ssh -t` session so the
# password is typed once (timestamp cached across the sudo calls).

set -euo pipefail

POLARIS_HOST="${POLARIS_HOST:-mattias@192.168.1.50}"
NS="${NS:-karakeep}"
DEPLOY="${DEPLOY:-web}"
PVC="${PVC:-data-pvc}"
MIGRATE_POD="${MIGRATE_POD:-karakeep-migrate}"
TAR_REMOTE="${TAR_REMOTE:-/tmp/karakeep-data.tar}"
DATA_DIR="${DATA_DIR:-/var/lib/karakeep}"
SUDO="/run/wrappers/bin/sudo"

COUNT_SQL="select count(*) from bookmarks;"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

cleanup_pod() { kubectl delete pod "$MIGRATE_POD" -n "$NS" --ignore-not-found >/dev/null 2>&1 || true; }
trap 'cleanup_pod; printf "\n\033[1;31mAborted. Roll back the k8s side with:\n  kubectl scale deploy/%s -n %s --replicas=1\n(the PVC was mounted read-only; this script never modifies the k8s data)\033[0m\n" "$DEPLOY" "$NS" >&2' ERR

# --- 1. Pre-flight -----------------------------------------------------------
say "Pre-flight checks"
kubectl get ns "$NS" >/dev/null 2>&1 || die "kubectl cannot see namespace '$NS' (wrong context?)"
kubectl get deploy "$DEPLOY" -n "$NS" >/dev/null 2>&1 || die "deployment '$DEPLOY' not found in '$NS'"
kubectl get pvc "$PVC" -n "$NS" >/dev/null 2>&1 || die "PVC '$PVC' not found in '$NS'"
ssh "$POLARIS_HOST" 'systemctl is-enabled karakeep-web' >/dev/null 2>&1 \
  || die "karakeep not enabled on $POLARIS_HOST — deploy 'make switch NIXNAME=polaris' first"
ssh "$POLARIS_HOST" "findmnt -no SOURCE '$DATA_DIR'" >/dev/null 2>&1 \
  || die "$DATA_DIR is not a mountpoint on polaris — the fast-pool storage/bind is not set up"

# --- 2. Freeze source --------------------------------------------------------
say "Scaling k8s deployment '$DEPLOY' to 0 (closes the SQLite DB cleanly)"
kubectl scale deploy/"$DEPLOY" -n "$NS" --replicas=0
kubectl rollout status deploy/"$DEPLOY" -n "$NS" --timeout=120s || true
kubectl wait --for=delete pod -l app=karakeep-web -n "$NS" --timeout=120s || true

# --- 3. Temp pod mounting the PVC read-only ----------------------------------
say "Starting temp pod '$MIGRATE_POD' to read the PVC"
cleanup_pod
kubectl apply -n "$NS" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${MIGRATE_POD}
spec:
  restartPolicy: Never
  containers:
  - name: shell
    image: alpine:3
    command: ["sleep", "3600"]
    volumeMounts:
    - { name: data, mountPath: /data, readOnly: true }
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${PVC}
EOF
kubectl wait --for=condition=Ready pod/"$MIGRATE_POD" -n "$NS" --timeout=120s

# --- 4. Count source ---------------------------------------------------------
say "Counting bookmarks on the k8s source"
src_count=$(kubectl exec -n "$NS" "$MIGRATE_POD" -- sh -c \
  "apk add --no-cache sqlite >/dev/null 2>&1 && sqlite3 'file:/data/db.db?mode=ro&immutable=1' '$COUNT_SQL'")
echo "source bookmarks = $src_count"
[[ "$src_count" =~ ^[0-9]+$ ]] || die "could not read a numeric bookmark count from the source"

# --- 5. Transfer the data dir (db.db + assets) -------------------------------
say "Tarring /data -> $POLARIS_HOST:$TAR_REMOTE"
kubectl exec -n "$NS" "$MIGRATE_POD" -- tar -C /data -cf - . \
  | ssh "$POLARIS_HOST" "cat > '$TAR_REMOTE'"
ssh "$POLARIS_HOST" "test -s '$TAR_REMOTE'" || die "tarball is empty on polaris"

# --- 6. Unpack + re-init + start (interactive; one sudo password) ------------
say "Loading data on polaris (you will be prompted for your sudo password)"
dst_count=$(ssh -t "$POLARIS_HOST" "
  set -e
  $SUDO systemctl stop karakeep-web karakeep-workers karakeep-browser
  # Unpack over DATA_DIR: overwrites db.db, merges assets/, keeps settings.env.
  $SUDO tar -C '$DATA_DIR' -xf '$TAR_REMOTE'
  $SUDO chown -R karakeep:karakeep '$DATA_DIR'
  printf 'COUNT:'
  $SUDO sqlite3 '$DATA_DIR/db.db' '$COUNT_SQL'
  $SUDO systemctl restart karakeep-init          # drizzle migrate: no-op, schema already current
  $SUDO systemctl start karakeep-workers karakeep-web
" | tee /dev/tty | tr -d '\r' | sed -n 's/^COUNT://p')
echo "polaris bookmarks = $dst_count"

# --- 7. Cleanup --------------------------------------------------------------
cleanup_pod
ssh "$POLARIS_HOST" "rm -f '$TAR_REMOTE'" || true

# --- 8. Report ---------------------------------------------------------------
say "Result"
echo "  source : $src_count"
echo "  polaris: $dst_count"
if [[ -n "$dst_count" && "$src_count" == "$dst_count" ]]; then
  printf '\033[1;32mPASS — bookmark counts match.\033[0m\n'
  echo "Next (manual):"
  echo "  1. Log in at https://karakeep.polaris.mattiasgees.be (one fresh login — NEXTAUTH_SECRET was regenerated)."
  echo "  2. Admin -> 'Reindex all bookmarks' to rebuild the local Meilisearch index (the k8s index is not migrated)."
  echo "  3. Spot-check: open a bookmark (asset renders) and search for a known one."
  echo "Leave k8s at replicas=0 as the rollback net until you're satisfied."
else
  printf '\033[1;31mFAIL — counts differ or empty. Investigate before decommissioning k8s.\033[0m\n'
  echo "Rollback: kubectl scale deploy/$DEPLOY -n $NS --replicas=1"
  exit 1
fi

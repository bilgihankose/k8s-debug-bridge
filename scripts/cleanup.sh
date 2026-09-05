#!/usr/bin/env bash
# Restores the original Service selector, deletes the bridge pod, cleans up state files and
# the lock annotation on the cluster.
# Uses only bash + kubectl/oc — python3/jq not required.
# Usage: cleanup.sh <namespace> <service>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-kube-cli.sh
source "$SCRIPT_DIR/lib-kube-cli.sh"

NAMESPACE="${1:?namespace required}"
SERVICE="${2:?service name required}"

ANNOTATION_OWNER="k8s-debug-bridge/owner"
ANNOTATION_SELECTOR="k8s-debug-bridge/original-selector"

STATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/.state"
ENV_FILE="$STATE_DIR/${NAMESPACE}-${SERVICE}.env"
SELECTOR_FILE="$STATE_DIR/${NAMESPACE}-${SERVICE}.selector"
PID_FILE="$STATE_DIR/${NAMESPACE}-${SERVICE}.pid"

# Local state is used ONLY if both files are intact (bridge-up.sh might have been interrupted
# halfway, or one might have been manually deleted) — otherwise fallback to annotation,
# do not crash with a source/redirect error because "one exists and the other doesn't".
if [ -f "$ENV_FILE" ] && [ -s "$SELECTOR_FILE" ]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  SELECTOR_SOURCE="file"
else
  # Try the annotation on the cluster as a recovery path — local state might be missing/
  # lost (another machine, deleted .state, interrupted bridge-up.sh).
  ANNOTATED_SELECTOR=$("$KUBE_CLI" get service "$SERVICE" -n "$NAMESPACE" \
    -o jsonpath="{.metadata.annotations['${ANNOTATION_SELECTOR}']}" 2>/dev/null || true)
  if [ -z "$ANNOTATED_SELECTOR" ]; then
    ui_hint "State file (complete) and annotation not found — might have already been cleaned up."
    exit 0
  fi
  ui_warn "WARNING: local state is missing/absent but annotation found on cluster, restoring from it."
  SELECTOR_SOURCE="annotation"
fi

# convert original_selector from key=value lines to JSON (without using python3/jq).
# `|| [ -n "$key" ]` makes this robust even if the input's last line has no
# trailing newline (plain `while read` silently drops that last line otherwise —
# a real bug we hit once already; don't rely on every caller adding \n for us).
build_selector_json() {
  local json="{" first=1 key val
  while IFS='=' read -r key val || [ -n "$key" ]; do
    [ -z "$key" ] && continue
    if [ "$first" -eq 1 ]; then first=0; else json="${json},"; fi
    json="${json}\"${key}\":\"${val}\""
  done
  json="${json}}"
  printf '%s' "$json"
}

if [ "$SELECTOR_SOURCE" = "annotation" ]; then
  # Trailing \n matters: without it, a `while read` loop silently drops the last
  # key=value pair on some bash versions when the final line has no newline.
  SELECTOR_JSON=$(printf '%s\n' "$ANNOTATED_SELECTOR" | tr ',' '\n' | build_selector_json)
else
  SELECTOR_JSON=$(build_selector_json < "$SELECTOR_FILE")
fi

ui_step "Restoring service selector: $SERVICE -> $SELECTOR_JSON"
"$KUBE_CLI" patch service "$SERVICE" -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/selector\",\"value\":$SELECTOR_JSON}]"

if [ "$SELECTOR_SOURCE" = "file" ]; then
  ui_step "Deleting bridge pod: $BRIDGE_POD"
  "$KUBE_CLI" delete pod "$BRIDGE_POD" -n "$NAMESPACE" --ignore-not-found
else
  # Bridge pod name was not in local state (recovery from annotation) — pods created by
  # this script always carry the "debug" label, we find it from there.
  ui_step "Bridge pod name was not in local state, searching by 'debug' label..."
  ORPHAN_PODS=$("$KUBE_CLI" get pods -n "$NAMESPACE" -l 'debug' -o name 2>/dev/null || true)
  if [ -n "$ORPHAN_PODS" ]; then
    echo "$ORPHAN_PODS" | xargs -r "$KUBE_CLI" delete -n "$NAMESPACE" --ignore-not-found
  else
    ui_info "No pod with 'debug' label found, nothing to delete."
  fi
fi

ui_step "Removing lock annotation on the cluster..."
"$KUBE_CLI" annotate service "$SERVICE" -n "$NAMESPACE" "${ANNOTATION_OWNER}-" "${ANNOTATION_SELECTOR}-" 2>/dev/null || true

if [ -f "$PID_FILE" ]; then
  TUNNEL_PID=$(cat "$PID_FILE" 2>/dev/null || true)
  if [ -n "$TUNNEL_PID" ] && [ "$TUNNEL_PID" != "$$" ]; then
    ui_step "Terminating local tunnel process (PID: $TUNNEL_PID)..."
    kill -TERM "$TUNNEL_PID" 2>/dev/null || true
  fi
fi

# Match the leftover `kubectl/oc exec -i <pod> -n <ns> ... nc -l -p <port>` that tunnel.sh
# spawns per connection. Keyed on the exec target rather than on the listener tool on purpose:
# a pattern tied to whichever helper the tunnel happens to use goes stale the moment that
# changes, and a silently no-op cleanup is worse than a loud failure. BRIDGE_POD only exists
# on the local-state path; on the annotation-recovery path fall back to the namespace.
if [ -n "${BRIDGE_POD:-}" ]; then
  TUNNEL_PATTERN="exec -i ${BRIDGE_POD} -n ${NAMESPACE}"
else
  TUNNEL_PATTERN="exec -i .* -n ${NAMESPACE} .*nc -l -p"
fi
# pkill is a convenience sweep for stragglers; the PID file above is the primary mechanism.
# Git Bash on Windows has no pkill, so treat it as optional rather than required.
if command -v pkill >/dev/null 2>&1; then
  ui_step "Killing local tunnel processes..."
  pkill -f "$TUNNEL_PATTERN" 2>/dev/null || true
else
  ui_note "NOTE: 'pkill' not available; skipped the leftover-process sweep."
  ui_note "      If a tunnel process lingers, stop it manually (its command line contains: $TUNNEL_PATTERN)."
fi

rm -f "$ENV_FILE" "$SELECTOR_FILE" "$PID_FILE"
ui_ok "Cleanup complete. Service reverted to normal."

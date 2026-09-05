#!/usr/bin/env bash
# Validates the environment before starting bridge setup: is there a login, does the namespace/service
# actually exist. Does not change anything, only reads — to prevent crashing in the middle of
# bridge-up.sh due to blind name guessing.
#
# Usage:
#   check-env.sh                    -> login status + available namespaces
#   check-env.sh <namespace>        -> + services in that namespace (including port)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-kube-cli.sh
source "$SCRIPT_DIR/lib-kube-cli.sh"

ui_head "== CLI =="
ui_info "Used: $KUBE_CLI"

echo ""
ui_head "== Login status =="
if [ "$KUBE_CLI" = "oc" ]; then
  if WHOAMI=$("$KUBE_CLI" whoami 2>&1); then
    ui_ok "Login OK: $WHOAMI"
  else
    ui_err "ERROR: you are not logged in. Run 'oc login <cluster-url>' first."
    exit 1
  fi
else
  if CTX=$(kubectl config current-context 2>&1); then
    ui_info "Active context: $CTX"
  else
    ui_err "ERROR: kubectl context not found. Run 'kubectl config use-context <cluster>' first."
    exit 1
  fi
  if ! kubectl get ns >/dev/null 2>&1; then
    ui_err "ERROR: cluster is inaccessible (permission or connection issue). Run 'kubectl get ns' and inspect the error."
    exit 1
  fi
  ui_ok "Cluster access OK."
fi

echo ""
ui_head "== Available namespaces =="
if [ "$KUBE_CLI" = "oc" ]; then
  "$KUBE_CLI" get projects -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null \
    || ui_info "(you don't have permission to list namespaces, but you can try a specific namespace)"
else
  "$KUBE_CLI" get ns -o custom-columns=NAME:.metadata.name --no-headers 2>/dev/null \
    || ui_info "(you don't have permission to list namespaces, but you can try a specific namespace)"
fi

NAMESPACE="${1:-}"
if [ -z "$NAMESPACE" ]; then
  echo ""
  ui_info "To see services in a specific namespace: $0 <namespace>"
  exit 0
fi

echo ""
ui_head "== Checking if namespace '$NAMESPACE' exists =="
if ! "$KUBE_CLI" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  ui_err "ERROR: namespace '$NAMESPACE' not found or access denied."
  exit 1
fi

echo ""
ui_head "== Services in '$NAMESPACE' (name + port + targetPort) =="
ui_note "IMPORTANT: use TARGETPORT (not PORT) as the <port> argument for bridge-up.sh/"
ui_note "tunnel.sh — kube-proxy forwards traffic to the pod's targetPort, not the"
ui_note "Service's client-facing port, and not whatever 'free' port you might pick."
ui_note "It is also NOT your debugger's port (Delve 2345, debugpy 5678, node 9229): the"
ui_note "debugger talks to your IDE only and is never bridged."
SERVICE_NAMES=$("$KUBE_CLI" get services -n "$NAMESPACE" \
  -o custom-columns='NAME:.metadata.name,PORT:.spec.ports[*].port,TARGETPORT:.spec.ports[*].targetPort' --no-headers 2>/dev/null || true)
if [ -z "$SERVICE_NAMES" ]; then
  ui_info "(you don't have permission to list services in this namespace or there are no services)"
else
  echo "$SERVICE_NAMES"
  echo ""
  ui_head "== Already bridged ones =="
  ANY_BRIDGED=0
  while read -r SVC_NAME _; do
    [ -z "$SVC_NAME" ] && continue
    OWNER=$("$KUBE_CLI" get service "$SVC_NAME" -n "$NAMESPACE" \
      -o jsonpath="{.metadata.annotations['k8s-debug-bridge/owner']}" 2>/dev/null || true)
    if [ -n "$OWNER" ]; then
      ui_info "  - $SVC_NAME -> $OWNER"
      ANY_BRIDGED=1
    fi
  done <<< "$SERVICE_NAMES"
  [ "$ANY_BRIDGED" -eq 0 ] && ui_info "  (none, none are bridged)"
fi

echo ""
ui_info "Pass one of the NON-bridged names above to scripts/bridge-up.sh as the Service"
ui_info "name — if you try a bridged one, bridge-up.sh will reject it anyway."

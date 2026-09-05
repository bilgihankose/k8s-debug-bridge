#!/usr/bin/env bash
# Creates a bridge pod, saves the original Service selector to both the cluster (annotation,
# so other users can see it) and the local state file.
# Uses only bash + kubectl/oc — python3/jq not required.
# Usage: bridge-up.sh <namespace> <service> <bridge-pod-name> <image> [port]
# [port] should be the target Service's targetPort (see check-env.sh's output) —
# kube-proxy forwards traffic to the pod's targetPort once the selector is
# redirected, not to any arbitrary "free" port. This value is only used for the
# (informational) containerPort field in the pod manifest here; the real
# enforcement happens in tunnel.sh, which must use the same port. Defaults to
# 8000 if not specified.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-kube-cli.sh
source "$SCRIPT_DIR/lib-kube-cli.sh"

NAMESPACE="${1:?namespace required}"
SERVICE="${2:?service name required}"
BRIDGE_NAME="${3:?bridge pod name required (e.g., myuser-debug-bridge)}"
IMAGE="${4:?bridge pod image required (must ship nc, e.g. nicolaka/netshoot)}"
PORT="${5:-8000}"

if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  ui_err "ERROR: Port '$PORT' must be a valid numeric port number (e.g. 8000). Named ports must be mapped to their numeric container port."
  exit 1
fi

ANNOTATION_OWNER="k8s-debug-bridge/owner"
ANNOTATION_SELECTOR="k8s-debug-bridge/original-selector"

STATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/.state"
mkdir -p "$STATE_DIR"
ENV_FILE="$STATE_DIR/${NAMESPACE}-${SERVICE}.env"
SELECTOR_FILE="$STATE_DIR/${NAMESPACE}-${SERVICE}.selector"

if [ -f "$ENV_FILE" ]; then
  ui_warn "WARNING: $ENV_FILE already exists. A previous bridge session might not have been cleaned up."
  ui_hint "Run cleanup.sh first, then try again."
  exit 1
fi

# Has someone else (or you, from another machine) already bridged this service?
# There is a small race window between this check and a true "atomic lock" (if two
# people run it at the exact same time), but in practice this almost completely closes it.
EXISTING_OWNER=$("$KUBE_CLI" get service "$SERVICE" -n "$NAMESPACE" \
  -o jsonpath="{.metadata.annotations['${ANNOTATION_OWNER}']}" 2>/dev/null || true)
if [ -n "$EXISTING_OWNER" ]; then
  ui_err "ERROR: service '$SERVICE' already appears to be bridged by someone."
  ui_hint "Owner: $EXISTING_OWNER"
  ui_hint "If this is you and your state is lost, talk to them first and ask them to run cleanup.sh,"
  ui_hint "or manually run: $KUBE_CLI annotate service $SERVICE -n $NAMESPACE ${ANNOTATION_OWNER}- ${ANNOTATION_SELECTOR}-"
  exit 1
fi

ui_step "Saving original selector..."
"$KUBE_CLI" get service "$SERVICE" -n "$NAMESPACE" \
  -o go-template='{{range $k, $v := .spec.selector}}{{$k}}={{$v}}
{{end}}' > "$SELECTOR_FILE" 2>/dev/null || true

if [ ! -s "$SELECTOR_FILE" ]; then
  ui_err "ERROR: selector of service '$SERVICE' could not be read or is empty. Aborting."
  rm -f "$SELECTOR_FILE"
  exit 1
fi

# Write the same information to the cluster as an annotation too — so another user
# (different machine, different local .state) can see that this service is bridged.
OWNER="$(whoami)@$(hostname) $(date -u +%Y-%m-%dT%H:%M:%SZ)"
SELECTOR_CSV=$(paste -sd, "$SELECTOR_FILE")
"$KUBE_CLI" annotate service "$SERVICE" -n "$NAMESPACE" \
  "${ANNOTATION_OWNER}=${OWNER}" \
  "${ANNOTATION_SELECTOR}=${SELECTOR_CSV}" \
  --overwrite

cat > "$ENV_FILE" <<EOF
NAMESPACE=$NAMESPACE
SERVICE=$SERVICE
BRIDGE_POD=$BRIDGE_NAME
EOF
ui_info "State saved: $ENV_FILE (and written to cluster as annotation: $OWNER)"

# The manifest lives in assets/bridge-pod.yaml so it can be adapted to a cluster's
# policies (imagePullSecrets, securityContext, limits) without editing this script.
TEMPLATE="$SCRIPT_DIR/../assets/bridge-pod.yaml"
if [ ! -f "$TEMPLATE" ]; then
  ui_err "ERROR: pod template not found: $TEMPLATE"
  exit 1
fi

sed -e "s|__BRIDGE_NAME__|${BRIDGE_NAME}|g" \
    -e "s|__IMAGE__|${IMAGE}|g" \
    -e "s|__PORT__|${PORT}|g" \
    "$TEMPLATE" | "$KUBE_CLI" apply -n "$NAMESPACE" -f -

ui_step "Bridge pod '$BRIDGE_NAME' created, waiting for it to be ready..."
"$KUBE_CLI" wait --for=condition=Ready "pod/$BRIDGE_NAME" -n "$NAMESPACE" --timeout=60s

# Verify the listener exists BEFORE anyone redirects the Service. tunnel.sh checks this too,
# but by then the selector has already been switched — a missing nc would mean a short real
# outage. Failing here costs nothing: the Service is still untouched.
if ! "$KUBE_CLI" exec "$BRIDGE_NAME" -n "$NAMESPACE" -c debug-bridge -- sh -c 'command -v nc' >/dev/null 2>&1; then
  ui_err "ERROR: image '$IMAGE' does not ship 'nc' — the tunnel cannot work with it."
  ui_hint "The Service has NOT been touched. Delete this pod and retry with an image that has nc"
  ui_hint "(e.g. nicolaka/netshoot, busybox):"
  ui_hint "  $KUBE_CLI delete pod $BRIDGE_NAME -n $NAMESPACE"
  ui_hint "  $KUBE_CLI annotate service $SERVICE -n $NAMESPACE ${ANNOTATION_OWNER}- ${ANNOTATION_SELECTOR}-"
  exit 1
fi

ui_ok "Ready ('nc' found in the bridge pod). redirect-service.sh can now be run."

#!/usr/bin/env bash
# Opens a reverse tunnel between the bridge pod and the local port. It is blocking, should be run
# in a separate terminal/in the background. When Ctrl+C is pressed or terminal closes (EXIT/INT/TERM),
# the trap automatically triggers cleanup.sh.
#
# IMPORTANT design note: we DO NOT do this by connecting two processes using bash's `|` (pipe)
# — a pipe is one-way (A's stdout connects to B's stdin, but B's stdout does not come back to
# A's stdin). In such a design the client in the cluster could never receive the local
# application's response back. What we need is a single DUPLEX channel, and bash gives us one
# for free: `<>"/dev/tcp/host/port"` opens the local socket read-write on stdin, and `>&0`
# points stdout at that very same socket. `kubectl exec -i` then has its stdin and stdout
# wired to one bidirectional TCP connection — no helper tool involved on this side at all.
#
# Consequently the pod side never forks either: one connection is carried at a time (which also
# eliminates the risk of several connections interleaving data over a single stdio), and the
# loop starts a fresh `kubectl exec` for the next one.
#
# Neither side needs socat. Locally, bash's built-in /dev/tcp does the job; inside the pod,
# plain `nc` does. That matters in practice: hardened corporate images routinely strip `socat`
# out while keeping Nmap's `nc`, so requiring socat would rule out exactly the images those
# clusters allow. `nc` has no `reuseaddr` equivalent, so the loop sleeps briefly between
# connections to ride out TIME_WAIT.
#
# Usage: tunnel.sh <namespace> <service> <bridge-pod> <port>
set -euo pipefail

NAMESPACE="${1:?namespace required}"
SERVICE="${2:?service name required}"
BRIDGE_NAME="${3:?bridge pod name required}"
PORT="${4:-8000}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-kube-cli.sh
source "$SCRIPT_DIR/lib-kube-cli.sh"

if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
  ui_err "ERROR: Port '$PORT' must be a valid numeric port number (e.g. 8000)."
  exit 1
fi
CLEANED_UP=0
# Container name inside the bridge pod — must match the name in assets/bridge-pod.yaml.
CONTAINER="debug-bridge"

STATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/.state"
mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/${NAMESPACE}-${SERVICE}.pid"
echo "$$" > "$PID_FILE"

run_cleanup() {
  if [ "$CLEANED_UP" -eq 1 ]; then
    return
  fi
  CLEANED_UP=1
  rm -f "$PID_FILE"
  echo ""
  ui_step "Tunnel closing, triggering automatic cleanup..."
  "$SCRIPT_DIR/cleanup.sh" "$NAMESPACE" "$SERVICE" || ui_warn "WARNING: automatic cleanup failed, run cleanup.sh $NAMESPACE $SERVICE manually."
}
trap run_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! "$KUBE_CLI" exec "$BRIDGE_NAME" -n "$NAMESPACE" -c "$CONTAINER" -- sh -c 'command -v nc' >/dev/null 2>&1; then
  ui_err "ERROR: the bridge pod image does not ship 'nc'."
  ui_hint "Recreate the bridge with an image that has it (e.g. nicolaka/netshoot, busybox)."
  exit 1
fi

# First char bracketed so `pkill -f` cannot match its own `sh -c` command line.
ui_step "Cleaning up a stale listener on the pod side..."
"$KUBE_CLI" exec "$BRIDGE_NAME" -n "$NAMESPACE" -c "$CONTAINER" -- sh -c "pkill -f '[n]c -l -p ${PORT}'" 2>/dev/null || true

ui_ok "Tunnel starting: $BRIDGE_NAME:$PORT <-> 127.0.0.1:$PORT (one connection at a time)"
ui_info "When you close this terminal with Ctrl+C, the service and pod will automatically revert."

# One connection per iteration. The redirections belong to this single command: stdin is the
# local socket opened read-write, stdout is that same socket (fd 0).
carry_one_connection() {
  "$KUBE_CLI" exec -i "$BRIDGE_NAME" -n "$NAMESPACE" -c "$CONTAINER" -- nc -l -p "$PORT" \
    <>"/dev/tcp/127.0.0.1/${PORT}" >&0
}

while true; do
  if carry_one_connection; then
    sleep 0.05
  else
    # Usually means nothing is listening on 127.0.0.1:$PORT yet (local app still building,
    # or an Air/Delve reload released the port). Back off instead of spinning.
    ui_warn "WARNING: could not carry a connection — is your local app listening on 127.0.0.1:${PORT}? Retrying..."
    sleep 1
  fi
done

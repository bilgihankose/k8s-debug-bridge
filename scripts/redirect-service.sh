#!/usr/bin/env bash
# Points the target Service's selector to the bridge pod. The state file must have been
# created previously by bridge-up.sh.
# Usage: redirect-service.sh <namespace> <service> [--yes]
#
# --yes: skips the interactive "yes" confirmation. Use this ONLY if you have already
# obtained confirmation from the user elsewhere (e.g., in an AI agent's chat interface) — this script
# itself should never run without confirmation, --yes only changes WHERE the confirmation
# is obtained. If an agent runs this without --yes and without stdin attached, `read` will
# hang/fail here; agents should therefore use --yes but must first show the user the
# same warning and obtain confirmation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-kube-cli.sh
source "$SCRIPT_DIR/lib-kube-cli.sh"

NAMESPACE="${1:?namespace required}"
SERVICE="${2:?service name required}"
AUTO_YES="${3:-}"

STATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/.state"
ENV_FILE="$STATE_DIR/${NAMESPACE}-${SERVICE}.env"

if [ ! -f "$ENV_FILE" ]; then
  ui_err "ERROR: $ENV_FILE not found. Run bridge-up.sh first (redirect is not done without saving the original selector)."
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

ui_note "!!! ALL traffic to the $SERVICE ($NAMESPACE) service will now go to the $BRIDGE_POD pod."
ui_note "Actual pods will no longer receive traffic via this Service."

if [ "$AUTO_YES" = "--yes" ]; then
  ui_note "(--yes provided, assuming confirmation was obtained elsewhere)"
else
  ui_head "Type 'yes' to continue:"
  read -r CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    ui_note "Cancelled."
    exit 1
  fi
fi

"$KUBE_CLI" patch service "$SERVICE" -n "$NAMESPACE" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/selector\",\"value\":{\"debug\":\"$BRIDGE_POD\"}}]"
ui_ok "Redirected. Use cleanup.sh to revert."

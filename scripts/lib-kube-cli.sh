#!/usr/bin/env bash
# Common: determines which CLI to use. Sourced via `source`, exports KUBE_CLI.
# Priority: KUBE_CLI environment variable > oc if exists > kubectl.
# Exists so the same scripts work on both OpenShift and vanilla Kubernetes.
# Also pulls in lib-ui.sh, so every script that sources this one gets the output
# helpers (ui_err/ui_ok/...) without repeating the source line.

# Resolved with parameter expansion rather than `dirname`, because this file is also
# sourced in environments with a minimal PATH where no external binary is available.
LIB_DIR="${BASH_SOURCE[0]%/*}"
[ "$LIB_DIR" = "${BASH_SOURCE[0]}" ] && LIB_DIR="."
# shellcheck source=lib-ui.sh
source "$LIB_DIR/lib-ui.sh"

if [ -n "${KUBE_CLI:-}" ]; then
  : # user forced it, do not touch
elif command -v oc >/dev/null 2>&1; then
  KUBE_CLI="oc"
elif command -v kubectl >/dev/null 2>&1; then
  KUBE_CLI="kubectl"
else
  ui_err "ERROR: neither 'oc' nor 'kubectl' found in PATH."
  ui_hint "Install one or force it with the KUBE_CLI=oc|kubectl environment variable."
  exit 1
fi

export KUBE_CLI

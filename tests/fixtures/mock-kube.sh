#!/usr/bin/env bash
# Fake kubectl/oc for tests. Invoked as "kubectl" or "oc" (via a symlink/copy with
# that name on PATH, see tests/lib/harness.bash). Every invocation is appended to
# $MOCK_CALL_LOG (one line, args joined by a single space) so tests can assert on
# what was called. Behavior for each subcommand is controlled entirely via
# environment variables, listed next to each case below.
set -euo pipefail

SELF_NAME="$(basename "$0")"

if [ -n "${MOCK_CALL_LOG:-}" ]; then
  printf '%s %s\n' "$SELF_NAME" "$*" >> "$MOCK_CALL_LOG"
fi

# whoami (oc) — MOCK_WHOAMI_EXIT (default 0), MOCK_WHOAMI_OUT (default "test-user")
if [ "${1:-}" = "whoami" ]; then
  echo "${MOCK_WHOAMI_OUT:-test-user}"
  exit "${MOCK_WHOAMI_EXIT:-0}"
fi

# config current-context (kubectl) — MOCK_CTX_EXIT (default 0), MOCK_CTX_OUT
if [ "${1:-}" = "config" ] && [ "${2:-}" = "current-context" ]; then
  echo "${MOCK_CTX_OUT:-test-context}"
  exit "${MOCK_CTX_EXIT:-0}"
fi

# get ns / get projects — MOCK_NS_EXIT (default 0), MOCK_NS_LIST (newline-separated)
if [ "${1:-}" = "get" ] && { [ "${2:-}" = "ns" ] || [ "${2:-}" = "projects" ]; } && [ "${3:-}" != "" ] && [ "${3:-}" != "-n" ]; then
  : # fallthrough, handled by more specific matchers below when a name follows
fi
if [ "${1:-}" = "get" ] && { [ "${2:-}" = "ns" ] || [ "${2:-}" = "projects" ]; }; then
  if [ "${MOCK_NS_EXIT:-0}" -ne 0 ]; then
    exit "${MOCK_NS_EXIT}"
  fi
  printf '%s\n' "${MOCK_NS_LIST:-default}"
  exit 0
fi

# get namespace <name> — MOCK_NS_EXISTS_EXIT (default 0 = exists)
if [ "${1:-}" = "get" ] && [ "${2:-}" = "namespace" ]; then
  exit "${MOCK_NS_EXISTS_EXIT:-0}"
fi

# get services -n <ns> -o custom-columns=... (list) — MOCK_SVC_LIST_EXIT, MOCK_SVC_LIST
if [ "${1:-}" = "get" ] && [ "${2:-}" = "services" ]; then
  exit_code="${MOCK_SVC_LIST_EXIT:-0}"
  if [ "$exit_code" -ne 0 ]; then
    exit "$exit_code"
  fi
  printf '%s\n' "${MOCK_SVC_LIST:-}"
  exit 0
fi

# get pods -n <ns> -l debug -o name — MOCK_ORPHAN_PODS (newline-separated "pod/name"), MOCK_ORPHAN_EXIT
if [ "${1:-}" = "get" ] && [ "${2:-}" = "pods" ]; then
  exit_code="${MOCK_ORPHAN_EXIT:-0}"
  if [ "$exit_code" -ne 0 ]; then
    exit "$exit_code"
  fi
  printf '%s\n' "${MOCK_ORPHAN_PODS:-}"
  exit 0
fi

# get service <name> -n <ns> -o jsonpath=... or -o go-template=...
if [ "${1:-}" = "get" ] && [ "${2:-}" = "service" ]; then
  # find -o value
  output_spec=""
  prev=""
  for arg in "$@"; do
    if [ "$prev" = "-o" ]; then
      output_spec="$arg"
    fi
    prev="$arg"
  done
  case "$output_spec" in
    jsonpath*owner*)
      exit_code="${MOCK_OWNER_EXIT:-0}"
      [ "$exit_code" -ne 0 ] && exit "$exit_code"
      printf '%s' "${MOCK_OWNER_ANNOTATION:-}"
      exit 0
      ;;
    jsonpath*'original-selector'*)
      exit_code="${MOCK_SELECTOR_ANNOTATION_EXIT:-0}"
      [ "$exit_code" -ne 0 ] && exit "$exit_code"
      printf '%s' "${MOCK_SELECTOR_ANNOTATION:-}"
      exit 0
      ;;
    go-template*)
      exit_code="${MOCK_SELECTOR_EXIT:-0}"
      [ "$exit_code" -ne 0 ] && exit "$exit_code"
      printf '%s' "${MOCK_SELECTOR_OUTPUT:-}"
      exit 0
      ;;
    *)
      exit 0
      ;;
  esac
fi

# annotate service ... — MOCK_ANNOTATE_EXIT (default 0)
if [ "${1:-}" = "annotate" ]; then
  exit "${MOCK_ANNOTATE_EXIT:-0}"
fi

# apply -f - (reads manifest from stdin, discards it) — MOCK_APPLY_EXIT (default 0)
if [ "${1:-}" = "apply" ]; then
  cat > /dev/null
  exit "${MOCK_APPLY_EXIT:-0}"
fi

# wait --for=condition=Ready ... — MOCK_WAIT_EXIT (default 0)
if [ "${1:-}" = "wait" ]; then
  exit "${MOCK_WAIT_EXIT:-0}"
fi

# patch service ... — MOCK_PATCH_EXIT (default 0)
if [ "${1:-}" = "patch" ]; then
  exit "${MOCK_PATCH_EXIT:-0}"
fi

# delete pod / delete -n ... (from xargs) — MOCK_DELETE_EXIT (default 0)
if [ "${1:-}" = "delete" ]; then
  exit "${MOCK_DELETE_EXIT:-0}"
fi

# exec <pod> -n <ns> -c <container> -- <cmd...> — MOCK_EXEC_EXIT (default 0)
if [ "${1:-}" = "exec" ]; then
  exit "${MOCK_EXEC_EXIT:-0}"
fi

echo "mock-kube.sh: unhandled invocation: $*" >&2
exit 99

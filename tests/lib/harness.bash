#!/usr/bin/env bash
# Shared bats test helpers. `load` this from each *.bats file:
#   load '../lib/harness'
#
# Provides:
#   setup_project        - copies the real scripts/ dir into a fresh temp dir
#                           ($PROJECT_DIR), so STATE_DIR ends up isolated per test.
#   setup_mock_bins <name...> - puts an executable mock (kubectl and/or oc) on PATH
#                           pointing at tests/fixtures/mock-kube.sh, and sets
#                           MOCK_CALL_LOG to a fresh temp file.
#   teardown_project     - removes $PROJECT_DIR and $MOCK_BIN_DIR.
#
# Every mock behavior is controlled via MOCK_* environment variables — see
# tests/fixtures/mock-kube.sh for the full list.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

setup_project() {
  PROJECT_DIR="$(mktemp -d)"
  cp -R "$REPO_ROOT/scripts" "$PROJECT_DIR/scripts"
  cp -R "$REPO_ROOT/assets" "$PROJECT_DIR/assets"
  chmod +x "$PROJECT_DIR"/scripts/*.sh
}

teardown_project() {
  [ -n "${PROJECT_DIR:-}" ] && rm -rf "$PROJECT_DIR"
  [ -n "${MOCK_BIN_DIR:-}" ] && rm -rf "$MOCK_BIN_DIR"
  return 0
}

setup_mock_bins() {
  MOCK_BIN_DIR="$(mktemp -d)"
  for name in "$@"; do
    ln -sf "$REPO_ROOT/tests/fixtures/mock-kube.sh" "$MOCK_BIN_DIR/$name"
  done
  chmod +x "$MOCK_BIN_DIR"/* 2>/dev/null || true
  export PATH="$MOCK_BIN_DIR:$PATH"
  MOCK_CALL_LOG="$(mktemp)"
  export MOCK_CALL_LOG
}

# Runs a command with a hard wall-clock limit, so a script that regresses into its
# blocking main loop fails the test instead of hanging CI forever. `timeout` is not
# on macOS by default, so perl's alarm does the portable work.
run_with_timeout() {
  local secs="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# Assertion helpers. NOTE: a bare `[[ ... ]]` is a bash *keyword*, and when one fails
# inside a bats test it does not abort that test unless it happens to be the last
# command — the failure is silently swallowed and the test still reports "ok". These
# helpers are ordinary functions, whose non-zero exit bats does catch, so every
# output assertion must go through them rather than through a bare `[[ ]]`.
assert_output_contains() {
  case "$output" in
    *"$1"*) return 0 ;;
  esac
  echo "expected output to contain: $1" >&2
  echo "actual output: $output" >&2
  return 1
}

refute_output_contains() {
  case "$output" in
    *"$1"*)
      echo "expected output NOT to contain: $1" >&2
      echo "actual output: $output" >&2
      return 1
      ;;
  esac
  return 0
}

# assert_contains <needle> <haystack> — same idea for values other than $output.
assert_contains() {
  case "$2" in
    *"$1"*) return 0 ;;
  esac
  echo "expected to contain: $1" >&2
  echo "actual: $2" >&2
  return 1
}

refute_contains() {
  case "$2" in
    *"$1"*)
      echo "expected NOT to contain: $1" >&2
      echo "actual: $2" >&2
      return 1
      ;;
  esac
  return 0
}

# Assert the call log contains a line matching a grep -F pattern.
assert_called() {
  grep -qF -- "$1" "$MOCK_CALL_LOG"
}

# Assert the call log does NOT contain a line matching a grep -F pattern.
refute_called() {
  ! grep -qF -- "$1" "$MOCK_CALL_LOG"
}

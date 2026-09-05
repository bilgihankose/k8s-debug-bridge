#!/usr/bin/env bash
# Terminal styling. Sourced by lib-kube-cli.sh, so every script gets it for free.
#
# Colour and symbols are emitted ONLY when the target stream is a terminal. Piped
# output, CI logs and AI-agent transcripts therefore stay plain ASCII — nothing
# downstream has to strip escape codes, and the bats suite (whose stdout is never a
# TTY) compares against the same strings it always did.
#
# The wording of a message never changes with styling: tests and the agent
# instructions in SKILL.md/AGENTS.md match on the text, styling only wraps it.
#
# Honours the NO_COLOR convention (https://no-color.org) and TERM=dumb.

# ui_is_tty <fd> — split out from ui_styled so tests can stub it: without a stub every
# check would trivially be false under a test runner, and the NO_COLOR/TERM rules below
# would go unverified.
ui_is_tty() {
  case "$1" in
    2) [ -t 2 ] ;;
    *) [ -t 1 ] ;;
  esac
}

# ui_styled <fd> — is styling wanted for this stream?
ui_styled() {
  [ -z "${NO_COLOR:-}" ] || return 1
  [ "${TERM:-dumb}" != "dumb" ] || return 1
  ui_is_tty "$1"
}

# ui_paint <fd> <sgr> <symbol> <text> — writes to stdout; callers redirect if needed.
ui_paint() {
  local fd="$1" sgr="$2" symbol="$3"
  shift 3
  if ui_styled "$fd"; then
    if [ -n "$symbol" ]; then
      printf '\033[%sm%s\033[0m %s\n' "$sgr" "$symbol" "$*"
    else
      printf '\033[%sm%s\033[0m\n' "$sgr" "$*"
    fi
  else
    printf '%s\n' "$*"
  fi
}

# Errors and warnings go to stderr, everything else to stdout.
ui_err()  { ui_paint 2 '1;31' '' "$*" >&2; }   # bold red   — ERROR: ...
ui_warn() { ui_paint 2 '33'   '' "$*" >&2; }   # yellow     — WARNING: ...
ui_hint() { ui_paint 2 '2'    '' "$*" >&2; }   # dim        — what to do about it

ui_head() { ui_paint 1 '1'    '' "$*"; }       # bold       — == Section ==
ui_step() { ui_paint 1 '2'    '▸' "$*"; }      # dim arrow  — doing something
ui_ok()   { ui_paint 1 '32'   '✓' "$*"; }      # green tick — it worked
ui_note() { ui_paint 1 '33'   '' "$*"; }       # yellow     — read this before continuing
ui_info() { printf '%s\n' "$*"; }              # plain

#!/usr/bin/env bats
# Styling must be invisible to anything that is not a human terminal: pipes, CI logs
# and AI-agent transcripts have to keep receiving the exact plain strings the rest of
# the suite (and SKILL.md/AGENTS.md) match on.

load 'lib/harness'

setup() {
  setup_project
  setup_mock_bins kubectl
}

teardown() {
  teardown_project
}

esc=$'\033'

@test "lib-ui.sh: ui_styled says no when the stream is not a TTY" {
  run bash -c "source \"$PROJECT_DIR/scripts/lib-ui.sh\"; ui_styled 1; echo \"rc=\$?\""
  assert_output_contains "rc=1"
}

# The three tests below stub ui_is_tty to true, i.e. they ask: "given a real terminal,
# do the NO_COLOR / TERM rules still switch styling off?" Without the stub they would
# pass no matter what those rules said.
@test "lib-ui.sh: ui_styled says yes on a TTY with a normal TERM" {
  run bash -c "export TERM=xterm; unset NO_COLOR; source \"$PROJECT_DIR/scripts/lib-ui.sh\"; ui_is_tty() { return 0; }; ui_styled 1; echo \"rc=\$?\""
  assert_output_contains "rc=0"
}

@test "lib-ui.sh: ui_styled says no when NO_COLOR is set, even on a TTY" {
  run bash -c "export NO_COLOR=1 TERM=xterm; source \"$PROJECT_DIR/scripts/lib-ui.sh\"; ui_is_tty() { return 0; }; ui_styled 1; echo \"rc=\$?\""
  assert_output_contains "rc=1"
}

@test "lib-ui.sh: ui_styled says no when TERM is dumb, even on a TTY" {
  run bash -c "export TERM=dumb; unset NO_COLOR; source \"$PROJECT_DIR/scripts/lib-ui.sh\"; ui_is_tty() { return 0; }; ui_styled 1; echo \"rc=\$?\""
  assert_output_contains "rc=1"
}

@test "lib-ui.sh: a styled stream does get colour and symbols" {
  run bash -c "export TERM=xterm; unset NO_COLOR; source \"$PROJECT_DIR/scripts/lib-ui.sh\"; ui_is_tty() { return 0; }; ui_ok 'Cluster access OK.'"
  assert_output_contains "$esc"
  assert_output_contains "Cluster access OK."
}

@test "lib-ui.sh: helpers emit the bare message with no escape codes off a TTY" {
  run bash -c "source \"$PROJECT_DIR/scripts/lib-ui.sh\"; ui_ok 'Cluster access OK.'; ui_step 'Saving original selector...'; ui_err 'ERROR: nope'; ui_warn 'WARNING: hm'"
  assert_output_contains "Cluster access OK."
  assert_output_contains "Saving original selector..."
  assert_output_contains "ERROR: nope"
  assert_output_contains "WARNING: hm"
  refute_output_contains "$esc"
  refute_output_contains "✓"
  refute_output_contains "▸"
}

@test "lib-ui.sh: ui_err and ui_warn write to stderr, ui_ok to stdout" {
  run bash -c "source \"$PROJECT_DIR/scripts/lib-ui.sh\"; { ui_err 'ERROR: to stderr'; ui_warn 'WARNING: to stderr'; ui_ok 'to stdout'; } 2>/dev/null"
  assert_output_contains "to stdout"
  refute_output_contains "ERROR: to stderr"
  refute_output_contains "WARNING: to stderr"
}

@test "scripts print no escape codes when stdout is redirected" {
  export MOCK_SELECTOR_OUTPUT="app=auth-service
"
  run "$PROJECT_DIR/scripts/bridge-up.sh" dev auth-service my-bridge nicolaka/netshoot
  [ "$status" -eq 0 ]
  refute_output_contains "$esc"

  run "$PROJECT_DIR/scripts/check-env.sh"
  refute_output_contains "$esc"
}

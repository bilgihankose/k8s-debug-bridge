#!/usr/bin/env bats
# tunnel.sh's main loop (infinite exec over a /dev/tcp socket) has no mockable I/O boundary, so it is
# intentionally left out of unit test coverage — see the coverage note in tests/README.md.

load 'lib/harness'

setup() {
  setup_project
  setup_mock_bins kubectl
}

teardown() {
  teardown_project
}

@test "tunnel.sh: exits early with error when namespace argument is missing" {
  run "$PROJECT_DIR/scripts/tunnel.sh"
  [ "$status" -ne 0 ]
  assert_output_contains "namespace required"
}

@test "tunnel.sh: exits early with error when service argument is missing" {
  run "$PROJECT_DIR/scripts/tunnel.sh" dev
  [ "$status" -ne 0 ]
  assert_output_contains "service name required"
}

@test "tunnel.sh: exits early with error when bridge pod argument is missing" {
  run "$PROJECT_DIR/scripts/tunnel.sh" dev auth-service
  [ "$status" -ne 0 ]
  assert_output_contains "bridge pod name required"
}

@test "tunnel.sh: exits early with error when port is non-numeric" {
  run "$PROJECT_DIR/scripts/tunnel.sh" dev auth-service my-bridge http
  [ "$status" -ne 0 ]
  assert_output_contains "must be a valid numeric port number"
}

@test "tunnel.sh: refuses to open the tunnel when the bridge pod image has no nc" {
  export MOCK_EXEC_EXIT=1
  run run_with_timeout 20 "$PROJECT_DIR/scripts/tunnel.sh" dev auth-service my-bridge 8000
  [ "$status" -eq 1 ]
  assert_output_contains "does not ship 'nc'"
}

@test "tunnel.sh: warns when the port looks like a debugger port" {
  export MOCK_EXEC_EXIT=1
  run run_with_timeout 20 "$PROJECT_DIR/scripts/tunnel.sh" dev auth-service my-bridge 5678
  assert_output_contains "5678 is a well-known debugger port"
}

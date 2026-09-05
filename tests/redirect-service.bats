#!/usr/bin/env bats

load 'lib/harness'

setup() {
  setup_project
  setup_mock_bins kubectl
}

teardown() {
  teardown_project
}

@test "redirect-service.sh: fails with missing namespace argument" {
  run "$PROJECT_DIR/scripts/redirect-service.sh"
  [ "$status" -ne 0 ]
  assert_output_contains "namespace required"
}

@test "redirect-service.sh: fails with missing service argument" {
  run "$PROJECT_DIR/scripts/redirect-service.sh" dev
  [ "$status" -ne 0 ]
  assert_output_contains "service name required"
}

@test "redirect-service.sh: fails when env state file does not exist" {
  run "$PROJECT_DIR/scripts/redirect-service.sh" dev auth-service --yes
  [ "$status" -eq 1 ]
  assert_output_contains "ERROR:"
  assert_output_contains "not found"
}

@test "redirect-service.sh: auto confirms with --yes flag and patches service" {
  mkdir -p "$PROJECT_DIR/.state"
  echo "BRIDGE_POD=my-bridge-pod" > "$PROJECT_DIR/.state/dev-auth-service.env"

  run "$PROJECT_DIR/scripts/redirect-service.sh" dev auth-service --yes
  [ "$status" -eq 0 ]
  assert_output_contains "(--yes provided, assuming confirmation was obtained elsewhere)"
  assert_output_contains "Redirected."
  assert_called "patch service auth-service -n dev --type=json -p [{\"op\":\"replace\",\"path\":\"/spec/selector\",\"value\":{\"debug\":\"my-bridge-pod\"}}]"
}

@test "redirect-service.sh: confirms via interactive stdin 'yes' and patches service" {
  mkdir -p "$PROJECT_DIR/.state"
  echo "BRIDGE_POD=my-bridge-pod" > "$PROJECT_DIR/.state/dev-auth-service.env"

  run bash -c "printf 'yes\n' | \"$PROJECT_DIR/scripts/redirect-service.sh\" dev auth-service"
  [ "$status" -eq 0 ]
  assert_output_contains "Type 'yes' to continue:"
  assert_output_contains "Redirected."
  assert_called "patch service auth-service -n dev --type=json -p [{\"op\":\"replace\",\"path\":\"/spec/selector\",\"value\":{\"debug\":\"my-bridge-pod\"}}]"
}

@test "redirect-service.sh: cancels when stdin is not 'yes'" {
  mkdir -p "$PROJECT_DIR/.state"
  echo "BRIDGE_POD=my-bridge-pod" > "$PROJECT_DIR/.state/dev-auth-service.env"

  run bash -c "printf 'no\n' | \"$PROJECT_DIR/scripts/redirect-service.sh\" dev auth-service"
  [ "$status" -eq 1 ]
  assert_output_contains "Cancelled."
  refute_called "patch service auth-service"
}

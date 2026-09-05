#!/usr/bin/env bats

load 'lib/harness'

setup() {
  setup_project
}

teardown() {
  teardown_project
}

@test "check-env.sh: no args, oc cli, whoami succeeds" {
  setup_mock_bins oc
  export MOCK_WHOAMI_OUT="test-user"
  run "$PROJECT_DIR/scripts/check-env.sh"
  [ "$status" -eq 0 ]
  assert_output_contains "Used: oc"
  assert_output_contains "Login OK: test-user"
  assert_output_contains "To see services in a specific namespace:"
}

@test "check-env.sh: no args, oc cli, whoami fails" {
  setup_mock_bins oc
  export MOCK_WHOAMI_EXIT=1
  run "$PROJECT_DIR/scripts/check-env.sh"
  [ "$status" -eq 1 ]
  assert_output_contains "ERROR: you are not logged in"
}

@test "check-env.sh: no args, kubectl cli, context and get ns succeed" {
  setup_mock_bins kubectl
  export MOCK_CTX_OUT="test-context"
  run "$PROJECT_DIR/scripts/check-env.sh"
  [ "$status" -eq 0 ]
  assert_output_contains "Used: kubectl"
  assert_output_contains "Active context: test-context"
  assert_output_contains "Cluster access OK."
  assert_output_contains "To see services in a specific namespace:"
}

@test "check-env.sh: no args, kubectl cli, context fails" {
  setup_mock_bins kubectl
  export MOCK_CTX_EXIT=1
  run "$PROJECT_DIR/scripts/check-env.sh"
  [ "$status" -eq 1 ]
  assert_output_contains "ERROR: kubectl context not found"
}

@test "check-env.sh: no args, kubectl cli, context succeeds but get ns fails" {
  setup_mock_bins kubectl
  export MOCK_NS_EXIT=1
  run "$PROJECT_DIR/scripts/check-env.sh"
  [ "$status" -eq 1 ]
  assert_output_contains "ERROR: cluster is inaccessible"
}

@test "check-env.sh: namespace provided but does not exist" {
  setup_mock_bins kubectl
  export MOCK_NS_EXISTS_EXIT=1
  run "$PROJECT_DIR/scripts/check-env.sh" non-existent-ns
  [ "$status" -eq 1 ]
  assert_output_contains "ERROR: namespace 'non-existent-ns' not found or access denied."
}

@test "check-env.sh: namespace exists but no services found" {
  setup_mock_bins kubectl
  export MOCK_SVC_LIST=""
  run "$PROJECT_DIR/scripts/check-env.sh" dev
  [ "$status" -eq 0 ]
  assert_output_contains "(you don't have permission to list services in this namespace or there are no services)"
}

@test "check-env.sh: services exist but none are bridged" {
  setup_mock_bins kubectl
  export MOCK_SVC_LIST="auth-service 8080
payment-service 8081"
  export MOCK_OWNER_ANNOTATION=""
  run "$PROJECT_DIR/scripts/check-env.sh" dev
  [ "$status" -eq 0 ]
  assert_output_contains "(none, none are bridged)"
  assert_output_contains "Pass one of the NON-bridged names above to scripts/bridge-up.sh"
}

@test "check-env.sh: services exist and one is bridged" {
  setup_mock_bins kubectl
  export MOCK_SVC_LIST="auth-service 8080"
  export MOCK_OWNER_ANNOTATION="dev-user@host 2026-01-01T00:00:00Z"
  run "$PROJECT_DIR/scripts/check-env.sh" dev
  [ "$status" -eq 0 ]
  assert_output_contains "- auth-service -> dev-user@host 2026-01-01T00:00:00Z"
}

@test "check-env.sh: displays usage hint when namespace argument is missing" {
  setup_mock_bins kubectl
  run "$PROJECT_DIR/scripts/check-env.sh"
  [ "$status" -eq 0 ]
  assert_output_contains "To see services in a specific namespace: "
}

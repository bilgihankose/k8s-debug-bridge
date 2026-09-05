#!/usr/bin/env bats

load 'lib/harness'

setup() {
  setup_project
  setup_mock_bins kubectl
}

teardown() {
  teardown_project
}

@test "cleanup.sh: exits gracefully when neither local state nor annotation exists" {
  run "$PROJECT_DIR/scripts/cleanup.sh" dev auth-service
  [ "$status" -eq 0 ]
  assert_output_contains "State file (complete) and annotation not found"
  refute_called "patch service"
}

@test "cleanup.sh: restores selector from local state files and deletes bridge pod by name" {
  mkdir -p "$PROJECT_DIR/.state"
  echo "BRIDGE_POD=my-bridge-pod" > "$PROJECT_DIR/.state/dev-auth-service.env"
  echo "app=auth-service" > "$PROJECT_DIR/.state/dev-auth-service.selector"
  echo "99999" > "$PROJECT_DIR/.state/dev-auth-service.pid"

  run "$PROJECT_DIR/scripts/cleanup.sh" dev auth-service
  [ "$status" -eq 0 ]
  assert_output_contains 'Restoring service selector: auth-service -> {"app":"auth-service"}'
  assert_output_contains "Deleting bridge pod: my-bridge-pod"
  assert_called 'patch service auth-service -n dev --type=json -p [{"op":"replace","path":"/spec/selector","value":{"app":"auth-service"}}]'
  assert_called "delete pod my-bridge-pod -n dev --ignore-not-found"
  assert_called "annotate service auth-service -n dev k8s-debug-bridge/owner- k8s-debug-bridge/original-selector-"
  [ ! -f "$PROJECT_DIR/.state/dev-auth-service.env" ]
  [ ! -f "$PROJECT_DIR/.state/dev-auth-service.selector" ]
  [ ! -f "$PROJECT_DIR/.state/dev-auth-service.pid" ]
}

@test "cleanup.sh: recovers from single-key annotation when local state is missing" {
  export MOCK_SELECTOR_ANNOTATION="app=auth-service"
  export MOCK_ORPHAN_PODS="pod/orphan-bridge-pod"

  run "$PROJECT_DIR/scripts/cleanup.sh" dev auth-service
  [ "$status" -eq 0 ]
  assert_output_contains "WARNING: local state is missing/absent but annotation found on cluster"
  assert_called 'patch service auth-service -n dev --type=json -p [{"op":"replace","path":"/spec/selector","value":{"app":"auth-service"}}]'
  assert_called "delete -n dev --ignore-not-found"
  assert_called "annotate service auth-service -n dev k8s-debug-bridge/owner- k8s-debug-bridge/original-selector-"
}

@test "cleanup.sh: recovers from multi-key annotation when local state is missing" {
  export MOCK_SELECTOR_ANNOTATION="app=auth-service,tier=backend"
  export MOCK_ORPHAN_PODS="pod/orphan-bridge-pod"

  run "$PROJECT_DIR/scripts/cleanup.sh" dev auth-service
  [ "$status" -eq 0 ]
  assert_output_contains "WARNING: local state is missing/absent but annotation found on cluster"
  assert_called 'patch service auth-service -n dev --type=json -p [{"op":"replace","path":"/spec/selector","value":{"app":"auth-service","tier":"backend"}}]'
  assert_called "delete -n dev --ignore-not-found"
  assert_called "annotate service auth-service -n dev k8s-debug-bridge/owner- k8s-debug-bridge/original-selector-"
}

@test "cleanup.sh: recovers from annotation but reports nothing to delete when no orphan pod exists" {
  export MOCK_SELECTOR_ANNOTATION="app=auth-service"
  export MOCK_ORPHAN_PODS=""

  run "$PROJECT_DIR/scripts/cleanup.sh" dev auth-service
  [ "$status" -eq 0 ]
  assert_output_contains "No pod with 'debug' label found, nothing to delete."
  assert_called 'patch service auth-service -n dev --type=json -p [{"op":"replace","path":"/spec/selector","value":{"app":"auth-service"}}]'
  assert_called "annotate service auth-service -n dev k8s-debug-bridge/owner- k8s-debug-bridge/original-selector-"
}

#!/usr/bin/env bats

load 'lib/harness'

setup() {
  setup_project
  setup_mock_bins kubectl
}

teardown() {
  teardown_project
}

@test "bridge-up.sh: happy path creates state files and annotates service" {
  export MOCK_SELECTOR_OUTPUT="app=auth-service
"
  run "$PROJECT_DIR/scripts/bridge-up.sh" dev auth-service my-bridge nicolaka/netshoot
  [ "$status" -eq 0 ]
  [ -f "$PROJECT_DIR/.state/dev-auth-service.env" ]
  [ -s "$PROJECT_DIR/.state/dev-auth-service.selector" ]
  assert_called "annotate service auth-service -n dev k8s-debug-bridge/owner="
  assert_called "apply -n dev -f -"
}

@test "bridge-up.sh: refuses when service already bridged by someone else" {
  export MOCK_OWNER_ANNOTATION="someone@otherhost 2026-01-01T00:00:00Z"
  run "$PROJECT_DIR/scripts/bridge-up.sh" dev auth-service my-bridge nicolaka/netshoot
  [ "$status" -eq 1 ]
  assert_output_contains "already appears to be bridged"
  [ ! -f "$PROJECT_DIR/.state/dev-auth-service.env" ]
}

@test "bridge-up.sh: fails when port is non-numeric" {
  run "$PROJECT_DIR/scripts/bridge-up.sh" dev auth-service my-bridge nicolaka/netshoot http
  [ "$status" -eq 1 ]
  assert_output_contains "must be a valid numeric port number"
}

@test "assets/bridge-pod.yaml keeps the contract the other scripts depend on" {
  tpl="$REPO_ROOT/assets/bridge-pod.yaml"
  [ -f "$tpl" ]
  # Placeholders bridge-up.sh substitutes
  grep -q '__BRIDGE_NAME__' "$tpl"
  grep -q '__IMAGE__' "$tpl"
  grep -q '__PORT__' "$tpl"
  # redirect-service.sh points the Service selector at exactly this label
  grep -q 'debug: "__BRIDGE_NAME__"' "$tpl"
  # tunnel.sh and cleanup.sh exec into this container by name
  grep -q 'name: debug-bridge' "$tpl"
}

@test "assets/bridge-pod.yaml renders with no placeholder left behind" {
  tpl="$REPO_ROOT/assets/bridge-pod.yaml"
  rendered=$(sed -e "s|__BRIDGE_NAME__|my-bridge|g" \
                 -e "s|__IMAGE__|nicolaka/netshoot|g" \
                 -e "s|__PORT__|8000|g" "$tpl")
  refute_contains "__" "$rendered"
  assert_contains "name: my-bridge" "$rendered"
  assert_contains "image: nicolaka/netshoot" "$rendered"
  assert_contains "containerPort: 8000" "$rendered"
}

@test "bridge-up.sh: refuses when a previous session's state file is still present" {
  mkdir -p "$PROJECT_DIR/.state"
  printf 'NAMESPACE=dev\n' > "$PROJECT_DIR/.state/dev-auth-service.env"
  run "$PROJECT_DIR/scripts/bridge-up.sh" dev auth-service my-bridge nicolaka/netshoot
  [ "$status" -eq 1 ]
  assert_output_contains "already exists"
  refute_called "annotate service auth-service"
}

@test "bridge-up.sh: aborts when the service selector is empty or unreadable" {
  export MOCK_SELECTOR_OUTPUT=""
  run "$PROJECT_DIR/scripts/bridge-up.sh" dev auth-service my-bridge nicolaka/netshoot
  [ "$status" -eq 1 ]
  assert_output_contains "could not be read or is empty"
  [ ! -f "$PROJECT_DIR/.state/dev-auth-service.selector" ]
  [ ! -f "$PROJECT_DIR/.state/dev-auth-service.env" ]
  refute_called "annotate service auth-service"
}

@test "bridge-up.sh: fails when the pod template is missing" {
  export MOCK_SELECTOR_OUTPUT="app=auth-service
"
  rm -rf "$PROJECT_DIR/assets"
  run "$PROJECT_DIR/scripts/bridge-up.sh" dev auth-service my-bridge nicolaka/netshoot
  [ "$status" -eq 1 ]
  assert_output_contains "pod template not found"
  refute_called "apply -n dev -f -"
}

@test "bridge-up.sh: fails when the bridge pod never becomes ready" {
  export MOCK_SELECTOR_OUTPUT="app=auth-service
"
  export MOCK_WAIT_EXIT=1
  run "$PROJECT_DIR/scripts/bridge-up.sh" dev auth-service my-bridge nicolaka/netshoot
  [ "$status" -ne 0 ]
  assert_called "wait --for=condition=Ready"
  refute_called "exec my-bridge"
}

@test "bridge-up.sh: rejects an image without nc and leaves the Service untouched" {
  export MOCK_SELECTOR_OUTPUT="app=auth-service
"
  export MOCK_EXEC_EXIT=1
  run "$PROJECT_DIR/scripts/bridge-up.sh" dev auth-service my-bridge some/image-without-nc
  [ "$status" -eq 1 ]
  assert_output_contains "does not ship 'nc'"
  assert_output_contains "has NOT been touched"
  refute_called "patch service"
}

@test "bridge-up.sh: warns when the port looks like a debugger port, and still proceeds" {
  export MOCK_SELECTOR_OUTPUT="app=auth-service
"
  run "$PROJECT_DIR/scripts/bridge-up.sh" dev auth-service my-bridge nicolaka/netshoot 2345
  [ "$status" -eq 0 ]
  assert_output_contains "2345 is a well-known debugger port"
  assert_output_contains "targetPort"
  assert_called "apply -n dev -f -"
}

@test "bridge-up.sh: says nothing about debuggers for an ordinary application port" {
  export MOCK_SELECTOR_OUTPUT="app=auth-service
"
  run "$PROJECT_DIR/scripts/bridge-up.sh" dev auth-service my-bridge nicolaka/netshoot 8000
  [ "$status" -eq 0 ]
  refute_output_contains "debugger port"
}

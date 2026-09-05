#!/usr/bin/env bats

load 'lib/harness'

setup() {
  setup_project
}

teardown() {
  teardown_project
}

@test "lib-kube-cli.sh: respects already set KUBE_CLI variable" {
  run bash -c "export KUBE_CLI=custom-cli; source \"$PROJECT_DIR/scripts/lib-kube-cli.sh\" && echo \"\$KUBE_CLI\""
  [ "$status" -eq 0 ]
  [ "$output" = "custom-cli" ]
}

@test "lib-kube-cli.sh: selects oc when KUBE_CLI unset and oc available on PATH" {
  setup_mock_bins oc
  run bash -c "unset KUBE_CLI; export PATH=\"$MOCK_BIN_DIR\"; source \"$PROJECT_DIR/scripts/lib-kube-cli.sh\" && echo \"\$KUBE_CLI\""
  [ "$status" -eq 0 ]
  [ "$output" = "oc" ]
}

@test "lib-kube-cli.sh: selects kubectl when KUBE_CLI unset and only kubectl available on PATH" {
  setup_mock_bins kubectl
  run bash -c "unset KUBE_CLI; export PATH=\"$MOCK_BIN_DIR\"; source \"$PROJECT_DIR/scripts/lib-kube-cli.sh\" && echo \"\$KUBE_CLI\""
  [ "$status" -eq 0 ]
  [ "$output" = "kubectl" ]
}

@test "lib-kube-cli.sh: exits with error when neither oc nor kubectl is on PATH" {
  EMPTY_BIN_DIR="$(mktemp -d)"
  run bash -c "unset KUBE_CLI; export PATH=\"$EMPTY_BIN_DIR\"; source \"$PROJECT_DIR/scripts/lib-kube-cli.sh\""
  rm -rf "$EMPTY_BIN_DIR"
  [ "$status" -eq 1 ]
  assert_output_contains "neither 'oc' nor 'kubectl' found in PATH"
}

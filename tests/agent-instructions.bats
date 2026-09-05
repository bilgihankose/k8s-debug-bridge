#!/usr/bin/env bats
# SKILL.md and AGENTS.md are not documentation — an agent reads them and acts on them.
# A wording change in these files is a behaviour change, so the safety-critical instructions
# are asserted here. If a PR softens or removes an approval step, CI fails.
#
# Assertions are deliberately keyed on concepts (case-insensitive), not exact sentences, so
# ordinary rewording does not break the build while a removed guarantee does.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SKILL="$REPO_ROOT/SKILL.md"
  AGENTS="$REPO_ROOT/AGENTS.md"
}

# --- the files themselves ----------------------------------------------------

@test "agent instruction files exist" {
  [ -f "$SKILL" ]
  [ -f "$AGENTS" ]
}

@test "SKILL.md frontmatter name matches the directory name (Agent Skills spec)" {
  run grep -E '^name:[[:space:]]*k8s-debug-bridge[[:space:]]*$' "$SKILL"
  [ "$status" -eq 0 ]
  [ "$(basename "$REPO_ROOT")" = "k8s-debug-bridge" ]
}

# --- canonical safety sentences ----------------------------------------------
#
# These are matched as whole phrases, on a whitespace-normalised copy of the file so line
# wrapping does not matter. Matching phrases rather than keywords is deliberate: a keyword
# test can be defeated by inverting the sentence around it ("can be skipped" contains the
# same word as "must not be skipped"). If you genuinely need to reword one of these, update
# the list here in the same PR — that edit is the point where someone thinks twice.

@test "SKILL.md keeps the approval sentences for the redirect step" {
  run bash -c "tr '\n' ' ' < '$SKILL' | tr -s ' ' | grep -c 'get real approval'"
  [ "$output" -ge 1 ]
  run bash -c "tr '\n' ' ' < '$SKILL' | tr -s ' ' | grep -Ec 'After (getting )?approval, run'"
  [ "$output" -ge 1 ]
}

@test "AGENTS.md keeps the explicit-approval rule for redirect-service.sh" {
  run bash -c "tr '\n' ' ' < '$AGENTS' | tr -s ' ' | grep -c 'Always get explicit user approval'"
  [ "$output" -ge 1 ]
  run bash -c "tr '\n' ' ' < '$AGENTS' | tr -s ' ' | grep -Ec 'After (getting )?approval, run'"
  [ "$output" -ge 1 ]
}

@test "both files explain that --yes means approval was obtained elsewhere" {
  run bash -c "tr '\n' ' ' < '$SKILL' | tr -s ' ' | grep -o -- '--yes[^.]*' | grep -ci 'approval'"
  [ "$output" -ge 1 ]
  run bash -c "tr '\n' ' ' < '$AGENTS' | tr -s ' ' | grep -o -- '--yes[^.]*' | grep -ci 'approval'"
  [ "$output" -ge 1 ]
}

@test "the bridge-up-before-redirect prohibition is intact" {
  run bash -c "tr '\n' ' ' < '$SKILL' | tr -s ' ' | grep -c 'never redirect without the original selector saved'"
  [ "$output" -ge 1 ]
  run bash -c "tr '\n' ' ' < '$AGENTS' | tr -s ' ' | grep -c 'never proceed to redirect without running this'"
  [ "$output" -ge 1 ]
}

@test "the prohibition on reading pod environment variables is intact" {
  for f in "$SKILL" "$AGENTS"; do
    run bash -c "tr '\n' ' ' < '$f' | tr -s ' ' | grep -c 'never run \`oc exec ... env\`'"
    [ "$output" -ge 1 ]
  done
}

@test "both files tell the agent to check for a forgotten bridge before ending the session" {
  for f in "$SKILL" "$AGENTS"; do
    run bash -c "tr '\n' ' ' < '$f' | tr -s ' ' | grep -Eci 'before ending the session'"
    [ "$output" -ge 1 ]
    run bash -c "grep -c 'cleanup.sh' '$f'"
    [ "$output" -ge 1 ]
  done
}

@test "the state directory is described as living next to scripts, not the user project" {
  # a bare 'find .state' from the user's project reports a clean state while a bridge is up
  for f in "$SKILL" "$AGENTS"; do
    run bash -c "tr '\n' ' ' < '$f' | tr -s ' ' | grep -Eci 'next to .scripts|not in the user.s project'"
    [ "$output" -ge 1 ]
  done
}

# --- nothing may instruct the agent to bypass a safety step -------------------

@test "no instruction tells the agent to skip approval or confirmation" {
  # Phrases that would disable a guarantee if someone slipped them into a docs PR.
  # Scoped to approval/confirmation wording on purpose: a broad 'do not ask the user'
  # match would flag the legitimate "don't ask for the namespace, run check-env.sh first".
  PATTERN='skip (the )?(approval|confirmation|warning)'
  PATTERN="$PATTERN|without (getting |asking for )?(explicit )?(approval|confirmation)"
  PATTERN="$PATTERN|no (approval|confirmation) (is )?(needed|required)"
  PATTERN="$PATTERN|(do not|don'\''t|no need to) (ask for|request|require|wait for) (an? )?(approval|confirmation)"
  PATTERN="$PATTERN|asking (again|twice) is (redundant|unnecessary)"
  for f in "$SKILL" "$AGENTS"; do
    run bash -c "grep -Ein \"$PATTERN\" '$f'"
    [ -z "$output" ]
  done
}

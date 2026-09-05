# Tests

58 [bats](https://github.com/bats-core/bats-core) tests covering `scripts/*.sh`, using a fake `kubectl`/`oc` (`tests/fixtures/mock-kube.sh`) so nothing touches a real cluster.

```bash
brew install bats-core   # once
bats tests/*.bats
```

## How mocking works

`tests/lib/harness.bash` provides `setup_project` (copies `scripts/` into an isolated temp dir so `.state/` never collides between tests) and `setup_mock_bins kubectl|oc` (puts a fake `kubectl`/`oc` on `PATH` pointing at `tests/fixtures/mock-kube.sh`). Every mock response is controlled by `MOCK_*` environment variables — see the top of `mock-kube.sh` for the full list. `assert_called`/`refute_called` check `$MOCK_CALL_LOG` for expected invocations.

## Write assertions as function calls, never as a bare `[[ ]]`

`[[ ... ]]` is a bash *keyword*. When one fails inside a bats test the failure does not abort that test unless it happens to be the very last command — bats still reports `ok`. An entire suite can be green while asserting nothing. Use the harness helpers instead, which are ordinary functions whose non-zero exit bats does catch:

```bash
assert_output_contains "ERROR: ... not found"   # $output must contain this
refute_output_contains "Redirected."            # $output must not
assert_contains "containerPort: 8000" "$rendered"
refute_contains "__" "$rendered"
```

`[ ... ]` (the `test` builtin, e.g. `[ "$status" -eq 1 ]`) is caught normally and is fine to use directly.

Anything that can block — `tunnel.sh` past its pre-flight checks, for instance — should be run through `run_with_timeout <seconds> <cmd...>` so a regression fails the test instead of hanging CI.

## Coverage — honest notes

We tried automated line coverage via `kcov`, but its bash-tracing mode produced inconsistent, sometimes garbled results on macOS/arm64 in this environment (wrong line attribution, spurious parse errors) — not trustworthy enough to quote a percentage from. Instead, here's a manual branch-by-branch accounting, verified by reading each script against the 58 tests **and** by mutation-testing them: each guard below was deliberately broken one at a time, and every mutation made at least one test fail.

| Script | Branch coverage |
|---|---|
| `lib-kube-cli.sh` | All 4 paths tested: `KUBE_CLI` preset, `oc` found, `kubectl` found, neither found. |
| `check-env.sh` | All paths tested: oc/kubectl login success/failure, `get ns` failure, missing namespace, empty service list, no services bridged, one bridged, no-namespace usage hint. |
| `bridge-up.sh` | All paths tested: happy path, non-numeric port, already-bridged rejection, stale `.env` rejection, empty/unreadable selector rejection, missing pod template, pod never becoming Ready, and an image without `nc` (which must leave the Service untouched). |
| `redirect-service.sh` | All paths tested: missing args, missing state file, `--yes`, interactive "yes", interactive non-"yes" (cancel). |
| `cleanup.sh` | All paths tested: nothing to clean up, restore from local state + delete pod by name, restore from annotation (single key, multiple keys), restore from annotation with no orphan pod found. |
| `tunnel.sh` | **Partial, deliberately.** Argument validation and the `nc` pre-flight check are tested. The main loop (`while true; do kubectl exec ... nc -l <>"/dev/tcp/..." >&0; done`) blocks on a real socket + exec connection with no mockable boundary — unit-testing it would mean re-implementing both ends of a TCP tunnel, which isn't worth it. If you want to verify the tunnel itself, do it against a real (or kind/minikube) cluster. |
| `lib-ui.sh` | All paths tested: styling on for a TTY with a normal `TERM`, off when the stream is not a TTY, off under `NO_COLOR`, off under `TERM=dumb`; errors and warnings on stderr, the rest on stdout; and no script emits an escape code when its stdout is redirected. `ui_is_tty` exists as a separate function so these can be tested without a real terminal. |
| `SKILL.md` / `AGENTS.md` | `agent-instructions.bats` pins the safety wording an agent reads: the approval sentences, the bridge-up-before-redirect prohibition, the ban on reading pod environment variables, and the frontmatter `name`. |

Three things were caught by writing (and mutating) these tests — one in the scripts, two in the suite itself:

- `cleanup.sh`'s annotation-recovery path silently dropped the last `key=value` pair when rebuilding the selector JSON, because the CSV-to-JSON pipeline fed a `while read` loop a final line with no trailing newline (a well-known bash `read` gotcha) — fixed by adding `\n` before the `tr` step.
- The suite itself was asserting far less than it looked: 48 output assertions were bare `[[ ]]` expressions and therefore inert. They are now function calls (see the section above), and the mutation run that exposed this is what the coverage table is now based on.
- The first `NO_COLOR` test was inert for the same class of reason: under a test runner stdout is never a TTY, so styling was already off and the assertion held whatever `lib-ui.sh` did about `NO_COLOR`. Stubbing `ui_is_tty` is what makes that rule actually testable.

# Changelog

Notable changes, newest first. The version here matches `metadata.version` in `SKILL.md`, so `npx skills list` tells you which one you have.

To update an installed copy:

```bash
npx skills update k8s-debug-bridge
```

## v0.1.0 — 2026-09-05

First public release.

- Five scripts that pull a Kubernetes Service's traffic to `localhost`: `check-env.sh` (read-only pre-flight), `bridge-up.sh` (temporary bridge pod, original selector saved locally *and* as an annotation on the Service), `redirect-service.sh` (selector swap, behind an explicit confirmation), `tunnel.sh` (reverse tunnel, restores state on Ctrl+C via `trap`), `cleanup.sh` (selector restored, pod deleted).
- No dependency on either side: `kubectl`/`oc exec`, bash's built-in `/dev/tcp`, and the `nc` already inside the pod image. Nothing is installed locally and nothing permanent is left in the cluster.
- Ships as an Agent Skill: `SKILL.md` and `AGENTS.md` carry the approval rules an agent must follow before creating the pod and before redirecting the Service.
- `docs/local-debug-setup.md`: the local-side recipe — the three requirements your app has to satisfy, a working Go setup (Air + Delve), and the equivalents for Node, Python, JVM and .NET.
- Guards against bridging a debugger port (Delve `2345`, debugpy `5678`, node `9229`, JDWP `5005`): the scripts warn, and the docs name the 502 it produces. This came out of a real session where the debugger port was bridged instead of the application port.
- Owner annotation (`k8s-debug-bridge/owner`) so a second developer cannot silently take over a Service someone else is already bridging.
- 61 bats tests over a mocked `kubectl`, plus shellcheck in CI.

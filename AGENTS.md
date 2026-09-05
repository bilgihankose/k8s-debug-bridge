# AGENTS.md — k8s-debug-bridge

This repo contains bash scripts that route traffic of a service in a Kubernetes/OpenShift
cluster to the local machine for debugging, without installing an extra CLI/agent tool.
This file is a short operating guide for agents that read the
[AGENTS.md standard](https://agents.md), such as Codex. For details, see `README.md`.

## When to use

Apply this flow if the user asks for something like:
- "I want to debug service X in the cluster locally"
- "An extra CLI/agent tool isn't allowed here, I need to pull the traffic locally"
- "set up a bridge pod", "intercept service traffic"

## Prerequisites — verify before asking

Do not ask the user for the namespace/service name and use it blindly. First run
`scripts/check-env.sh [namespace]` (read-only):
- Without arguments: login status + accessible namespaces. If not logged in, stop and
  tell the user to run `oc login`/`kubectl config use-context`.
- With a namespace: verifies the namespace exists and lists the Services inside it
  (name + port + targetPort).

Show the output to the user and let them pick the target Service from the list — don't
make them guess. Then ask:
- **Application port, never the debugger port.** The `<port>` argument is the port the
  application serves on — the Service's `targetPort` that `check-env.sh` prints. A
  debugger's own port (Delve 2345, debugpy 5678, node --inspect 9229, JDWP 5005) is
  spoken to by the IDE alone and is never bridged. If the user asks for the debugger
  port, say why that fails (the debugger drops the connection, every request returns
  502) and ask for the application's port instead.

- **The bridge pod image — always ask, never assume.** Ask outright *"which image
  should the bridge pod use?"* and wait for an answer; don't fall back to a default.
  Only the user knows which image their cluster is allowed to pull — many clusters
  pull only from an approved internal registry, so a guessed image can fail at pull
  time with the Service already redirected. Offer `nicolaka/netshoot` or
  `busybox` as examples. It must ship `sh` plus **`nc`**: the pod side uses `nc` because
  hardened images often strip `socat` while keeping it; the local side
  needs nothing at all (bash `/dev/tcp`). `tunnel.sh` checks the running pod for `nc`
  and aborts if it's missing — the pod then has to be recreated with another image.
- **Pod manifest**: rendered from `assets/bridge-pod.yaml`. Cluster policy needs
  (imagePullSecrets, securityContext, nodeSelector, resource limits) are edited there,
  not worked around in the scripts. The `debug: "__BRIDGE_NAME__"` label and the
  `debug-bridge` container name must stay — the other scripts address the pod by them.
- **The port**: use the Service's `targetPort` from `check-env.sh`'s output, not an
  arbitrary free port — kube-proxy forwards traffic to the pod's `targetPort` once
  the selector is redirected, so a mismatched port means no traffic ever arrives.

**Secrets and environment**: never run `oc exec ... env`, `printenv`, `set` or anything
similar against an application pod. Values can be multiline credentials and will leak
into terminal/tool output even when the command looks like it only selects names. Never
copy pod environment values into a local command, shell history or `.env`. Require an
existing local secret-management workflow, or have the user supply the local env file out
of band; verify only that the app starts, never print its environment.

**The local application must already be running before you touch the Service.** The
tunnel delivers traffic to `127.0.0.1:<port>`, so if nothing listens there when the
selector flips, every intercepted request fails with connection-refused/502 while the
real pods are already out of rotation. Confirm it right before step 2:

```bash
lsof -nP -iTCP:<port> -sTCP:LISTEN
```

**This creates/modifies real resources in the cluster**: a Pod is created, a Service's
`spec.selector` is modified. It is not a simulation.

## Flow — in this order, without skipping

1. Tell the user: *"I will create a real Pod named `<bridge-pod>` in `<namespace>`
   (image: `<image>`)."* After getting approval, run `scripts/bridge-up.sh
   <namespace> <service> <bridge-pod> <image> [port]` — sets up the bridge pod, saves the
   original Service selector to both `.state/<namespace>-<service>.{env,selector}`
   files and the Service's `k8s-debug-bridge/owner` annotation. **If this step is
   skipped there's no way back — never proceed to redirect without running this
   first.** If the service is already bridged by someone else, the script fails and
   stops — show the user the owner from the error message, don't retry.
2. Give the user a clear warning: *"ALL traffic to `<service>` will now go to the
   bridge pod."* After getting approval, run `scripts/redirect-service.sh
   <namespace> <service> --yes` (without `--yes` the script hangs on an interactive
   `read` — since you already got approval, `--yes` is required). The script replaces
   the entire selector map; merging `debug=<bridge-pod>` into the original selector
   would leave the Service with no matching endpoint.
3. `scripts/tunnel.sh <namespace> <service> <bridge-pod> <port>` — blocking, so it
   belongs in its own terminal or a background process. On Ctrl+C or when the process
   ends, a `trap` automatically triggers `cleanup.sh`. **If you started it in the
   background there is no Ctrl+C to press** — stop it with `kill -TERM <pid>` (the trap
   handles TERM too); note the PID at launch and tell the user. It accepts one
   connection at a time and reopens the listener after each connection, so keep it
   running between requests. Repeated `WARNING: could not carry a connection` lines mean
   nothing is listening on `127.0.0.1:<port>` — fix the local app, don't restart the tunnel.
4. The user's local application must be listening on the same `<port>` — that's what
   receives the tunneled traffic. Their debugger attaches to that running app
   separately (usually a different port, e.g. Delve on 2345). The bridge passes the HTTP
   path through unchanged — it does not reproduce an Ingress rewrite, so the local app's
   route/base prefix must accept the path the Service actually receives. The caller can be any
   in-cluster workload using the Service, such as a dashboard Nginx proxy; it does not
   have to use a public Route. A long breakpoint pause may exceed the caller's timeout.
   With Delve `--accept-multiclient`, an agent can attach alongside VS Code to inspect
   the current line, stack and variables. Get approval before continuing execution or
   changing debugger state.
5. When done, Ctrl+C in the tunnel terminal (or `kill -TERM <pid>` for a background
   run) is enough — it cleans up automatically. Cleanup restores the complete original
   selector map. If the trap didn't fire (`kill -9`), `scripts/cleanup.sh <namespace>
   <service>` must be run manually.

## Security rules — never violate

- Don't run `redirect-service.sh` without having run `bridge-up.sh`.
- Always get explicit user approval before `redirect-service.sh`.
- Before ending the session, check for a forgotten `.env` file in the state directory.
  **It sits next to `scripts/`, in the repo/skill folder — not in the user's project**,
  so resolve it from the script path rather than the current directory. A bare
  `find .state` run from somewhere else finds nothing and wrongly reports a clean state.
  If a `.env` is found, tell the user which namespace/service it names and suggest
  `cleanup.sh <namespace> <service>`.
- Don't run anything requiring cluster-admin; these scripts must only run in your
  own namespace, with your own `exec` permission.

## CLI selection

The scripts automatically use `oc` if it exists, otherwise `kubectl`
(`scripts/lib-kube-cli.sh`). Force it with the `KUBE_CLI=oc` or `KUBE_CLI=kubectl`
environment variable.

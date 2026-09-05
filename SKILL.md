---
name: k8s-debug-bridge
description: >-
  Automates intercepting and routing traffic from a Kubernetes or OpenShift service to a local machine for debugging, using a temporary bridge pod and a reverse tunnel (kubectl/oc exec + nc). Use this skill when the user wants to: debug a remote K8s/OpenShift microservice on their local machine, intercept or redirect live cluster traffic to localhost, or test local code against other services in a staging/dev cluster. Trigger this if the user asks about "local k8s development", "remote debugging pods", "routing service traffic locally", "reverse port-forwarding", "bridge pod", or "intercepting service traffic".
license: MIT
compatibility: Requires kubectl or oc with a logged-in session, bash (the tunnel uses bash's /dev/tcp, which is not POSIX), and a bridge pod image that ships nc (e.g. nicolaka/netshoot). Nothing is installed locally.
allowed-tools: Bash(./scripts/*) Bash(kubectl:*) Bash(oc:*) Bash(lsof:*) Bash(find:*) Read
metadata:
  version: "0.1.0"
---

# K8s Debug Bridge

Tunnels live traffic from a Kubernetes/OpenShift Service to a local machine for
debugging using only standard `kubectl`/`oc exec`, bash's built-in `/dev/tcp` and the
`nc` inside the bridge pod — no extra CLI or agent to install. Mechanism: a temporary
"bridge pod" is spun up, the target Service's
`spec.selector` is temporarily switched to this pod's label, and a reverse tunnel
bridges the pod and the local port. Works on any Kubernetes distribution (vanilla
K8s, OpenShift, EKS/GKE/AKS) — uses `oc` if available, otherwise `kubectl` (see
`scripts/lib-kube-cli.sh`). `README.md` covers the rationale and the tradeoffs against
tools like Telepresence and mirrord.

This is not tied to a single language/framework: the bridge only transports traffic.
VS Code + Air + Delve (Go) is just an **example** integration — if you work in another
language, connect your own watcher/debugger (Node: nodemon+inspector, Python:
watchdog+debugpy, etc.) over the same tunnel.
If the user's local side is not set up yet — no reloader, no debugger attached, or they
want it adapted to their own project — read `docs/local-debug-setup.md` at that point and
follow it. Don't reproduce its contents from memory, and don't read it when the local app
is already running and listening.

**This skill creates a real resource in your cluster and modifies a real resource:
it creates a Pod and temporarily changes a Service's `spec.selector`. These are not
simulations — this is real cluster state. There must be a rollback plan at every
step — never change the selector and forget about it.**

## Prerequisites — verify before asking the user

Do not ask the user for the namespace/service name and pass it blindly to
`bridge-up.sh` — a misspelled name will fail in the middle of the script. First run
**`scripts/check-env.sh [namespace]`** (read-only, changes nothing):

- Run without arguments: lists login status and accessible namespaces. If not
  logged in, stop here and tell the user to run `oc login`/`kubectl config
  use-context`.
- Run with a namespace: verifies the namespace exists and lists the Services inside
  it (name + port + targetPort, including ones already bridged).

Show this output to the user and let them pick the target Service from the list —
don't make them guess. Then:
- **The bridge pod image — always ask, never assume.** Do not pick a default and run
  with it: ask the user outright *"which image should the bridge pod use?"* and wait for
  an answer. The image has to be approved by and reachable from that specific cluster,
  and only they know which one that is — many clusters pull only from an approved
  internal registry, so a guessed image can fail at pull time with the Service already
  redirected. [`nicolaka/netshoot`](https://github.com/nicolaka/netshoot)
  is an example to offer, not a fallback to use silently.
  Whatever they pick must ship `nc`: the pod side uses `nc` rather than socat because
  hardened images often strip `socat` out while keeping Nmap's `nc`.
  `tunnel.sh` checks for `nc` before opening the tunnel and stops with a clear error if
  the image doesn't have it.
- **Pod manifest**: the bridge pod is rendered from `assets/bridge-pod.yaml`. If the
  cluster requires imagePullSecrets, a securityContext, nodeSelector/tolerations or
  different resource limits, edit that file — don't work around it in the scripts. Keep
  the `debug: "__BRIDGE_NAME__"` label and the `debug-bridge` container name; the other
  scripts address the pod through them.
- **The port**: use the Service's numeric `targetPort` from `check-env.sh`'s output,
  NOT an arbitrary free port. If the Service uses a named targetPort (e.g. `http`),
  resolve it to its numeric container port. kube-proxy forwards traffic to the pod's
  `targetPort` once the selector is redirected — if you pick a different number,
  traffic never reaches the bridge pod at all.
- **Outbound dependencies**: this bridge only handles inbound traffic (Cluster → Local).
  If local code must call other cluster services (`.svc.cluster.local`), use external
  Routes/Ingress or local port-forwards.
- **Secrets and environment**: never run `oc exec ... env`, `printenv`, `set`, or a
  similar command against an application pod. Values may be multiline credentials and
  will leak into terminal/tool output even when a command appears to select only names.
  Never copy pod environment values into a local command, shell history, or `.env`.
  Require a pre-existing local secret-management workflow or have the user provide the
  needed local env file out of band. Verify only that the local application starts;
  do not print its environment.

**The local application must already be running before you touch the Service.** This is
a precondition, not a later step: the tunnel delivers traffic to `127.0.0.1:<port>`, so
if nothing listens there when the selector flips, every intercepted request fails with
connection-refused/502 while the real pods are already out of rotation. Have the user
start their app (with a safely provisioned local env file — never one read out of a
cluster pod) and confirm the listener immediately before step 2:

```bash
lsof -nP -iTCP:<port> -sTCP:LISTEN
```

## Flow

1. **Set up the bridge**: Before running anything, tell the user clearly: *"I will
   create a real Pod named `<bridge-pod>` in the `<namespace>` namespace (image:
   `<image>`) — it consumes cluster resources and will be deleted once you're
   done."* After getting approval, run `scripts/bridge-up.sh <namespace> <service>
   <bridge-pod> <image> [port]` — this creates the bridge pod and saves the
   original selector both to local state and as a `k8s-debug-bridge/owner`
   annotation on the Service (no python3/jq required, plain bash). Don't skip this
   step — never redirect without the original selector saved, or there's no way
   back. **If the service is already bridged by someone else, this script fails
   and stops** (annotation check) — in that case show the user the owner from the
   error message, don't retry yourself.

2. **Redirect the service**: Before switching the target Service's selector to the
   bridge pod's label, tell the user clearly and get real approval: *"From this
   moment, ALL traffic to `<service>` will go to your bridge pod — the real pods
   will stop receiving traffic."* After approval, run
   `scripts/redirect-service.sh <namespace> <service> --yes` — `--yes` skips the
   script's own interactive `read` prompt (since you already got approval in
   chat); without `--yes` the script waits on stdin and can hang.
   The script replaces the complete selector map with only
   `debug=<bridge-pod>`; it must not merge this label into the original selector,
   because the bridge pod does not carry the application's original labels.

3. **Start the tunnel**: `scripts/tunnel.sh <namespace> <service> <bridge-pod>
   <port>` — this script blocks, so it belongs in its own terminal or a background
   process. **It self-cleans**: `trap` catches EXIT/INT/TERM, so Ctrl+C or any other
   termination automatically calls `cleanup.sh`. **If you started it in the background
   yourself, there is no Ctrl+C to press** — stop it with `kill -TERM <pid>`, which the
   trap also handles; note the PID when you launch it and tell the user what it is.
   Running `cleanup.sh` by hand is only needed if the process is killed uncatchably
   (`kill -9`).
   It carries one connection at a time and automatically creates a fresh pod-side
   listener after each connection closes, so leave the same tunnel running between
   sequential debug requests.
   If the tunnel repeatedly logs `WARNING: could not carry a connection`, nothing is
   listening on `127.0.0.1:<port>` — the local app is down, still building, or a hot
   reload released the port. Fix that rather than restarting the tunnel.

4. **Local debug**: the port you bridge is the port the **application** serves on
   (the Service's `targetPort`), never the port its debugger listens on. If the user
   says "my debugger is on 2345, bridge that", they are conflating the two: correct
   them, ask which port the application itself serves on, and bridge that one. Traffic
   sent to a debugger port comes back as 502s that look like a broken tunnel.
   The local app is already running and verified (see the
   precondition above); it is what receives tunneled traffic. Their language's debugger
   (e.g. Delve, a Node inspector) attaches to that running application separately,
   usually on a different port — e.g. in Go, Air + Delve on port 2345 while the app
   itself listens on the tunneled `<port>`.
   A hot reload can briefly remove the listener; while
   it is absent the bridge returns connection failures/502s. If the local app does
   not recover promptly, stop the tunnel and clean up the Service instead of leaving
   all traffic pointed at a failing bridge. The bridge transports the HTTP path
   unchanged: configure the local app's base prefix to match the path delivered to
   the Service; it does not reproduce an Ingress rewrite.
   Traffic may come from any in-cluster caller of the Service (for example, a
   dashboard Nginx proxy); a public Route/Ingress is not required. If execution is
   paused beyond the caller's timeout, resume it and trigger a new request. After a
   hot reload restarts Delve, the IDE may need to attach again.
   When Delve was started with `--accept-multiclient`, the agent may also attach a
   terminal Delve client to port `2345` alongside VS Code to inspect the current
   source line, stack and variables. Report observations to the user; get explicit
   approval before continuing execution or otherwise changing debugger state.

5. **When done**: Ctrl+C in the tunnel terminal, or `kill -TERM <pid>` if you started
   it in the background — the service selector and bridge pod revert automatically,
   including restoration of the complete original selector map. If the trap didn't fire
   (e.g. `kill -9`), `scripts/cleanup.sh <namespace> <service>` must be run manually;
   remind the user of this before they leave the session.

## Security note

This method installs no permanent component in the cluster (no mutating webhook,
sidecar injector, or cluster-wide RBAC) — only a temporary pod clearly marked by
its name/label (`debug=<bridge-pod-name>`) and standard `exec` permissions. Even
so, there are two real risks, warn the user about them:
1. Forgetting to revert the service selector — a permanent outage in prod/stage.
2. `exec` permission being abusable via RBAC — this skill should only run in your
   own namespace, on your own bridge pod, and should never need cluster-admin.

For detailed steps and troubleshooting, see `README.md`.

Before ending the session, check whether an uncleaned bridge remains. **State lives
next to `scripts/`, in this skill's own folder — not in the user's project directory.**
Resolve it relative to the scripts you are running, e.g.:

```bash
find "$(dirname <path-to>/scripts)/.state" -name '*.env'
```

Running a bare `find .state` from the user's project will silently find nothing and
report a clean state even when a bridge is still up. If a `.env` file exists there, tell
the user which namespace/service it names and suggest
`scripts/cleanup.sh <namespace> <service>`. This is a reminder, not a deterministic gate
— take care not to forget it.

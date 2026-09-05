# Setting up the local side

The bridge only moves bytes. Whatever receives them on `127.0.0.1:<port>` is your own application, and attaching a debugger to it is a separate job from opening the tunnel. This file is the recipe for that job — read it when the local side is not set up yet, and adapt it to the project in front of you.

## What the local side has to satisfy

Three requirements, in this order. Everything below is just a language-specific way of meeting them.

1. **The app listens on the Service's `targetPort`.** Not the Service's client-facing `port`, and not a free port you picked — `check-env.sh` prints the right number. Once the selector is switched, kube-proxy delivers to that port and nothing else.
2. **It is already listening before the Service is redirected.** Verify it, do not assume: `lsof -nP -iTCP:<port> -sTCP:LISTEN` (on Windows, `netstat -ano | findstr :<port>`). A redirect made against a port with nothing behind it turns every real request into a connection failure.
3. **The debugger attaches to the app on its own separate port.** The bridge knows nothing about debuggers; a debugger port is never the port you pass to `bridge-up.sh` / `tunnel.sh`.

A fourth one, easy to miss: **paths are delivered unchanged.** The bridge does not emulate an Ingress rewrite, so the local app's base prefix has to accept the path the Service actually receives. Prove it with an endpoint that already works before testing a new one.

## Go — Air + Delve

This is the setup the author runs; the rest of the file generalises from it.

```bash
# Air: rebuilds on save
go install github.com/air-verse/air@latest

# Delve: the debugger
go install github.com/go-delve/delve/cmd/dlv@latest

# Check which dlv you will actually run, and what it was built for:
file "$(which dlv)"      # on Windows: where dlv
```

Read that output against your own machine: on Apple Silicon you want `arm64`, and the path should be the Go bin directory you just installed into. If it points somewhere else — an older copy from a package manager, or one built for a different architecture — that copy comes first in your `PATH` and is the one that runs. Remove it and re-run the `go install` so the fresh build is found.

`.air.toml` in the project root. Two details are not optional: `CGO_ENABLED=0` and `-gcflags='all=-N -l'` (they disable the optimisations and inlining that make breakpoints land on the wrong line, or not at all).

```toml
root = "."
tmp_dir = "tmp"

[build]
  # "./cmd/api" -> path to THIS project's main package (e.g. "./cmd/server", ".")
  cmd = "CGO_ENABLED=0 go build -gcflags='all=-N -l' -o ./tmp/main ./cmd/api"
  # dlv runs the binary headless; the IDE attaches to :2345
  full_bin = "dlv --listen=:2345 --headless=true --continue --api-version=2 --accept-multiclient --check-go-version=false exec ./tmp/main --wd=$(pwd)"
  include_ext = ["go", "env"]
  exclude_dir = ["tmp", "vendor", "testdata", "docs", "node_modules", ".git"]
  delay = 1500
  stop_on_error = true
  send_interrupt = true

[log]
  time = true
```

`.vscode/launch.json` — the "attach" entry is the one used with the bridge:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Attach to Air (Hot Reload)",
      "type": "go",
      "request": "attach",
      "mode": "remote",
      "port": 2345,
      "host": "127.0.0.1",
      "substitutePath": [{ "from": "${workspaceFolder}", "to": "${workspaceFolder}" }]
    }
  ]
}
```

Three things here are project-specific and must be adapted rather than copied: the main package path (in both `.air.toml` and any `launch` configuration), the `envFile` path if the project keeps one, and the debug port if `2345` is taken.

`--accept-multiclient` matters for agent work: it lets a terminal Delve client attach alongside the IDE, so an agent can read the stopped frame, stack and variables while the IDE stays connected. Reading is safe. Continuing execution or changing debugger state is not — that paused request is real traffic from a shared cluster, and it needs the user's approval first.

## Other languages — the same three requirements

Only the tooling changes.

| | Watcher / reloader | Debugger | Attach from the IDE |
|---|---|---|---|
| **Node.js** | `nodemon`, `tsx watch` | built-in inspector: `node --inspect=127.0.0.1:9229` | "Attach to Node process", port 9229 |
| **Python** | `watchfiles`, `uvicorn --reload` | `debugpy`: `python -m debugpy --listen 127.0.0.1:5678` | "Python: Remote Attach", port 5678 |
| **Java / Kotlin** | the build tool's continuous mode | JDWP agent: `-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=*:5005` | "Remote JVM Debug", port 5005 |
| **.NET** | `dotnet watch` | `vsdbg` / the IDE's attach-to-process | attach to the running process |

These are starting points, not verified recipes — the author has only run the Go path end to end. Whatever the stack, check it against the three requirements above before touching the Service.

## During a session

- **Hot reload briefly frees the port.** While the app rebuilds, intercepted requests get `connection refused` / 502. That is expected; if it does not recover quickly, stop the tunnel with Ctrl+C so its trap restores the Service.
- **A held breakpoint holds a real request.** Pause longer than the caller's timeout and that request fails on their side — on a shared dev/stage cluster someone may notice.
- **After a reload the IDE may need to attach again**, because the reloader restarted the debugger process underneath it.
- **A stale debugger port blocks the next start.** If `:2345` (or your equivalent) is already taken, find and stop the old process before starting a fresh watcher instance.

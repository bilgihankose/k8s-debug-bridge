#!/usr/bin/env bash
# Pre-flight checks shared by bridge-up.sh and tunnel.sh. Sourced, not executed.

# Ports that normally belong to a debugger's own listener rather than to an application.
# Bridging one of them is a common and very confusing mistake: the debugger accepts the
# TCP connection, fails to parse HTTP, and drops it — so the caller in the cluster sees
# 502s that look like a broken tunnel. The bridge must carry traffic to the port the
# APPLICATION listens on (the Service's targetPort); the debugger is attached to that
# application separately and is never part of the tunnel.
#
#   2345 Delve · 5678 debugpy · 9229/9230 Node inspector · 5005 JDWP · 5858 legacy Node
DEBUGGER_PORTS="2345 5678 9229 9230 5005 5858"

# warn_if_debugger_port <port> — warns and continues; it never blocks, because an
# application is technically allowed to listen on any of these.
warn_if_debugger_port() {
  local port="$1" known
  for known in $DEBUGGER_PORTS; do
    [ "$port" = "$known" ] || continue
    ui_warn "WARNING: $port is a well-known debugger port, not an application port."
    ui_hint "The bridge carries cluster traffic to the port your APPLICATION listens on —"
    ui_hint "the Service's targetPort, which scripts/check-env.sh prints in its own column."
    ui_hint "A debugger (Delve, debugpy, node --inspect, JDWP) listens separately, is only"
    ui_hint "spoken to by your IDE, and is never bridged. Sending cluster traffic to it"
    ui_hint "produces 502s that look like the tunnel is broken."
    ui_hint "Continuing anyway — if your app really does listen on $port, ignore this."
    return 0
  done
  return 0
}

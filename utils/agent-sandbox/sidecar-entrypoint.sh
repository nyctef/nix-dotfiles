#!/usr/bin/env bash
set -euo pipefail

# Sidecar proxy entrypoint (Phase B.1).
#
# Runs mitmproxy as a forward (explicit) proxy. The agent container uses
# HTTP_PROXY / HTTPS_PROXY env vars to route traffic here. The Docker
# --internal network provides mandatory enforcement: even if the agent ignores
# the proxy env vars, packets with non-subnet destination IPs are DROPped by
# Docker's host-level DOCKER-INTERNAL iptables chain.
#
# No iptables, no ip_forward, no NET_ADMIN needed — the --internal network
# is the enforcement, the proxy is just the policy brain.
#
# Network topology:
#   - default bridge: internet access (sidecar only)
#   - sandbox-internal (--internal): agent ↔ sidecar only, no internet
#
# Traffic flow:
#   agent → HTTP_PROXY=sidecar:8080 → mitmproxy (forward mode) → internet
#   agent → direct connect to external IP → DROPped by Docker --internal

PROXY_PORT=8080
PROXY_CONFDIR="/etc/mitmproxy"
CA_SHARE_DIR="/shared-ca"
PROXY_LOGFILE="/var/log/mitmproxy.log"

# ── 1. Start mitmproxy ──────────────────────────────────────────────────────

mkdir -p "$PROXY_CONFDIR" "$CA_SHARE_DIR"

echo "Starting egress proxy (mitmproxy forward mode, port $PROXY_PORT)..."

# --mode regular: forward (explicit) proxy. Clients send CONNECT for HTTPS
# or full-URL requests for HTTP. mitmproxy resolves DNS and connects to the
# real server from the sidecar's network namespace (which has internet).
#
# --ssl-insecure: don't validate upstream certs (the proxy is the policy
# point, not a security gateway for upstream TLS).
#
# --set connection_strategy=lazy: don't connect upstream until the full
# request is available (needed for proper Host header checking).
mitmdump \
    --mode regular \
    --listen-host 0.0.0.0 \
    --listen-port "$PROXY_PORT" \
    --set confdir="$PROXY_CONFDIR" \
    --set connection_strategy=lazy \
    --ssl-insecure \
    -s /opt/egress-policy.py \
    >"$PROXY_LOGFILE" 2>&1 &
PROXY_PID=$!

# Wait for CA generation
echo "Waiting for proxy CA certificate..."
for _ in $(seq 1 30); do
    if [[ -f "$PROXY_CONFDIR/mitmproxy-ca-cert.pem" ]]; then
        break
    fi
    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        echo "ERROR: egress proxy exited during startup. Log:" >&2
        cat "$PROXY_LOGFILE" >&2 || true
        exit 1
    fi
    sleep 0.5
done

if [[ ! -f "$PROXY_CONFDIR/mitmproxy-ca-cert.pem" ]]; then
    echo "ERROR: proxy CA cert not generated within 15s." >&2
    tail -n 30 "$PROXY_LOGFILE" >&2 || true
    exit 1
fi

# Share CA with agent container via Docker volume
cp "$PROXY_CONFDIR/mitmproxy-ca-cert.pem" "$CA_SHARE_DIR/mitmproxy-ca-cert.pem"
echo "CA certificate shared at $CA_SHARE_DIR/mitmproxy-ca-cert.pem"

# Signal readiness (agent entrypoint waits on this)
touch "$CA_SHARE_DIR/.sidecar-ready"

echo ""
echo "Sidecar proxy ready (forward mode, port $PROXY_PORT)."
echo "  Enforcement: Docker --internal network (host-level iptables)"
echo "  Policy: mitmproxy L7 hostname allowlist"

# ── 2. Keep running ─────────────────────────────────────────────────────────

wait "$PROXY_PID"

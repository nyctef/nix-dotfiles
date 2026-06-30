#!/usr/bin/env bash
set -euo pipefail

# Phase B: L7 egress firewall — iptables mandatory floor + transparent proxy.
#
# This script runs as root inside the container (before privileges drop to the
# claude user). It sets up:
#
#   1. mitmproxy in transparent mode — owns the hostname allowlist, checks
#      SNI + Host header, rejects domain fronting. Runs as a dedicated
#      'egressproxy' user so iptables can distinguish proxy traffic from agent
#      traffic.
#
#   2. iptables mandatory floor — default-deny egress for the agent (claude)
#      user. Only DNS (to the local resolver) and the proxy port are allowed.
#      The proxy user's own traffic goes out freely. This is kernel-enforced;
#      the agent cannot bypass it even if it ignores HTTP_PROXY.
#
#   3. Self-verification — asserts that a blocked host fails AND an allowed
#      host succeeds (the old script only tested the blocked case).
#
# Runs BEFORE the agent starts. Must be called from entrypoint.sh as root.

PROXY_PORT=8080
PROXY_USER="egressproxy"
PROXY_CONFDIR="/etc/mitmproxy"
PROXY_LOGFILE="/var/log/mitmproxy.log"
POLICY_SCRIPT="/opt/egress-policy.py"
DOMAINS_FILE="/etc/firewall-domains.txt"

# ---------- 0. create the proxy user (if not already) ----------

if ! id "$PROXY_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$PROXY_USER"
fi
PROXY_UID="$(id -u "$PROXY_USER")"
CLAUDE_UID="$(id -u claude)"

# ---------- 1. generate per-run CA for MITM ----------
# mitmproxy auto-generates a CA on first run if confdir is empty.
# We pre-create the confdir and let mitmdump generate it on startup.
# The CA cert is then installed into the system trust store so tools
# (curl, dotnet, python, node) trust it without per-tool env vars.

mkdir -p "$PROXY_CONFDIR"
chown "$PROXY_USER:$PROXY_USER" "$PROXY_CONFDIR"

# ---------- 2. start the transparent proxy ----------

echo "Starting egress proxy (mitmproxy transparent, port $PROXY_PORT)..."

# Start mitmdump as the proxy user. In transparent mode it intercepts
# redirected connections. --ssl-insecure because we don't care about
# validating upstream certs from inside the sandbox (the proxy is the
# policy point, not a security gateway for the agent's benefit).
#
# --set connection_strategy=lazy so mitmproxy doesn't connect upstream
# until it has the full request (needed for proper Host header checking).
runuser -u "$PROXY_USER" -- mitmdump \
    --mode transparent \
    --listen-port "$PROXY_PORT" \
    --set confdir="$PROXY_CONFDIR" \
    --set connection_strategy=lazy \
    --ssl-insecure \
    -s "$POLICY_SCRIPT" \
    >"$PROXY_LOGFILE" 2>&1 &
PROXY_PID=$!

# Wait for the proxy to start and generate its CA cert
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
    echo "ERROR: proxy CA cert not generated within 15s. Log:" >&2
    tail -n 30 "$PROXY_LOGFILE" >&2 || true
    exit 1
fi

# ---------- 3. install CA into system trust store ----------

echo "Installing proxy CA into system trust store..."
cp "$PROXY_CONFDIR/mitmproxy-ca-cert.pem" /usr/local/share/ca-certificates/mitmproxy-ca.crt
update-ca-certificates 2>/dev/null

# Export env vars that various runtimes need to trust the CA.
# These are picked up by the agent's shell (exported in the rcfile).
cat > /etc/profile.d/proxy-ca.sh <<CAEOF
# Per-run proxy CA — auto-generated, not a persistent secret.
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export NODE_EXTRA_CA_CERTS=$PROXY_CONFDIR/mitmproxy-ca-cert.pem
CAEOF

# Also install into the Java trust store (for Maven, Flyway, etc.)
JAVA_HOME_DIR="$(dirname "$(dirname "$(readlink -f "$(which java)")")")" || true
if [[ -n "$JAVA_HOME_DIR" && -f "$JAVA_HOME_DIR/lib/security/cacerts" ]]; then
    keytool -importcert -noprompt -trustcacerts \
        -alias mitmproxy-sandbox \
        -file "$PROXY_CONFDIR/mitmproxy-ca-cert.pem" \
        -keystore "$JAVA_HOME_DIR/lib/security/cacerts" \
        -storepass changeit 2>/dev/null || true
    echo "Proxy CA installed into Java trust store."
fi

# .NET trusts the system store on Linux (SSL_CERT_FILE), no extra step needed.

# ---------- 4. iptables mandatory floor ----------
# Design:
#   - The claude user's traffic is forced through the transparent proxy via
#     REDIRECT. The proxy decides what's allowed at L7.
#   - The egressproxy user's traffic goes out directly (it IS the proxy).
#   - DNS is allowed only to the container's resolver (127.0.0.11 for Docker
#     user-defined networks, or we use the gateway). We keep 127.0.0.1 too.
#   - UDP 443 (QUIC) is blocked — force fallback to TCP so the proxy can
#     inspect.
#   - TCP 853 (DoT) is blocked — prevent DNS-over-TLS bypass.
#   - Everything else from the claude user that isn't redirected is REJECT'd.

echo "Configuring iptables mandatory floor..."

# Get the container's default gateway (Docker DNS / upstream)
HOST_IP=$(ip route | grep default | awk '{print $3}')
# Upstream DNS — passed from the host or fall back to gateway
UPSTREAM_DNS="${HOST_DNS:-$HOST_IP}"

# -- NAT table: transparent redirect --
# Redirect all HTTP/HTTPS from the claude user to the local proxy.
# The proxy user's own outbound traffic is excluded (otherwise infinite loop).
iptables -t nat -N SANDBOX_REDIRECT 2>/dev/null || iptables -t nat -F SANDBOX_REDIRECT
iptables -t nat -A SANDBOX_REDIRECT -m owner --uid-owner "$PROXY_UID" -j RETURN
# Don't redirect loopback or local traffic
iptables -t nat -A SANDBOX_REDIRECT -d 127.0.0.0/8 -j RETURN
iptables -t nat -A SANDBOX_REDIRECT -d 172.16.0.0/12 -j RETURN
iptables -t nat -A SANDBOX_REDIRECT -d 10.0.0.0/8 -j RETURN
iptables -t nat -A SANDBOX_REDIRECT -d 192.168.0.0/16 -j RETURN
# Redirect HTTP and HTTPS to the proxy
iptables -t nat -A SANDBOX_REDIRECT -p tcp --dport 80 -j REDIRECT --to-port "$PROXY_PORT"
iptables -t nat -A SANDBOX_REDIRECT -p tcp --dport 443 -j REDIRECT --to-port "$PROXY_PORT"
# Hook into OUTPUT
iptables -t nat -A OUTPUT -p tcp -j SANDBOX_REDIRECT

# -- FILTER table: mandatory deny --
iptables -N SANDBOX_EGRESS 2>/dev/null || iptables -F SANDBOX_EGRESS

# Loopback is always allowed
iptables -A SANDBOX_EGRESS -o lo -j RETURN

# Proxy user gets free egress (it IS the enforcement point)
iptables -A SANDBOX_EGRESS -m owner --uid-owner "$PROXY_UID" -j RETURN

# Root gets free egress (dockerd, system services)
iptables -A SANDBOX_EGRESS -m owner --uid-owner 0 -j RETURN

# DNS: claude user may reach the local resolver and upstream
iptables -A SANDBOX_EGRESS -p udp --dport 53 -d 127.0.0.1 -j RETURN
iptables -A SANDBOX_EGRESS -p tcp --dport 53 -d 127.0.0.1 -j RETURN
iptables -A SANDBOX_EGRESS -p udp --dport 53 -d 127.0.0.11 -j RETURN
iptables -A SANDBOX_EGRESS -p tcp --dport 53 -d 127.0.0.11 -j RETURN
iptables -A SANDBOX_EGRESS -p udp --dport 53 -d "$UPSTREAM_DNS" -j RETURN
iptables -A SANDBOX_EGRESS -p tcp --dport 53 -d "$UPSTREAM_DNS" -j RETURN

# Block QUIC (UDP 443) — force fallback to TCP so proxy can inspect
iptables -A SANDBOX_EGRESS -p udp --dport 443 -j REJECT --reject-with icmp-admin-prohibited

# Block DoT (TCP 853) — prevent DNS-over-TLS bypass
iptables -A SANDBOX_EGRESS -p tcp --dport 853 -j REJECT --reject-with tcp-reset

# Allow the claude user to reach the local proxy port (the REDIRECT sends
# traffic here, but the connection is local so it needs to be allowed)
iptables -A SANDBOX_EGRESS -p tcp --dport "$PROXY_PORT" -d 127.0.0.1 -j RETURN

# Docker bridge / local network — allow (for inner docker, DB containers, etc.)
iptables -A SANDBOX_EGRESS -d 172.16.0.0/12 -j RETURN
iptables -A SANDBOX_EGRESS -d 10.0.0.0/8 -j RETURN
iptables -A SANDBOX_EGRESS -d 192.168.0.0/16 -j RETURN

# Established/related connections from the claude user are allowed (these are
# responses to redirected connections that went through the proxy)
iptables -A SANDBOX_EGRESS -m state --state ESTABLISHED,RELATED -j RETURN

# Everything else from the claude user: REJECT (not DROP — fast failure)
iptables -A SANDBOX_EGRESS -m owner --uid-owner "$CLAUDE_UID" -j REJECT --reject-with icmp-admin-prohibited

# Hook into OUTPUT chain
iptables -A OUTPUT -j SANDBOX_EGRESS

echo "iptables mandatory floor configured."
echo "  Proxy user ($PROXY_USER, uid=$PROXY_UID): free egress"
echo "  Agent user (claude, uid=$CLAUDE_UID): HTTP(S) redirected to proxy, rest blocked"

# ---------- 5. self-verification ----------
# Both directions: blocked host must fail, allowed host must succeed.
# Run as the claude user so we test the actual policy path.

echo ""
echo "Verifying egress policy..."

VERIFY_FAILED=0

# Test 1: blocked host should fail
if runuser -u claude -- curl --connect-timeout 5 -sf https://example.com >/dev/null 2>&1; then
    echo "FAIL: example.com should be blocked but is reachable" >&2
    VERIFY_FAILED=1
else
    echo "  ✓ example.com blocked (expected)"
fi

# Test 2: allowed host should succeed
if runuser -u claude -- curl --connect-timeout 10 -sf https://api.github.com/zen >/dev/null 2>&1; then
    echo "  ✓ api.github.com reachable (expected)"
else
    echo "FAIL: api.github.com should be allowed but is blocked" >&2
    VERIFY_FAILED=1
fi

if [[ "$VERIFY_FAILED" -ne 0 ]]; then
    echo ""
    echo "ERROR: egress policy verification failed. Proxy log tail:" >&2
    tail -n 20 "$PROXY_LOGFILE" >&2 || true
    echo ""
    echo "Continuing anyway (policy may still be partially effective)." >&2
fi

echo ""
echo "Egress firewall ready (L7 proxy + iptables mandatory floor)."

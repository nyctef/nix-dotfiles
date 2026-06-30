#!/usr/bin/env bash
set -euo pipefail

# Phase B: L7 egress firewall — iptables mandatory floor + transparent proxy.
#
# This script runs as root inside the container (before privileges drop to the
# claude user). It supports two sub-commands, called at different points in the
# entrypoint to get the startup ordering right:
#
#   init-egress-firewall.sh start-proxy
#     Starts mitmproxy, waits for CA generation, installs the CA into the
#     system trust store and Java keystore. Must run BEFORE dockerd starts
#     so dockerd picks up the MITM CA on its first registry connection.
#
#   init-egress-firewall.sh start-firewall
#     Configures the iptables mandatory floor + NAT REDIRECT. Must run
#     AFTER dockerd is ready (so the self-verification can test docker pull).
#
# Entrypoint sequence:
#   1. start-proxy     → proxy running, CA installed
#   2. start dockerd   → dockerd trusts the MITM CA from the system store
#   3. start-firewall  → iptables redirect ALL uids (incl root) through proxy
#
# This ordering is critical: root (uid 0) traffic is redirected through the
# proxy, which closes the escalation gap where claude could gain root (via
# docker group or sudo) and bypass the firewall. Dockerd/containerd trust the
# proxy's CA because it was installed before they started.

PROXY_PORT=8080
PROXY_USER="egressproxy"
PROXY_CONFDIR="/etc/mitmproxy"
PROXY_LOGFILE="/var/log/mitmproxy.log"
POLICY_SCRIPT="/opt/egress-policy.py"
DOMAINS_FILE="/etc/firewall-domains.txt"

# ═══════════════════════════════════════════════════════════════════════════════
# start-proxy: launch mitmproxy + install CA
# ═══════════════════════════════════════════════════════════════════════════════

cmd_start_proxy() {
    # ---------- 0. create the proxy user (if not already) ----------

    if ! id "$PROXY_USER" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$PROXY_USER"
    fi

    # ---------- 1. prepare confdir ----------

    mkdir -p "$PROXY_CONFDIR"
    chown "$PROXY_USER:$PROXY_USER" "$PROXY_CONFDIR"

    # ---------- 2. start the transparent proxy ----------

    echo "Starting egress proxy (mitmproxy transparent, port $PROXY_PORT)..."

    # --ssl-insecure: we don't care about validating upstream certs from inside
    # the sandbox (the proxy is the policy point, not a security gateway).
    # --set connection_strategy=lazy: don't connect upstream until the full
    # request is available (needed for proper Host header checking).
    runuser -u "$PROXY_USER" -- mitmdump \
        --mode transparent \
        --listen-port "$PROXY_PORT" \
        --set confdir="$PROXY_CONFDIR" \
        --set connection_strategy=lazy \
        --ssl-insecure \
        -s "$POLICY_SCRIPT" \
        >"$PROXY_LOGFILE" 2>&1 &
    PROXY_PID=$!

    # Wait for the CA cert to be generated
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
    # This MUST happen before dockerd starts. Go's crypto/x509 on Linux reads
    # /etc/ssl/certs/ca-certificates.crt per-connection (not cached at process
    # start), so dockerd will trust the MITM CA from its very first registry
    # pull.

    echo "Installing proxy CA into system trust store..."
    cp "$PROXY_CONFDIR/mitmproxy-ca-cert.pem" /usr/local/share/ca-certificates/mitmproxy-ca.crt
    update-ca-certificates 2>/dev/null

    # Export env vars that various runtimes need to trust the CA.
    cat > /etc/profile.d/proxy-ca.sh <<CAEOF
# Per-run proxy CA — auto-generated, not a persistent secret.
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export NODE_EXTRA_CA_CERTS=$PROXY_CONFDIR/mitmproxy-ca-cert.pem
CAEOF

    # Java trust store (for Maven, Flyway, etc.)
    local java_home
    java_home="$(dirname "$(dirname "$(readlink -f "$(which java)")")")" || true
    if [[ -n "$java_home" && -f "$java_home/lib/security/cacerts" ]]; then
        keytool -importcert -noprompt -trustcacerts \
            -alias mitmproxy-sandbox \
            -file "$PROXY_CONFDIR/mitmproxy-ca-cert.pem" \
            -keystore "$java_home/lib/security/cacerts" \
            -storepass changeit 2>/dev/null || true
        echo "Proxy CA installed into Java trust store."
    fi

    echo "Proxy ready (CA installed into system trust store)."
}

# ═══════════════════════════════════════════════════════════════════════════════
# start-firewall: configure iptables mandatory floor
# ═══════════════════════════════════════════════════════════════════════════════

cmd_start_firewall() {
    local PROXY_UID CLAUDE_UID
    PROXY_UID="$(id -u "$PROXY_USER")"
    CLAUDE_UID="$(id -u claude)"

    echo "Configuring iptables mandatory floor..."

    # Get the container's default gateway (Docker DNS / upstream)
    local HOST_IP UPSTREAM_DNS
    HOST_IP=$(ip route | grep default | awk '{print $3}')
    UPSTREAM_DNS="${HOST_DNS:-$HOST_IP}"

    # -- NAT table: transparent redirect --
    # Redirect HTTP/HTTPS from ALL users to the proxy. Only the proxy user
    # itself is exempted (otherwise infinite loop).
    #
    # Root (uid 0) is NOT exempted. This is intentional: dockerd/containerd
    # trust the MITM CA (installed before they started), and this closes the
    # escalation gap where the agent gains root and bypasses the firewall.
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

    # -- FILTER table: default-deny egress --
    iptables -N SANDBOX_EGRESS 2>/dev/null || iptables -F SANDBOX_EGRESS

    # Loopback is always allowed
    iptables -A SANDBOX_EGRESS -o lo -j RETURN

    # Proxy user gets free egress (it IS the enforcement point)
    iptables -A SANDBOX_EGRESS -m owner --uid-owner "$PROXY_UID" -j RETURN

    # DNS: all users may reach the local resolver and upstream
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

    # Local proxy port — needed because REDIRECT makes the connection local
    iptables -A SANDBOX_EGRESS -p tcp --dport "$PROXY_PORT" -d 127.0.0.1 -j RETURN

    # Docker bridge / local network — allow (inner docker, DB containers, etc.)
    iptables -A SANDBOX_EGRESS -d 172.16.0.0/12 -j RETURN
    iptables -A SANDBOX_EGRESS -d 10.0.0.0/8 -j RETURN
    iptables -A SANDBOX_EGRESS -d 192.168.0.0/16 -j RETURN

    # Established/related — allow (responses to proxied connections)
    iptables -A SANDBOX_EGRESS -m state --state ESTABLISHED,RELATED -j RETURN

    # Default deny: REJECT everything else (fast failure, not silent DROP).
    # This applies to ALL uids except the proxy user. Root is not exempted —
    # even if the agent escalates to root, non-HTTP traffic is still blocked.
    iptables -A SANDBOX_EGRESS -j REJECT --reject-with icmp-admin-prohibited

    # Hook into OUTPUT chain
    iptables -A OUTPUT -j SANDBOX_EGRESS

    # -- FORWARD chain: block nested containers from reaching the internet --
    # Inner dockerd creates a docker0 bridge and MASQUERADEs traffic from
    # nested containers. That traffic goes through FORWARD, not OUTPUT, so
    # our OUTPUT rules don't catch it. We need a parallel set of rules here.
    #
    # Allow: container↔container traffic on private networks (docker bridges)
    # Allow: established/related (responses to allowed connections)
    # Block: everything else outbound (to non-private destinations)
    iptables -N SANDBOX_FORWARD 2>/dev/null || iptables -F SANDBOX_FORWARD

    # Container↔container on private networks is fine
    iptables -A SANDBOX_FORWARD -d 172.16.0.0/12 -j RETURN
    iptables -A SANDBOX_FORWARD -d 10.0.0.0/8 -j RETURN
    iptables -A SANDBOX_FORWARD -d 192.168.0.0/16 -j RETURN

    # Established/related responses
    iptables -A SANDBOX_FORWARD -m state --state ESTABLISHED,RELATED -j RETURN

    # DNS is allowed (so nested containers can resolve)
    iptables -A SANDBOX_FORWARD -p udp --dport 53 -j RETURN
    iptables -A SANDBOX_FORWARD -p tcp --dport 53 -j RETURN

    # Block everything else (internet-bound traffic from nested containers)
    iptables -A SANDBOX_FORWARD -j REJECT --reject-with icmp-admin-prohibited

    # Insert at the TOP of FORWARD — dockerd adds its own FORWARD rules
    # (DOCKER-USER, DOCKER chains) when it starts, and those allow container
    # traffic. We must come before them.
    iptables -I FORWARD 1 -j SANDBOX_FORWARD

    echo "iptables mandatory floor configured."
    echo "  Proxy user ($PROXY_USER, uid=$PROXY_UID): free egress"
    echo "  All other users (incl root): HTTP(S) redirected to proxy, rest blocked"

    # ---------- self-verification ----------
    echo ""
    echo "Verifying egress policy..."

    local VERIFY_FAILED=0

    # Test 1: blocked host should fail (as claude)
    if runuser -u claude -- curl --connect-timeout 5 -sf https://example.com >/dev/null 2>&1; then
        echo "FAIL: example.com should be blocked but is reachable" >&2
        VERIFY_FAILED=1
    else
        echo "  ✓ example.com blocked (expected)"
    fi

    # Test 2: allowed host should succeed (as claude)
    if runuser -u claude -- curl --connect-timeout 10 -sf https://api.github.com/zen >/dev/null 2>&1; then
        echo "  ✓ api.github.com reachable (expected)"
    else
        echo "FAIL: api.github.com should be allowed but is blocked" >&2
        VERIFY_FAILED=1
    fi

    # Test 3: root traffic also goes through the proxy (the key fix)
    if curl --connect-timeout 5 -sf https://example.com >/dev/null 2>&1; then
        echo "FAIL: example.com reachable as root — proxy bypass!" >&2
        VERIFY_FAILED=1
    else
        echo "  ✓ example.com blocked as root (no uid 0 bypass)"
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
}

# ═══════════════════════════════════════════════════════════════════════════════
# dispatch
# ═══════════════════════════════════════════════════════════════════════════════

case "${1:-}" in
    start-proxy)    cmd_start_proxy ;;
    start-firewall) cmd_start_firewall ;;
    *)
        echo "Usage: $0 {start-proxy|start-firewall}" >&2
        exit 1
        ;;
esac

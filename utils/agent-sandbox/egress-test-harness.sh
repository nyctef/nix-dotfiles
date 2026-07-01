#!/usr/bin/env bash
# In-container test harness for the sandbox network stack (Phase B.1: sidecar).
#
# Runs as the `claude` user (the "adversary" in our threat model). Tests the
# full Phase B.1 egress policy: sidecar L7 proxy, network topology isolation,
# CA trust, privilege separation, and inner dockerd.
#
# Phase B.1 key improvement: the proxy runs in a SEPARATE sidecar container.
# The agent's only route to the internet is through the sidecar. Even if the
# agent gains root and flushes iptables inside its own container, the sidecar's
# enforcement is unreachable. This eliminates the iptables-flush escape that
# was a residual risk in Phase B.
#
# Exit code: number of failed tests (0 = all passed).

set -uo pipefail

# ── colour / output helpers ──────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { ((PASS_COUNT++)); echo -e "  ${GREEN}✓${RESET} $1"; }
fail() { ((FAIL_COUNT++)); echo -e "  ${RED}✗${RESET} $1"; }
skip() { ((SKIP_COUNT++)); echo -e "  ${YELLOW}⊘${RESET} $1 ${YELLOW}(skipped)${RESET}"; }
section() { echo -e "\n${BOLD}${CYAN}── $1 ──${RESET}"; }

# ── helpers ──────────────────────────────────────────────────────────────────

# Expect curl to connect to an allowed host. We care that the proxy allowed
# the connection, not that the server returned 200 — a 404 from the real server
# is fine (it means the proxy let it through). curl -sf fails on both connection
# errors AND HTTP errors (exit 22), so we use -o /dev/null -w '%{http_code}'
# and check: any HTTP status > 0 means the proxy allowed it.
expect_allowed() {
    local label="$1" url="$2"; shift 2
    local http_code
    http_code="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 5 --max-time 10 "$@" "$url" 2>/dev/null)" || true
    if [[ "$http_code" =~ ^[0-9]+$ && "$http_code" -gt 0 && "$http_code" -ne 403 ]]; then
        pass "$label (HTTP $http_code)"
    elif [[ "$http_code" == "403" ]]; then
        fail "$label (HTTP 403 — proxy blocked it)"
    else
        fail "$label (connection failed, http_code=$http_code)"
    fi
}

# Expect curl to fail for a blocked host — either connection refused, proxy 403,
# or timeout.
expect_blocked() {
    local label="$1" url="$2"; shift 2
    local body status
    body="$(curl -sf --connect-timeout 5 --max-time 10 "$@" "$url" 2>&1)" && status=0 || status=$?
    if [[ $status -ne 0 ]]; then
        pass "$label"
    else
        fail "$label (expected block, but curl succeeded)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "\n${BOLD}Agent Sandbox Network Test Harness (Phase B.1: Sidecar Proxy)${RESET}"
echo "Running as: $(whoami) (uid=$(id -u))"
echo "Date:       $(date -Iseconds)"
echo "Sidecar IP: ${SANDBOX_SIDECAR_IP:-<not set>}"
echo ""

# ── 1. Allowed HTTPS hosts ───────────────────────────────────────────────────

section "Allowed HTTPS hosts (should succeed)"

expect_allowed "api.github.com (REST)" \
    "https://api.github.com/zen"

expect_allowed "github.com (HTML)" \
    "https://github.com/robots.txt"

expect_allowed "api.nuget.org (package registry)" \
    "https://api.nuget.org/v3/index.json"

expect_allowed "registry.npmjs.org (npm)" \
    "https://registry.npmjs.org/"

expect_allowed "pypi.org (Python)" \
    "https://pypi.org/simple/"

expect_allowed "repo1.maven.org (Maven)" \
    "https://repo1.maven.org/maven2/"

# ── 2. Allowed HTTPS subdomains ──────────────────────────────────────────────

section "Subdomain matching (subdomains of allowed domains)"

expect_allowed "objects.githubusercontent.com (GitHub subdomain)" \
    "https://objects.githubusercontent.com/"

expect_allowed "raw.githubusercontent.com (GitHub subdomain)" \
    "https://raw.githubusercontent.com/"

# ── 3. Blocked HTTPS hosts ──────────────────────────────────────────────────

section "Blocked HTTPS hosts (should fail with 403 or connection error)"

expect_blocked "example.com (not in allowlist)" \
    "https://example.com"

expect_blocked "evil.com (not in allowlist)" \
    "https://evil.com"

expect_blocked "httpbin.org (not in allowlist)" \
    "https://httpbin.org/get"

expect_blocked "ifconfig.me (potential exfil)" \
    "https://ifconfig.me"

expect_blocked "pastebin.com (potential exfil)" \
    "https://pastebin.com"

expect_blocked "webhook.site (potential C2)" \
    "https://webhook.site"

# ── 4. Blocked HTTP (plaintext, port 80) ────────────────────────────────────

section "Blocked HTTP (plaintext, port 80)"

expect_blocked "http://example.com (HTTP, not in allowlist)" \
    "http://example.com"

expect_blocked "http://httpbin.org/get (HTTP, not in allowlist)" \
    "http://httpbin.org/get"

# ── 5. Allowed HTTP (plaintext, port 80) ────────────────────────────────────

section "Allowed HTTP (plaintext, port 80)"

# Ubuntu archive is HTTP-only in many mirrors
expect_allowed "http://archive.ubuntu.com (apt mirror)" \
    "http://archive.ubuntu.com/ubuntu/dists/noble/Release.gpg"

# ── 6. QUIC / UDP 443 blocked ───────────────────────────────────────────────

section "QUIC / UDP 443 (should be blocked to force TCP fallback)"

# nc -u with a timeout: if REJECT'd, we get an immediate error (ICMP).
if command -v nc &>/dev/null; then
    if echo "test" | nc -u -w 2 8.8.8.8 443 2>&1 | grep -qi "refused\|unreachable\|not permitted" ||
       ! echo "test" | nc -u -w 2 8.8.8.8 443 >/dev/null 2>&1; then
        pass "UDP 443 blocked (REJECT)"
    else
        fail "UDP 443 might be open"
    fi
else
    if curl --help all 2>&1 | grep -q -- '--http3'; then
        if curl --http3-only --connect-timeout 3 -sf https://cloudflare.com >/dev/null 2>&1; then
            fail "QUIC/HTTP3 succeeded (should be blocked)"
        else
            pass "QUIC/HTTP3 blocked"
        fi
    else
        skip "UDP 443 / QUIC (no nc or curl --http3 available)"
    fi
fi

# ── 7. DoT / TCP 853 blocked ────────────────────────────────────────────────

section "DNS-over-TLS / TCP 853 (should be blocked)"

if command -v nc &>/dev/null; then
    if nc -z -w 2 1.1.1.1 853 2>/dev/null; then
        fail "TCP 853 (DoT) is open — should be blocked"
    else
        pass "TCP 853 (DoT) blocked"
    fi
elif command -v timeout &>/dev/null; then
    if timeout 3 bash -c 'echo >/dev/tcp/1.1.1.1/853' 2>/dev/null; then
        fail "TCP 853 (DoT) is open — should be blocked"
    else
        pass "TCP 853 (DoT) blocked"
    fi
else
    skip "DoT / TCP 853 (no nc or /dev/tcp)"
fi

# ── 8. Raw TCP to non-HTTP ports blocked ────────────────────────────────────

section "Raw TCP to non-HTTP ports (should be blocked)"

# Try SSH (port 22) to a public host
if command -v nc &>/dev/null; then
    if nc -z -w 3 github.com 22 2>/dev/null; then
        fail "TCP 22 (SSH) to github.com is open — should be blocked"
    else
        pass "TCP 22 (SSH) to github.com blocked"
    fi
else
    if timeout 3 bash -c 'echo >/dev/tcp/github.com/22' 2>/dev/null; then
        fail "TCP 22 (SSH) to github.com is open — should be blocked"
    else
        pass "TCP 22 (SSH) to github.com blocked"
    fi
fi

# Try SMTP (port 25)
if timeout 3 bash -c 'echo >/dev/tcp/smtp.gmail.com/25' 2>/dev/null; then
    fail "TCP 25 (SMTP) is open — should be blocked"
else
    pass "TCP 25 (SMTP) blocked"
fi

# Try arbitrary high port
if timeout 3 bash -c 'echo >/dev/tcp/example.com/8443' 2>/dev/null; then
    fail "TCP 8443 to example.com is open — should be blocked"
else
    pass "TCP 8443 (arbitrary) blocked"
fi

# ── 9. DNS resolution ───────────────────────────────────────────────────────

section "DNS resolution (should work for all domains, policy is at L7)"

if command -v dig &>/dev/null; then
    # Allowed domain
    if dig +short +timeout=3 api.github.com A 2>/dev/null | grep -qE '^[0-9]+\.'; then
        pass "DNS resolves api.github.com"
    else
        fail "DNS failed for api.github.com"
    fi

    # Blocked domain — DNS should still resolve (blocking is at L7, not DNS)
    if dig +short +timeout=3 example.com A 2>/dev/null | grep -qE '^[0-9]+\.'; then
        pass "DNS resolves example.com (blocked at L7, not DNS)"
    else
        fail "DNS failed for example.com (should resolve; L7 blocks, not DNS)"
    fi
else
    skip "DNS resolution — dig not available"
fi

# ── 10. Proxy CA trust ──────────────────────────────────────────────────────

section "Proxy CA trust (TLS should work without --insecure)"

# curl should trust the MITM CA via SSL_CERT_FILE / CURL_CA_BUNDLE
if curl -sf --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    pass "curl trusts proxy CA (no --insecure needed)"
else
    # Is it a CA problem specifically?
    if curl -sf --insecure --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
        fail "curl doesn't trust proxy CA (works with --insecure)"
    else
        fail "curl can't reach api.github.com at all (not a CA issue)"
    fi
fi

# Python (requests / urllib3)
if command -v python3 &>/dev/null; then
    if python3 -c "
import urllib.request, ssl
ctx = ssl.create_default_context()
urllib.request.urlopen('https://api.github.com/zen', timeout=10, context=ctx)
" 2>/dev/null; then
        pass "python3 urllib trusts proxy CA"
    else
        fail "python3 urllib doesn't trust proxy CA"
    fi
else
    skip "python3 urllib CA trust — python3 not available"
fi

# Check the env vars are set
if [[ -n "${SSL_CERT_FILE:-}" ]]; then
    pass "SSL_CERT_FILE is set ($SSL_CERT_FILE)"
else
    fail "SSL_CERT_FILE not set"
fi

if [[ -n "${NODE_EXTRA_CA_CERTS:-}" ]]; then
    pass "NODE_EXTRA_CA_CERTS is set ($NODE_EXTRA_CA_CERTS)"
else
    fail "NODE_EXTRA_CA_CERTS not set"
fi

# ── 11. Privilege separation (sidecar isolation) ────────────────────────────

section "Privilege separation (sidecar proxy is unreachable)"

# In Phase B.1, the proxy runs in a separate container. The claude user cannot
# see, kill, or modify it. These tests verify that the sidecar's enforcement
# surfaces are not accessible from inside the agent container.

# The proxy process should NOT be visible in this container
PROXY_PID="$(pgrep -f mitmdump 2>/dev/null | head -1)" || true
if [[ -n "$PROXY_PID" ]]; then
    fail "mitmdump process visible in agent container (should be in sidecar only)"
else
    pass "mitmdump process not visible (running in sidecar container)"
fi

# The domain allowlist should NOT exist in this container
if [[ -f /etc/firewall-domains.txt ]]; then
    fail "/etc/firewall-domains.txt exists in agent container (should be in sidecar only)"
else
    pass "/etc/firewall-domains.txt not present (in sidecar only)"
fi

# The egress policy script should NOT exist in this container
if [[ -f /opt/egress-policy.py ]]; then
    fail "/opt/egress-policy.py exists in agent container (should be in sidecar only)"
else
    pass "/opt/egress-policy.py not present (in sidecar only)"
fi

# sudo dpkg should be denied (tightened sudoers)
if sudo -n dpkg --version 2>/dev/null; then
    fail "claude can sudo dpkg (allows malicious .deb postinst)"
else
    pass "sudo dpkg denied for claude user"
fi

# sudo apt-get should be allowed (legitimate use)
if sudo -n apt-get --version >/dev/null 2>&1; then
    pass "sudo apt-get allowed (expected)"
else
    fail "sudo apt-get denied (agent needs this for installing packages)"
fi

# sudo root shell should be denied
if sudo -n bash -c 'whoami' 2>/dev/null | grep -q root; then
    fail "claude can sudo to root shell (CRITICAL)"
else
    pass "sudo root shell denied for claude user"
fi

# ── 12. SIDECAR ISOLATION: iptables flush does NOT bypass policy ────────────

section "Sidecar isolation (iptables flush cannot bypass policy)"

# THIS IS THE KEY TEST FOR PHASE B.1.
#
# In Phase B (in-container proxy), the agent gaining root and flushing iptables
# was a known vulnerability — it would disconnect the proxy and let all traffic
# through directly.
#
# In Phase B.1 (sidecar proxy), the enforcement is in a separate container.
# The agent's iptables rules are irrelevant — there are no iptables rules in
# the agent container that enforce egress policy. The only route to the internet
# is through the sidecar (Docker network topology, enforced by Docker's host-
# level iptables, which the agent cannot modify).
#
# This test verifies that even with full iptables access (which sysbox grants
# to root for inner dockerd's bridge creation), the policy still holds.

# claude user shouldn't be able to flush iptables (no sudo permission)
if iptables -F 2>/dev/null; then
    # If it succeeded, that's fine in Phase B.1 — it doesn't matter
    echo "  (note: iptables -F succeeded as claude — harmless in sidecar model)"
else
    pass "iptables -F denied for claude user (as expected)"
fi

# The definitive test: verify blocked hosts are STILL blocked.
# In Phase B, these would succeed after an iptables flush.
# In Phase B.1, they remain blocked because the sidecar enforces policy.
expect_blocked "example.com still blocked (enforcement is in sidecar, not local iptables)" \
    "https://example.com"

expect_allowed "api.github.com still works (sidecar routes allowed traffic)" \
    "https://api.github.com/zen"

# Verify there are no egress-related iptables rules in this container
# (confirming that enforcement is external)
if iptables -L -n 2>/dev/null; then
    # If we can list rules, check there's no SANDBOX chain
    if iptables -L -n 2>/dev/null | grep -q "SANDBOX"; then
        fail "SANDBOX iptables chain found in agent container (should be in sidecar)"
    else
        pass "no SANDBOX iptables chains in agent container (enforcement is external)"
    fi
else
    pass "iptables not accessible to claude (enforcement is external)"
fi

# ── 13. Root escalation via nested container ────────────────────────────────

section "Root escalation (gaining root must not bypass sidecar)"

# docker run as root inside a nested container — the classic escalation.
# Traffic still routes through the sidecar because the Docker network topology
# is the enforcement boundary, not iptables rules.
if docker run --rm alpine sh -c \
    'apk add --no-cache curl >/dev/null 2>&1 && curl -sf --connect-timeout 5 https://example.com' \
    >/dev/null 2>&1; then
    fail "nested root container reached blocked host (sidecar bypass!)"
else
    pass "nested root container blocked from example.com"
fi

if docker run --rm --user root alpine sh -c \
    'apk add --no-cache curl >/dev/null 2>&1 && curl -sf --connect-timeout 5 https://example.com' \
    >/dev/null 2>&1; then
    fail "nested --user root container reached blocked host"
else
    pass "nested --user root container blocked from example.com"
fi

# Verify that root CAN reach allowed hosts (dockerd needs this for pulls)
if docker run --rm alpine sh -c \
    'apk add --no-cache curl >/dev/null 2>&1 && curl -sf --connect-timeout 10 https://api.github.com/zen' \
    >/dev/null 2>&1; then
    pass "nested container can reach allowed host (api.github.com)"
else
    # Might fail because the nested container doesn't have the MITM CA —
    # acceptable; the important thing is blocked hosts are blocked.
    skip "nested container → allowed host failed (expected: no MITM CA in nested image)"
fi

# ── 14. Domain fronting (Host ≠ SNI) ────────────────────────────────────────

section "Domain fronting detection (Host header ≠ SNI)"

# Connect to github.com's IP but send Host/SNI for evil.com — the sidecar's
# proxy should block based on the hostname, regardless of the destination IP.
GITHUB_IP="$(dig +short +timeout=3 github.com A 2>/dev/null | head -1)" || true
if [[ -n "$GITHUB_IP" && "$GITHUB_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if curl -sf --connect-timeout 5 --max-time 10 \
        --resolve "evil.com:443:$GITHUB_IP" \
        "https://evil.com/" >/dev/null 2>&1; then
        fail "evil.com via github.com's IP succeeded (should be blocked by hostname)"
    else
        pass "evil.com via github.com's IP blocked (L7 hostname check)"
    fi
else
    skip "domain fronting — couldn't resolve github.com IP"
fi

# ── 15. Inner Docker (sysbox nested containers) ─────────────────────────────

section "Inner Docker (sysbox nested containers)"

if [[ "${SKIP_DOCKER_TESTS:-}" == "1" ]]; then
    skip "docker tests (--no-docker flag)"
else
    # Check dockerd is running
    if docker info >/dev/null 2>&1; then
        pass "inner dockerd is running"
    else
        fail "inner dockerd not reachable"
    fi

    # Pull and run hello-world — tests that dockerd can reach Docker Hub
    # through the sidecar proxy (registry-1.docker.io is in the allowlist,
    # and dockerd trusts the MITM CA from the shared volume)
    if docker run --rm hello-world >/dev/null 2>&1; then
        pass "docker run hello-world succeeded (dockerd pulls through sidecar)"
    else
        fail "docker run hello-world failed (dockerd can't pull through sidecar?)"
    fi
fi

# ── 16. Network topology verification ───────────────────────────────────────

section "Network topology (agent on internal network only)"

# Verify the default route points to the sidecar
DEFAULT_GW="$(ip route | grep default | awk '{print $3}' | head -1)" || true
SIDECAR_IP="${SANDBOX_SIDECAR_IP:-}"
if [[ -n "$DEFAULT_GW" && "$DEFAULT_GW" == "$SIDECAR_IP" ]]; then
    pass "default route via sidecar ($DEFAULT_GW)"
elif [[ -n "$DEFAULT_GW" ]]; then
    fail "default route via $DEFAULT_GW (expected $SIDECAR_IP)"
else
    fail "no default route found"
fi

# Verify we're on an internal network (no Docker bridge gateway)
# On Docker --internal networks, there's no gateway provided by Docker itself;
# the only gateway is the one we added (the sidecar).
ROUTE_COUNT="$(ip route | grep -c default)" || true
if [[ "$ROUTE_COUNT" -le 1 ]]; then
    pass "single default route (no Docker bridge gateway bypass)"
else
    fail "multiple default routes ($ROUTE_COUNT) — potential bypass path"
fi

# ── 17. Diagnostics ─────────────────────────────────────────────────────────

section "Diagnostics"

# CA file from sidecar should be mounted read-only
if [[ -f /shared-ca/mitmproxy-ca-cert.pem ]]; then
    pass "sidecar CA cert present at /shared-ca/"
    if (echo "test" >> /shared-ca/mitmproxy-ca-cert.pem) 2>/dev/null; then
        fail "CA volume is writable (should be read-only)"
    else
        pass "CA volume is read-only"
    fi
else
    fail "sidecar CA cert not found at /shared-ca/"
fi

# Show route table for debugging
echo ""
echo "  Route table:"
ip route 2>/dev/null | sed 's/^/    /' || true

# ═════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Results: ${GREEN}${PASS_COUNT} passed${RESET}  ${RED}${FAIL_COUNT} failed${RESET}  ${YELLOW}${SKIP_COUNT} skipped${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════${RESET}"

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo -e "\n${RED}${BOLD}SOME TESTS FAILED.${RESET} Review the output above."
    echo ""
    echo "Diagnostic commands (from host):"
    echo "  docker logs agent-sandbox-sidecar-*   # sidecar proxy decisions"
    echo "  docker exec <sidecar> cat /var/log/mitmproxy.log"
    echo "  docker exec <sidecar> iptables -L -n -v"
    echo ""
    echo "Diagnostic commands (from agent container, after Ctrl-Z or 'exit'):"
    echo "  ip route                        # verify sidecar is default gateway"
    echo "  curl -v https://example.com     # trace a blocked request"
    echo ""
fi

exit "$FAIL_COUNT"

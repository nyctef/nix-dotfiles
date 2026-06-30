#!/usr/bin/env bash
# In-container test harness for the sandbox network stack.
#
# Runs as the `claude` user (the "adversary" in our threat model). Tests the
# full Phase B egress policy: L7 proxy, iptables mandatory floor, CA trust,
# privilege separation, and inner dockerd.
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

# curl with sane defaults for testing. Returns exit code; captures body+headers
# in $CURL_OUT and HTTP status in $HTTP_STATUS.
tcurl() {
    local url="$1"; shift
    CURL_OUT="$(curl -s -o /dev/null -w '%{http_code}' \
        --connect-timeout 5 --max-time 10 "$@" "$url" 2>&1)" || true
    HTTP_STATUS="$CURL_OUT"
}

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

echo -e "\n${BOLD}Agent Sandbox Network Test Harness${RESET}"
echo "Running as: $(whoami) (uid=$(id -u))"
echo "Date:       $(date -Iseconds)"
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

# curl --http3 is not always available, so we use a raw UDP check.
# nc -u with a timeout: if REJECT'd, we get an immediate error (ICMP).
if command -v nc &>/dev/null; then
    # Send a dummy UDP packet to 443 on a public IP. REJECT should give
    # immediate ICMP unreachable (exit != 0). DROP would timeout.
    if echo "test" | nc -u -w 2 8.8.8.8 443 2>&1 | grep -qi "refused\|unreachable\|not permitted" ||
       ! echo "test" | nc -u -w 2 8.8.8.8 443 >/dev/null 2>&1; then
        pass "UDP 443 blocked (REJECT)"
    else
        fail "UDP 443 might be open"
    fi
else
    # Alternative: try curl with --http3 if available
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

# Try SMTP (port 25) — use /dev/tcp as fallback
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

# ── 11. Privilege separation ────────────────────────────────────────────────

section "Privilege separation (claude user must not tamper with firewall)"

# claude should not be able to modify iptables
if iptables -L -n >/dev/null 2>&1; then
    fail "claude can list iptables rules (should require root)"
else
    pass "iptables -L denied for claude user"
fi

if iptables -F 2>/dev/null; then
    fail "claude can flush iptables (CRITICAL — firewall compromised)"
else
    pass "iptables -F denied for claude user"
fi

# claude should not be able to kill the proxy
PROXY_PID="$(pgrep -f mitmdump 2>/dev/null | head -1)" || true
if [[ -n "$PROXY_PID" ]]; then
    if kill "$PROXY_PID" 2>/dev/null; then
        fail "claude can kill the egress proxy (CRITICAL)"
    else
        pass "claude cannot kill the egress proxy (pid=$PROXY_PID)"
    fi
    # Also try SIGKILL
    if kill -9 "$PROXY_PID" 2>/dev/null; then
        fail "claude can SIGKILL the egress proxy (CRITICAL)"
    else
        pass "claude cannot SIGKILL the egress proxy"
    fi
else
    skip "proxy PID not found — can't test kill protection"
fi

# claude should not be able to modify the domain allowlist
# (bash redirection errors go to stderr before 2>/dev/null on the `if`, so
#  we wrap in a subshell to capture them)
if (echo "evil.com" >> /etc/firewall-domains.txt) 2>/dev/null; then
    fail "claude can write to /etc/firewall-domains.txt (CRITICAL)"
else
    pass "claude cannot modify /etc/firewall-domains.txt"
fi

# claude should not be able to overwrite the proxy addon
if (echo "pass" > /opt/egress-policy.py) 2>/dev/null; then
    fail "claude can overwrite /opt/egress-policy.py (CRITICAL)"
else
    pass "claude cannot modify /opt/egress-policy.py"
fi

# claude should not be able to modify iptables via sudo.
# -n = non-interactive (fail immediately, never prompt for password).
if sudo -n iptables -F 2>/dev/null; then
    fail "claude can sudo iptables -F (CRITICAL)"
else
    pass "sudo iptables denied for claude user"
fi

# claude should not be able to sudo to root shell
if sudo -n bash -c 'whoami' 2>/dev/null | grep -q root; then
    fail "claude can sudo to root shell (CRITICAL)"
else
    pass "sudo root shell denied for claude user"
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

# ── 12. Root escalation does not bypass proxy ───────────────────────────────

section "Root escalation (gaining root must not bypass proxy)"

# docker run as root inside a privileged container — the classic escalation.
# Even though claude is in the docker group, root traffic should still go
# through the proxy.
if docker run --rm alpine sh -c \
    'apk add --no-cache curl >/dev/null 2>&1 && curl -sf --connect-timeout 5 https://example.com' \
    >/dev/null 2>&1; then
    fail "nested root container reached blocked host (uid 0 bypass!)"
else
    pass "nested root container blocked from example.com"
fi

# Root traffic from docker exec (simulates gaining a root shell)
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
    # This might fail because the nested container doesn't have the MITM CA.
    # That's acceptable — the important thing is that blocked hosts are blocked.
    skip "nested container → allowed host failed (expected: no MITM CA in nested image)"
fi

# ── 13. Domain fronting (Host ≠ SNI) ────────────────────────────────────────

section "Domain fronting detection (Host header ≠ SNI)"

# This is hard to test without a custom TLS client. curl's --resolve or
# --connect-to can separate the connection target from the Host header, which
# is the closest we can get.
#
# Connect to github.com's IP but send Host: evil.com — the proxy should see
# SNI=github.com + Host=evil.com and reject.

GITHUB_IP="$(dig +short +timeout=3 github.com A 2>/dev/null | head -1)" || true
if [[ -n "$GITHUB_IP" && "$GITHUB_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    # --connect-to makes curl connect to github.com:443 but we override the
    # Host header to evil.com. The TLS SNI will be evil.com (since curl sets
    # SNI from the URL host), so this tests a different path.
    #
    # Better: use --resolve to pin evil.com -> github.com's IP, so:
    #   SNI = evil.com, Host = evil.com, connected to github.com's IP
    # This tests that evil.com is blocked even when routed to an allowed IP.
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

# ── 14. Inner Docker (sysbox nested containers) ─────────────────────────────

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
    # through the proxy (registry-1.docker.io is in the allowlist, and
    # dockerd trusts the MITM CA because it was installed before dockerd started)
    if docker run --rm hello-world >/dev/null 2>&1; then
        pass "docker run hello-world succeeded (dockerd pulls through proxy)"
    else
        fail "docker run hello-world failed (dockerd can't pull through proxy?)"
    fi
fi

# ── 15. Proxy log visibility ────────────────────────────────────────────────

section "Diagnostics"

# Check if we can read the proxy log (useful for debugging but shouldn't be
# writable by claude)
if [[ -r /var/log/mitmproxy.log ]]; then
    PROXY_LINES="$(wc -l < /var/log/mitmproxy.log)"
    pass "proxy log readable ($PROXY_LINES lines)"
else
    # Not necessarily a failure — the log might be root-owned
    skip "proxy log not readable by claude user"
fi

# Show iptables rules (if readable, useful for debugging)
if iptables -L -n 2>/dev/null; then
    : # already handled above (would be a fail)
else
    pass "iptables rules not visible to claude (as expected)"
fi

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
    echo "Diagnostic commands (from the shell after Ctrl-Z or 'exit'):"
    echo "  cat /var/log/mitmproxy.log      # proxy decisions"
    echo "  sudo iptables -L -n -v          # firewall rules + counters"
    echo "  sudo iptables -t nat -L -n -v   # NAT/redirect rules"
    echo "  curl -v https://example.com     # trace a blocked request"
    echo ""
fi

exit "$FAIL_COUNT"

# agent-sandbox

The **new** hardened sandbox for running an *untrusted AI coding agent* (Claude
Code today; pi-dev and others later) with Docker access and network egress,
without letting it reach the host or exfiltrate freely. Developed alongside the
working `utils/run-claude-docker.sh` (which stays untouched as the daily driver)
— we cut over only once this path is proven end-to-end. Informed by a
reverse-engineering study of Docker `sbx` (host-side TLS MITM proxy for
credential injection + Cedar egress policy + microVM isolation).

The launcher is split into an **agent-agnostic core** and a thin
**Claude-specific wrapper**: the core takes the agent command, extra bind
mounts, and env vars as arguments; the wrapper supplies Claude's. Adding another
agent (pi-dev) is then a sibling wrapper, no core changes. The `claude`
user/home *inside the image* is still fixed (image-level) — generalising that is
deferred.

Unlike the old single-file script, the pieces are split into separate files:

| file                    | role                                                        |
|-------------------------|-------------------------------------------------------------|
| `default.nix`           | copies the folder into the store; PATH-wraps both launchers |
| `run-claude-sandbox.sh` | Claude wrapper — claude cmd/binary/config mounts/env, then calls the core |
| `run-agent-sandbox.sh`  | **generic core** — worktree, build, network, sidecar, `docker run` |
| `Dockerfile`            | agent image — full `dockerd` inside, **no host socket**, **no proxy** |
| `Dockerfile.sidecar`    | sidecar proxy image — mitmproxy + iptables, L7 egress policy |
| `sidecar-entrypoint.sh` | in-sidecar: starts proxy, configures iptables, NAT gateway   |
| `firewall-domains.txt`  | hostname allowlist — single source of truth for L7 egress policy        |
| `egress-policy.py`      | mitmproxy addon — enforces hostname allowlist (SNI + Host), anti-fronting |
| `entrypoint.sh`         | in-agent: install CA from sidecar, start inner dockerd, set route, run agent |
| `test-sandbox-egress.sh` | test wrapper — drives the core with a test harness as the "agent"     |
| `egress-test-harness.sh` | in-container test suite — exercises every layer of the network stack   |

## Core idea

The agent container runs under `--runtime=sysbox-runc`, so it is **unprivileged
with real UID remapping** yet can run its **own dockerd nested inside**. That
gives native `dotnet test -> docker run -p` ergonomics (single netns,
`localhost`, bind mounts) without ever handing the agent the host Docker socket
(the old `--docker` flag's one-hop-to-host-root, now gone).

## Threat model (the framing that drives every decision)

- **The agent (Claude) is the adversary.** Not the test databases it spins up.
- Therefore the agent's container must be **unprivileged** and must **not** hold
  the host Docker socket. Anything that leaves the agent in a privileged
  container (incl. single-container rootful/rootless dind) is ~no better than
  the old `--docker` host-socket mount (one hop to host root).
- Egress must be **mandatory** (kernel-enforced), not cooperative (`HTTP_PROXY`
  an app can ignore). Policy should be expressed at **L7 (hostname/SNI/Host)**,
  not L3/L4 (resolved IPs), to avoid CDN/shared-IP leaks and domain fronting.

## Why sysbox (the enabling prerequisite)

Sysbox (`sysbox-runc`) runs a container's *own* dockerd **unprivileged** via
user namespaces + idmapped mounts. That uniquely gives both:
- **ergonomics**: single network namespace → `localhost:5432` and bind mounts
  work like a dev box (matches the `dotnet test → docker run -p` workflow);
- **isolation**: the agent container is not privileged → no trivial host escape.

The alternative (unprivileged agent + privileged dind sidecar + body-filtering
socket proxy) also keeps the agent unprivileged but is more moving parts and
reintroduces port/path remapping. Sysbox collapses those layers.

Sysbox is enabled declaratively in this repo via the vendored
`system/sysbox-nix/` (`virtualisation.sysbox.enable = true`). See
**Sysbox enablement** below for the full history.

## Architecture: sidecar proxy (Phase B.1)

```
┌─── Host Docker ──────────────────────────────────────────────┐
│                                                              │
│  ┌── sandbox-internal-$$ (Docker bridge, sidecar=gateway) ─┐ │
│  │                                                          │ │
│  │  ┌─ Agent Container (sysbox-runc) ─────────────────┐    │ │
│  │  │  claude user → agent process                     │    │ │
│  │  │  inner dockerd → nested containers               │    │ │
│  │  │  default route → sidecar IP (172.30.0.2)         │    │ │
│  │  │  NO proxy, NO iptables egress rules              │    │ │
│  │  │  CA from sidecar (shared volume, read-only)      │    │ │
│  │  └──────────────────────────┬───────────────────────┘    │ │
│  │                             │ HTTP(S)                    │ │
│  │  ┌─ Sidecar Container ─────┴──────────────────────┐     │ │
│  │  │  mitmproxy (transparent) ← PREROUTING REDIRECT │     │ │
│  │  │  iptables: FORWARD deny (non-HTTP blocked)     │     │ │
│  │  │  egress-policy.py (hostname allowlist)          │     │ │
│  │  │  firewall-domains.txt                          │     │ │
│  │  └──────────────────────────┬─────────────────────┘     │ │
│  └─────────────────────────────│─────────────────────────────┘ │
│                                │ allowed traffic only          │
│  ┌── default bridge ──────────┴────────────────────────────┐ │
│  │                     Internet                            │ │
│  └─────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

**Key security properties:**
- Agent container is on `--internal` network only → no direct internet route
- Sidecar is on both internal + bridge → acts as NAT gateway with L7 policy
- Even if agent gains root + flushes iptables → no effect (enforcement is external)
- Policy files (allowlist, addon) are in sidecar → agent can't read or modify them
- Proxy process is in sidecar → agent can't see or kill it
- CA shared via Docker volume (mounted read-only in agent container)

## Build order — each phase is independently shippable

Reuse what already works by copying/extracting from `run-claude-docker.sh`
(worktree setup, Nix symlink resolution, mount helpers, the Ctrl-Z rcfile
trick) — we don't refactor the old script to share code yet.

### Phase A — run the agent under sysbox  ✅ proven
- Launch the agent container with `--runtime=sysbox-runc`; install dockerd
  *inside* the image; **no host-socket mount at all** (the old `--docker` flag
  is simply not carried over).
- Inner daemon data-root on a **per-instance** volume (`/var/lib/docker`) so
  parallel agents never share a data-root. Optional host **registry
  pull-through mirror** (`registry:2` + `REGISTRY_PROXY_REMOTEURL`) for warm
  caches without sharing storage. *(mirror not yet implemented)*
- Outcome: `dotnet test → docker run` works with native ergonomics; agent
  unprivileged; test-DB containers nested inside, not host siblings.

### Phase B — network: flip policy L3/L4 → L7 (biggest correctness win)  ✅ proven
- Replaced dnsmasq+ipset+iptables IP-allowlisting with L7 proxy (mitmproxy
  transparent mode) + iptables mandatory floor.
- Per-run CA generated by mitmproxy, installed into system trust store + Java
  keystore + standard env vars (`SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, etc.).
- Self-verifying: asserts blocked host fails AND allowed host succeeds.

### Phase B.1 — sidecar proxy (move enforcement outside the container)  ✅ scaffolded (untested)
- Run mitmproxy in a **separate sidecar container** on a Docker `--internal`
  network. The agent container's only route to the internet goes through
  the sidecar. Even if the agent gains root and flushes iptables inside its
  own container, the sidecar's enforcement is unreachable.
- Architecture: sidecar on both `sandbox-internal-$$` (internal, no internet)
  and the default bridge (internet). Agent container on `sandbox-internal-$$`
  only. Sidecar acts as NAT gateway with mitmproxy as the policy point.
- CA sharing via a Docker volume (sidecar generates, agent container mounts
  read-only).
- Agent entrypoint adds `ip route add default via <sidecar-ip>` to route all
  traffic through the sidecar.
- Sidecar iptables:
  - `PREROUTING REDIRECT`: HTTP(S) from internal → mitmproxy (transparent)
  - `FORWARD REJECT`: non-HTTP traffic blocked (raw TCP, QUIC, C2)
  - `INPUT REJECT`: QUIC (UDP 443) and DoT (TCP 853) from internal
  - `POSTROUTING MASQUERADE`: NAT outbound on external interface
- Closes the last in-container root risk: **iptables tampering** is now
  harmless because there are no enforcement rules in the agent container.
- Proxy process, policy files, and domain allowlist are in the sidecar
  filesystem — agent cannot see, kill, or modify them.

### Phase C — credential injection (keep secrets off the agent) — sbx model
- Generate a per-run CA; install trust via the sbx env-var set
  (`SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `NODE_EXTRA_CA_CERTS`)
  + Java keytool import.
- Proxy addon injects creds by **detected service** (domain→service table) and/or
  **placeholder substitution** (agent holds a fake token, proxy swaps the real
  one outbound). Real secrets read from host (env/keychain), never enter the VM.
- Lets us stop mounting real creds (`~/.config/gh`, NuGet token, Anthropic) into
  the container — resolves the existing TODOs in the launcher's mount block.
- git over HTTPS with token injection; SSH (port 22) stays default-denied unless
  explicitly allowed.

### Cross-cutting / carry over from the old script
- Worktree mode, host-absolute-path mounts, Nix symlink resolution, Ctrl-Z
  rcfile trick, build-arg version pinning — copied into the launcher (extracted
  verbatim; not shared with the old script yet).
- Make firewall/proxy **fail-closed and self-verifying**: assert a blocked host
  fails AND an allowed host succeeds (the old check only tested the blocked
  case).

## Security comparison: Phase B vs Phase B.1

| Attack vector | Phase B (in-container) | Phase B.1 (sidecar) |
|---|---|---|
| Agent ignores `HTTP_PROXY` | ✅ Blocked (iptables REDIRECT) | ✅ Blocked (network topology) |
| Agent flushes iptables as root | ❌ **Bypasses proxy** | ✅ **No effect** (no enforcement rules in agent) |
| Agent kills proxy process | ❌ Risk if escalates to egressproxy uid | ✅ **Impossible** (process in sidecar) |
| Agent modifies allowlist | ✅ File is root-owned | ✅ **File doesn't exist** in agent container |
| Agent modifies policy addon | ✅ File is root-owned | ✅ **File doesn't exist** in agent container |
| Root uid 0 bypass | ✅ No exemption (Phase B fix) | ✅ **N/A** (no iptables to bypass) |
| Domain fronting | ✅ Proxy detects SNI≠Host | ✅ Same (proxy in sidecar) |
| QUIC/DoT bypass | ✅ Blocked by iptables | ✅ Blocked by sidecar iptables |
| Raw TCP exfil | ✅ Default-deny in OUTPUT | ✅ Default-deny in sidecar FORWARD |
| Nested container egress | ✅ SANDBOX_FORWARD chain | ✅ Traffic routes through sidecar |
| Postinst script (apt-get) | ✅ Root goes through proxy | ✅ Root goes through sidecar |

**Phase B.1 is strictly stronger**: it eliminates the proxy-kill and policy-
modification attack vectors, and raises the bar on the iptables escape from
"flush rules" (instant, Phase B) to "discover bridge gateway + reconfigure
routing" (requires root + knowledge of Docker internals, Phase B.1). The proxy
process, policy files, and domain allowlist remain unreachable in all cases
(separate container namespace).

## Open questions / decisions parked
- ~~subuid/subgid handling on NixOS~~ — resolved at activation (worked out of
  the box).
- Proxy implementation: mitmproxy (batteries-included, Python addon) vs small Go
  proxy (better at hijacked/streamed conns; lighter). For pure outbound HTTPS,
  mitmproxy is fine; revisit if we ever proxy the docker socket too.
- Whether to also keep a body-authorizing docker-socket proxy as
  defense-in-depth even under sysbox (probably not load-bearing once the agent
  is unprivileged).
- Docker `--internal` networks are incompatible with transparent proxying: the
  host-level iptables `DOCKER-INTERNAL` chain DROPs any traffic on the internal
  bridge with non-subnet destination IPs. This blocks the transparent proxy
  pattern (agent sends to external IP, sidecar REDIRECTs to mitmproxy) because
  the packet is dropped before reaching the sidecar. We use a regular bridge
  instead and replace the default route to point at the sidecar. The agent could
  discover the bridge gateway and bypass (requires root + `ip route`), but this
  is a higher bar than Phase B's instant `iptables -F` bypass, and the sidecar's
  proxy/policy are still in a separate container (unreachable to modify/kill).
- **Caveat:** transparent mode relies on plaintext SNI; SNI-less / ECH traffic
  is opaque. Mitigate via DNS (strip ECH HTTPS records) or full MITM (Host
  header). These AI/API endpoints send normal SNI today.
- **Caveat:** nested containers don't have the MITM CA, so HTTPS from inside
  them fails with cert errors. This is acceptable (DB containers don't make
  outbound HTTPS; agent work happens in the outer container).

---

## Current status: Phase A proven, Phase B proven, Phase B.1 proven

- ✅ Inner dockerd starts under sysbox-runc (validated on `tachikoma`)
- ✅ `docker run hello-world` works nested inside the agent container
- ✅ `default.nix` wired into `users/claude-code.nix` — `run-claude-sandbox`
  and `run-agent-sandbox` are on `PATH` after `home-manager switch`
- ✅ Phase B proven end to end: L7 proxy + iptables floor + no uid 0 bypass +
  nested container egress blocked + domain fronting rejected + sudoers tightened
- ✅ Phase B.1 proven end to end: sidecar proxy, sandbox bridge network, DNS
  forwarding via DNAT, CA volume, transparent redirect, all 47 tests passing.
  Sidecar isolation verified: proxy process/policy files unreachable from agent,
  iptables flush has no effect.
- Test harness: `test-sandbox-egress` — 47 pass, 0 fail, 1 skip

Next step: **Phase C** — credential injection (keep secrets off the agent).

---

## Sysbox enablement (history & provenance)

Validated on `tachikoma` (NixOS 26.05, WSL2, kernel 6.18). This was the
enabling prerequisite for the whole sandbox design and is now **proven end to
end**: `docker run --runtime=sysbox-runc docker:dind` starts an inner dockerd,
`docker run hello-world` works nested inside, and the outer container is
unprivileged with real UID remapping (host `/proc/<pid>/uid_map` shows
container uid 0 → a high host subuid).

### Environment prerequisites (validated)
systemd PID 1 ✓, real Docker Engine ✓, idmapped mounts (`idmap.enabled: true`,
so shiftfs not needed) ✓, FUSE ✓, unprivileged userns ✓, cgroup v2 ✓,
`.wslconfig` not in `networkingMode=mirrored` (the one known WSL breaker) ✓.

### Vendoring
`polferov/sysbox-nix` @ `09799d4` (2026-05-31) vendored into
`system/sysbox-nix/` (MIT LICENSE kept, `.nix` files byte-for-byte, flake
plumbing removed for direct-import integration). Builds sysbox from pinned
`nestybox/sysbox` source via content hashes (tamper-evident). Integrated into
`tachikoma` via Option B (direct import) with `lib.mkForce` on the
inotify/pid_max sysctls to resolve priority ties with nixpkgs defaults.

### Hard-won fixes (the path to "proven end to end")
1. **Docker version skew → pinned Docker 29.4.3.** sysbox 0.6.7/0.7.0 break on
   Docker 29.5 (private `time` namespace injection — moby#52326,
   nestybox/sysbox#1011; plus changed stdio/console handling). 29.4.3 is the
   last known-good. Sourced from a dedicated pinned input `nixpkgs-docker`
   @ `8e4a6e1b8b11` (does *not* follow nixpkgs). **Revisit** when upstream
   sysbox supports 29.5+ → drop the input.
2. **Bumped vendored sysbox 0.6.7 → 0.7.0** — 0.7.0's openat2 trapping got past
   a silent nsenter init abort on kernel 6.18.
3. **sysbox-fs FUSE3** — 0.7.0 calls `fusermount3`; fixed `pkgs.fuse` →
   `pkgs.fuse3` on the service PATH.
4. **nsexec oom_score_adj patch** — nsexec unconditionally writes
   `oom_score_adj` (a kill-priority hint), which fails EACCES under sysbox's
   userns on this kernel and aborts container start. Patched to warn-and-
   continue. **Gotcha (cost hours):** the fix must target the **vendored** runc
   copy (`vendor/.../runc/libcontainer/nsenter/nsexec.c`) that cgo actually
   compiles — *not* sysbox-runc's own `libcontainer/nsenter` tree (dead code).
   Applied via `postConfigure` `substituteInPlace --replace-fail` (self-
   verifying).

### Commits (sysbox enablement)
- `1d21069` vendor polferov/sysbox-nix for review
- `ca248f2` integrate vendored sysbox into tachikoma (Option B)
- pin Docker 29.4.3 via dedicated `nixpkgs-docker` input
- bump vendored sysbox 0.6.7 → 0.7.0
- `sysbox-fs`: fuse3 (fusermount3) on service PATH
- `sysbox-runc`: oom-nonfatal patch on the vendored runc nsexec

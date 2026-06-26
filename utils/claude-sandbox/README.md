# claude-sandbox

The **new** hardened sandbox for running an untrusted AI agent, developed
alongside the working `utils/run-claude-docker.sh` (which stays untouched).
See `../../SANDBOX-PLAN.md` for the full threat model and roadmap.

Unlike the old single-file script, the pieces are split into separate files:

| file                   | role                                                        |
|------------------------|-------------------------------------------------------------|
| `default.nix`          | copies the folder into the store; PATH-wraps the launcher   |
| `run-claude-sandbox.sh`| host launcher — worktree, mounts, `docker run`              |
| `Dockerfile`           | agent image — full `dockerd` inside, **no host socket**     |
| `entrypoint.sh`        | in-container: start inner dockerd, then drop to `claude`    |

## Core idea

The agent container runs under `--runtime=sysbox-runc`, so it is **unprivileged
with real UID remapping** yet can run its **own dockerd nested inside**. That
gives native `dotnet test -> docker run -p` ergonomics (single netns,
`localhost`, bind mounts) without ever handing the agent the host Docker socket
(the old `--docker` flag's one-hop-to-host-root, now gone).

## Phase status

- **Phase A (current scaffold):** run the agent under sysbox with an inner
  daemon and a per-instance `/var/lib/docker` volume. Ergonomics + isolation.
  ⚠️ Network egress is **not** restricted yet, and creds are still mounted.
- **Phase B (TODO):** mandatory iptables egress floor + in-container L7 proxy
  (SNI/Host allowlist, block QUIC/DoT, anti-domain-fronting). Force
  agent-spawned containers through it too.
- **Phase C (TODO):** per-run CA + credential injection at the proxy so real
  secrets never enter the container.

## Status: UNTESTED scaffold

Not yet wired into `users/claude-code.nix` and not yet run end-to-end. To try it
from a checkout (without Nix packaging) — the launcher finds its `Dockerfile`
and `entrypoint.sh` siblings via `BASH_SOURCE`, so just run it by path:

```sh
utils/claude-sandbox/run-claude-sandbox.sh
```

Next steps: validate inner dockerd starts under sysbox, confirm
`docker run hello-world` works inside, then wire `default.nix` into
`home.packages`.

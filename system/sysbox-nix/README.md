# Vendored: sysbox-nix

A source-based Nix flake + NixOS module that builds the [Sysbox][sysbox]
container runtime (a `runc` replacement that runs system containers — its own
`dockerd`, systemd, etc. — inside *unprivileged* containers via user
namespaces + idmapped mounts).

We vendor it rather than consume it as a live flake input because upstream is
young (single maintainer, ~10 commits) and builds third-party code; pinning a
reviewed copy keeps it tamper-evident and removes surprise upstream changes.

## Provenance

- **Upstream repo:** https://github.com/polferov/sysbox-nix
- **Commit:** `09799d4c4e493a9431b084cd95074a7beb2d364a`
- **Committed:** 2026-05-31T11:06:08Z
- **Vendored:** 2026-06-22
- **License:** MIT (see `upstream/LICENSE`, © Kirill Polferov) — this covers the
  *packaging* code only. The Sysbox source it builds
  (`nestybox/sysbox` @ `v0.6.7`) is Apache-2.0 and is fetched at build time
  from the official repo via a pinned `fetchFromGitHub` hash, not vendored here.

The files under `upstream/` are copied **verbatim** from the commit above.

## Local changes

None yet — `upstream/` is an unmodified copy. Record any divergence here
(file + reason) and keep the copy otherwise byte-for-byte upstream so the next
re-sync is a clean diff.

## Why it suits this host (tachikoma, NixOS + WSL2)

- Kernel 6.18 ≥ 5.19 → idmapped mounts replace shiftfs (which is absent here).
- systemd PID 1, real Docker Engine (runc default) — the module registers
  `sysbox-runc` as a Docker runtime.
- See the build derivations in `upstream/pkgs/` and the NixOS module in
  `upstream/modules/sysbox.nix`.

## Re-syncing with upstream

```sh
# bump the commit, re-fetch verbatim, then re-review the diff under upstream/pkgs
gh api repos/polferov/sysbox-nix/contents/<path>?ref=<sha> --jq .content | base64 -d
```

[sysbox]: https://github.com/nestybox/sysbox

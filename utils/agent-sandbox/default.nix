{ pkgs }:

# Package the sandbox as a folder that mirrors the source checkout: the
# launcher and its support files (Dockerfile, entrypoint.sh) land together in
# one store directory, so the launcher can locate them via BASH_SOURCE exactly
# as it does when run straight from the repo. No env-var bridge needed.
#
# Layout in $out:
#   bin/run-claude-sandbox            -> shim for the Claude wrapper (daily use)
#   bin/run-agent-sandbox             -> shim for the generic core (other agents)
#   libexec/agent-sandbox/
#     run-claude-sandbox.sh           <- Claude wrapper; calls the core sibling
#     run-agent-sandbox.sh            <- generic core; BASH_SOURCE points here
#     Dockerfile                      <- agent image
#     Dockerfile.sidecar              <- sidecar proxy image (Phase B.1)
#     entrypoint.sh                   <- agent container entrypoint
#     sidecar-entrypoint.sh           <- sidecar container entrypoint
#
# The Claude wrapper finds the core via BASH_SOURCE (they're siblings in
# libexec), so only the bin shims need PATH wrapping.
pkgs.stdenv.mkDerivation {
  name = "run-agent-sandbox";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  dontBuild = true;

  installPhase = ''
    libexec=$out/libexec/agent-sandbox
    mkdir -p $libexec $out/bin
    cp run-claude-sandbox.sh run-agent-sandbox.sh test-sandbox-egress.sh \
       egress-test-harness.sh Dockerfile Dockerfile.sidecar entrypoint.sh \
       sidecar-entrypoint.sh \
       firewall-domains.txt egress-policy.py $libexec/
    chmod +x $libexec/run-claude-sandbox.sh $libexec/run-agent-sandbox.sh \
             $libexec/test-sandbox-egress.sh $libexec/egress-test-harness.sh \
             $libexec/entrypoint.sh $libexec/sidecar-entrypoint.sh

    for entry in run-claude-sandbox run-agent-sandbox test-sandbox-egress; do
      makeWrapper $libexec/$entry.sh $out/bin/$entry \
        --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.docker pkgs.coreutils pkgs.git ]}
    done
  '';
}

{ pkgs }:

# Package the sandbox as a folder that mirrors the source checkout: the
# launcher and its support files (Dockerfile, entrypoint.sh) land together in
# one store directory, so the launcher can locate them via BASH_SOURCE exactly
# as it does when run straight from the repo. No env-var bridge needed.
#
# Layout in $out:
#   bin/run-agent-sandbox             -> makeWrapper shim (sets PATH, execs ↓)
#   libexec/agent-sandbox/
#     run-agent-sandbox.sh            <- BASH_SOURCE points here; siblings below
#     Dockerfile
#     entrypoint.sh
pkgs.stdenv.mkDerivation {
  name = "run-agent-sandbox";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  dontBuild = true;

  installPhase = ''
    mkdir -p $out/libexec/agent-sandbox $out/bin
    cp run-agent-sandbox.sh Dockerfile entrypoint.sh $out/libexec/agent-sandbox/
    chmod +x $out/libexec/agent-sandbox/run-agent-sandbox.sh \
             $out/libexec/agent-sandbox/entrypoint.sh

    makeWrapper $out/libexec/agent-sandbox/run-agent-sandbox.sh \
      $out/bin/run-agent-sandbox \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.docker pkgs.coreutils pkgs.git ]}
  '';
}

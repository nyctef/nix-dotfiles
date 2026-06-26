{ pkgs }:

# Package the sandbox as a folder that mirrors the source checkout: the
# launcher and its support files (Dockerfile, entrypoint.sh) land together in
# one store directory, so the launcher can locate them via BASH_SOURCE exactly
# as it does when run straight from the repo. No env-var bridge needed.
#
# Layout in $out:
#   bin/run-claude-sandbox            -> makeWrapper shim (sets PATH, execs ↓)
#   libexec/claude-sandbox/
#     run-claude-sandbox.sh           <- BASH_SOURCE points here; siblings below
#     Dockerfile
#     entrypoint.sh
pkgs.stdenv.mkDerivation {
  name = "run-claude-sandbox";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  dontBuild = true;

  installPhase = ''
    mkdir -p $out/libexec/claude-sandbox $out/bin
    cp run-claude-sandbox.sh Dockerfile entrypoint.sh $out/libexec/claude-sandbox/
    chmod +x $out/libexec/claude-sandbox/run-claude-sandbox.sh \
             $out/libexec/claude-sandbox/entrypoint.sh

    makeWrapper $out/libexec/claude-sandbox/run-claude-sandbox.sh \
      $out/bin/run-claude-sandbox \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.docker pkgs.coreutils pkgs.git ]}
  '';
}

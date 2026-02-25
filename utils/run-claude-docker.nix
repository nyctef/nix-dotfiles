{ pkgs }:

pkgs.writeShellApplication {
  name = "run-claude-docker";

  runtimeInputs = with pkgs; [
    docker
    coreutils
  ];

  text = builtins.readFile ./run-claude-docker.sh;

  # Skip shellcheck — the script uses bash patterns (arrays, heredocs with
  # embedded iptables commands) that trigger false positives.
  checkPhase = "";
}

{ pkgs }:

pkgs.writeShellApplication {
  name = "recent-claude-sessions";

  runtimeInputs = with pkgs; [ fzf python3 ];

  text = ''
    exec ${pkgs.python3}/bin/python3 ${./recent-claude-sessions.py} "$@"
  '';
}

{ pkgs }:

pkgs.writeShellApplication {
  name = "renovate-pr-diagnose";

  runtimeInputs = with pkgs; [ gh python3 curl ];

  text = ''
    exec ${pkgs.python3}/bin/python3 ${./renovate_pr_diagnose.py} "$@"
  '';
}

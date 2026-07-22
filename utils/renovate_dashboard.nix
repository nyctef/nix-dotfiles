{ pkgs }:

pkgs.writeShellApplication {
  name = "renovate-dashboard";

  runtimeInputs = with pkgs; [ gh python3 ];

  text = ''
    exec ${pkgs.python3}/bin/python3 ${./renovate_dashboard.py} "$@"
  '';
}

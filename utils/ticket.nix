{ pkgs, ticket-src }:

pkgs.writeShellApplication {
  name = "tk";

  runtimeInputs = with pkgs; [
    jq
    ripgrep
    coreutils
  ];

  text = builtins.readFile "${ticket-src}/ticket";
}

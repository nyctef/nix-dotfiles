{ pkgs }:

pkgs.writeShellApplication {
  name = "watch-pr";
  
  runtimeInputs = with pkgs; [
    fzf
    gh
    jq
    gnused
    coreutils
  ];
  
  text = builtins.readFile ./watch-pr.sh;
}

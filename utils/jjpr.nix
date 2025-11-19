{ pkgs }:

pkgs.writeShellApplication {
  name = "jjpr";
  
  runtimeInputs = with pkgs; [
    fzf
    gh
    jujutsu
  ];
  
  text = builtins.readFile ./jjpr.sh;
}

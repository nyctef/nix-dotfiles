{ pkgs }:

pkgs.writeShellApplication {
  name = "jjdesc";

  runtimeInputs = with pkgs; [
    jujutsu
  ];

  text = builtins.readFile ./jjdesc.sh;
}

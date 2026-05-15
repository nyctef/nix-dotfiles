{ pkgs }:

pkgs.writeShellApplication {
  name = "cleanup-worktrees";

  runtimeInputs = with pkgs; [ git gawk ];

  text = builtins.readFile ./cleanup-worktrees.sh;
}

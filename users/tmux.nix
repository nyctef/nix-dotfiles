{ config, pkgs, ... }:

{
  programs.tmux.enable = true;

  programs.tmux.keyMode = "vi";
  # bind prefix + hjkl/HJKL
  programs.tmux.customPaneNavigationAndResize = true;
}

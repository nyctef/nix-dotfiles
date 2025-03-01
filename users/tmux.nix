{ config, pkgs, ... }:

{
  programs.tmux = {
    enable = true;
    keyMode = "vi";
    # bind prefix + hjkl/HJKL
    customPaneNavigationAndResize = true;
    # https://superuser.com/a/1809494
    escapeTime = 50;
    historyLimit = 50000;
    terminal = "screen-256color";
  };
}

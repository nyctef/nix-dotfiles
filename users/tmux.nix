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
    mouse = true;
    terminal = "tmux-256color";
    extraConfig = ''
      # make splits open in the current folder
      bind '"' split-window -v -c "#{pane_current_path}"
      bind % split-window -h -c "#{pane_current_path}"

      # Start windows and panes at 1, not 0
      set -g base-index 1
      set -g pane-base-index 1
      set-window-option -g pane-base-index 1
      set-option -g renumber-windows on

      # dim inactive panes
      setw -g window-active-style fg=terminal,bg=terminal
      setw -g window-style fg=colour245,bg=colour236

      # make sure nvim can receive focus events for automatically refreshing file contents etc
      set -g focus-events on
    '';
  };
}

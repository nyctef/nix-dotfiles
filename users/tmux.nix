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
      # Terminal overrides for proper color support
      # Tc: Enable RGB/true color support (tmux extension)
      # https://github.com/tmux/tmux/wiki/FAQ#how-do-i-use-rgb-colour
      set -as terminal-overrides ",xterm-256color:Tc"
      set -as terminal-features ',*:hyperlinks'

      # make splits open in the current folder
      bind '"' split-window -v -c "#{pane_current_path}"
      bind % split-window -h -c "#{pane_current_path}"

      # Start windows and panes at 1, not 0
      set -g base-index 1
      set -g pane-base-index 1
      setw -g pane-base-index 1
      set -g renumber-windows on

      # dim inactive panes
      setw -g window-active-style fg=terminal,bg=terminal
      setw -g window-style fg=colour245,bg=colour236

      # make sure nvim can receive focus events for automatically refreshing file contents etc
      set -g focus-events on

      # allow modified Enter/key combos (e.g. shift+enter) to pass through
      set -g extended-keys on

      # let apps (e.g. Claude Code) forward DCS-wrapped OSC 52 clipboard
      # sequences through tmux to the outer terminal. without this, the
      # "X characters copied to clipboard" popup fires but nothing is copied.
      set -g allow-passthrough on
      # ensure tmux forwards OSC 52 clipboard writes to the outer terminal
      set -g set-clipboard on
    '';
  };
}

{ pkgs }:

let
  psScript = ./wsl-toast.ps1;
in
pkgs.writeShellScriptBin "wsl-toast" ''
  #!/bin/sh

  # WSL Windows Toast Notification Script
  # Usage: wsl-toast [title] [message]
  # If only one arg provided, it's used as the message with default title

  TITLE="''${1:-WSL}"
  MESSAGE="''${2:-Notification}"

  if [ -z "$2" ]; then
    MESSAGE="$TITLE"
    TITLE="WSL"
  fi

  powershell.exe -ExecutionPolicy Bypass -File "${psScript}" -Title "$TITLE" -Message "$MESSAGE" 2>/dev/null
''

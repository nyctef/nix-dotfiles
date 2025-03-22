{ pkgs }:

pkgs.writeShellScriptBin "waitcat" ''
  #!/bin/sh

  if [ -z "$1" ]; then
    echo "Usage: $0 <filename> <...cat args>" >&2
    exit 1
  fi
  filename="$1"
  shift # strip off $1 so remaining args are left

  until [ -f "$filename" ]
  do
    sleep 1
  done

  cat "$filename" "$@"
''

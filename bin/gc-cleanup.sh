#!/usr/bin/env bash
# Garbage-collect nix generations/store, docker, and nuget caches older than $DAYS.
#
# Usage:
#   bin/gc-cleanup.sh [--dry-run] [--days N] [--include-nuget-global]
#
# --dry-run prints what would happen without deleting anything (default: off).
# --days N sets the age cutoff (default: 7).
# --include-nuget-global also prunes ~/.nuget/packages (the restore cache).
#   Off by default: packages untouched for N days can still be the bulk of the
#   cache (they're only "touched" when a restore uses them, not just by
#   existing), so this can evict most of it and slow down the next restore
#   per project. Opt in deliberately.

set -euo pipefail

DAYS=7
DRY_RUN=0
INCLUDE_NUGET_GLOBAL=0

while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run) DRY_RUN=1 ;;
	--include-nuget-global) INCLUDE_NUGET_GLOBAL=1 ;;
	--days)
		DAYS="$2"
		shift
		;;
	*)
		echo "unknown arg: $1" >&2
		exit 1
		;;
	esac
	shift
done

run() {
	if [ "$DRY_RUN" = 1 ]; then
		echo "+ $*"
	else
		echo "+ $*"
		"$@"
	fi
}

section() {
	echo
	echo "=== $1 ==="
}

section "nixos system generations + store gc"
run sudo nix-collect-garbage --delete-older-than "${DAYS}d"

section "home-manager generations"
run home-manager expire-generations "-${DAYS} days"
run nix-collect-garbage --delete-older-than "${DAYS}d"

section "docker"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
	run docker image prune -af --filter "until=$((DAYS * 24))h"
	run docker container prune -f --filter "until=$((DAYS * 24))h"
	run docker builder prune -af --filter "until=$((DAYS * 24))h"
	run docker volume prune -f
else
	echo "docker daemon not reachable, skipping"
fi

section "nuget http-cache / plugin-cache / temp (age-filtered, always safe to lose)"
for dir in "$HOME/.local/share/NuGet/http-cache" "$HOME/.local/share/NuGet/plugin-cache"; do
	if [ -d "$dir" ]; then
		if [ "$DRY_RUN" = 1 ]; then
			echo "+ find '$dir' -type f -mtime +${DAYS} -print"
			find "$dir" -type f -mtime "+${DAYS}" -print
		else
			echo "+ find '$dir' -type f -mtime +${DAYS} -delete"
			find "$dir" -type f -mtime "+${DAYS}" -delete
			find "$dir" -mindepth 1 -type d -empty -delete
		fi
	fi
done

section "nuget global-packages cache (package/version dirs untouched for ${DAYS}d)"
if [ "$INCLUDE_NUGET_GLOBAL" = 1 ]; then
	PKG_DIR="$HOME/.nuget/packages"
	if [ -d "$PKG_DIR" ]; then
		find "$PKG_DIR" -mindepth 2 -maxdepth 2 -type d | while read -r ver_dir; do
			# skip if any file inside was modified within the cutoff window
			if find "$ver_dir" -type f -mtime "-${DAYS}" -print -quit | grep -q .; then
				continue
			fi
			if [ "$DRY_RUN" = 1 ]; then
				echo "+ rm -rf '$ver_dir'"
			else
				echo "+ rm -rf '$ver_dir'"
				rm -rf "$ver_dir"
			fi
		done
	else
		echo "no ~/.nuget/packages, skipping"
	fi
else
	echo "skipped (pass --include-nuget-global to enable; can evict most of the cache, see script header)"
fi

section "done"
if [ "$DRY_RUN" = 1 ]; then
	echo "dry run only, nothing was deleted"
fi

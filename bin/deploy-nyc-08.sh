#!/usr/bin/env bash
# Deploy nyc-08: build the closure here and only activate it there.
#
# Building locally needs aarch64 emulation — see
# boot.binfmt.emulatedSystems in system/tachikoma/configuration.nix.
#
# Arguments are passed through to nixos-rebuild, so --dry-activate, --rollback etc works

set -euo pipefail

cd "$(dirname -- "$0")/.."

exec nixos-rebuild switch \
	--flake ".#nyc-08" \
	--target-host nyctef@nyc-08 \
	--sudo \
	"$@"

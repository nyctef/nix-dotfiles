#!/usr/bin/env bash
# Deploy nyc-08, a low-powered aarch64 Azure VM: build the closure here and
# only activate it there. Building locally needs aarch64 emulation — see
# boot.binfmt.emulatedSystems in system/tachikoma/configuration.nix.
#
# Arguments are passed through to nixos-rebuild, so --dry-activate, --rollback
# and friends work.

set -euo pipefail

cd "$(dirname -- "$0")/.."

exec nixos-rebuild switch \
	--flake ".#nyc-08" \
	--target-host nyctef@52.149.67.34 \
	--sudo \
	"$@"

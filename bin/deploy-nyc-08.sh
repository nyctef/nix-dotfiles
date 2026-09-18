#!/usr/bin/env bash
# Deploy the nyc-08 system closure from this machine.
#
# nyc-08 is a low-powered aarch64 Azure VM, so the closure is built locally and
# only activated there. That needs aarch64 emulation on the building host
# (boot.binfmt.emulatedSystems, set for tachikoma); without it, pass
# --build-host to build on the VM instead.
#
# Usage:
#   bin/deploy-nyc-08.sh [extra nixos-rebuild args...]
#
# Any arguments are passed through to nixos-rebuild, so `--dry-activate`,
# `--rollback` and friends work. The target defaults to the `nyc-08` ssh alias;
# override it with NYC08_TARGET=nyctef@<ip>.

set -euo pipefail

cd "$(dirname -- "$0")/.."

TARGET="${NYC08_TARGET:-nyctef@nyc-08}"

if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
	echo "warning: no aarch64 binfmt handler registered, so the local build will fail." >&2
	echo "         re-run with --build-host $TARGET to build on the VM instead." >&2
fi

exec nixos-rebuild switch \
	--flake ".#nyc-08" \
	--target-host "$TARGET" \
	--sudo \
	"$@"

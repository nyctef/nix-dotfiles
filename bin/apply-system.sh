#!/bin/sh
pushd $(dirname -- "$0")/..
sudo nixos-rebuild switch --flake .#
popd

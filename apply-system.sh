#!/bin/sh
pushd $(dirname -- "$0")
sudo nixos-rebuild switch -I nixos-config=./system/configuration.nix
popd

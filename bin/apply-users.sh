#/bin/sh
pushd $(dirname -- "$0")
home-manager switch --flake .
popd

#/bin/sh
pushd $(dirname -- "$0")
home-manager switch -f ./users/generic.nix
popd

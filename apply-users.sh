#/bin/sh
pushd $(dirname -- "$0")
nix build .#homeManagerConfigurations.generic.activationPackage
./result/activate
popd

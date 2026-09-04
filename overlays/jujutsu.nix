# Overlay to run a newer jujutsu than the one in nixpkgs-unstable.
#
# nixpkgs is on 0.44.0; this bumps to 0.45.1 by swapping out the source and the
# vendored cargo dependencies, keeping everything else (build flags, man pages,
# shell completions) from the nixpkgs derivation.
#
# Note we replace `cargoDeps` rather than `cargoHash`: buildRustPackage reads
# cargoHash from its *original* arguments, so overrideAttrs can't reach it.
# Building the vendor dir ourselves is the supported escape hatch.
#
# To bump the version:
#   1. Set `version` below.
#   2. nix-prefetch-url --unpack https://github.com/jj-vcs/jj/archive/refs/tags/v<version>.tar.gz
#      then `nix hash convert --hash-algo sha256 --to sri <hash>` -> src hash.
#   3. Set the cargoDeps hash to lib.fakeHash, build, and copy the "got:" hash
#      from the error.
#
# Delete this file (and its entry in flake.nix) once nixpkgs catches up.
final: prev: {
  jujutsu = prev.jujutsu.overrideAttrs (old: rec {
    version = "0.45.1";

    src = prev.fetchFromGitHub {
      owner = "jj-vcs";
      repo = "jj";
      tag = "v${version}";
      hash = "sha256-nqMd9kj6TH/6kTZ8a9XDPBESwCIOMa7c/0TgbEXoo3o=";
    };

    cargoDeps = prev.rustPlatform.fetchCargoVendor {
      inherit src;
      hash = "sha256-rt3mq7+Z+7Z1Y+XUWva+UsrDcVeZs6VjXnhAL0iyP20=";
    };
  });
}

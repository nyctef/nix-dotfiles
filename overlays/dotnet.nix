# Nixpkgs overlays are functions of the form `final: prev: { ... }` that return
# an attrset of packages to add or replace in the package set. `prev` is the
# package set before this overlay is applied (used to call existing builders),
# and `final` is the fully-resolved package set after all overlays (used when
# you need a package that another overlay might have modified).
#
# Overlays are applied in flake.nix by passing them to `import nixpkgs { overlays = [...]; }`.
#
# This overlay exists because nixpkgs typically lags behind Microsoft's .NET
# releases by a week or more, which causes build failures in repos that eagerly
# update their global.json. By maintaining our own copy of the binary SDK
# version file (./dotnet-versions/10.0.nix), we can update it immediately when
# a new release ships without waiting for a nixpkgs PR to land.
#
# How the nixpkgs dotnet package set works:
#   - `dotnetCorePackages` is a scope (makeScopeWithSplicing') that contains all
#     dotnet packages. It exposes a `buildDotnetSdk` function that takes a .nix
#     file defining URLs and SHA-512 hashes for each platform's binary tarball,
#     and returns an attrset of built packages (aspnetcore_X, runtime_X, sdk_X_1xx).
#   - The `-bin` packages (sdk_10_0-bin, sdk_10_0_1xx-bin) are aliases into that
#     attrset — they are pure binary downloads with no source build involved.
#
# What this overlay does:
#   1. Calls `buildDotnetSdk` with our local ./dotnet-versions/10.0.nix instead
#      of the one vendored in nixpkgs, producing a fresh set of dotnet 10 packages.
#   2. Merges the result into dotnetCorePackages, replacing only sdk_10_0-bin and
#      sdk_10_0_1xx-bin (both point to the same derivation; both need updating
#      because other packages may reference either name).
#
# To update when a new .NET 10 release ships:
#   1. Edit ./dotnet-versions/10.0.nix — update version strings and SHA-512 hashes.
#   2. Get hashes with: nix store prefetch-file --hash-type sha512 <url>
#      or copy them directly from Microsoft's release notes / download page.
#   3. Run: home-manager switch

final: prev:
let
  dotnet10bin = prev.dotnetCorePackages.buildDotnetSdk ./dotnet-versions/10.0.nix;
in
{
  dotnetCorePackages = prev.dotnetCorePackages // {
    sdk_10_0_1xx-bin = dotnet10bin.sdk_10_0_1xx;
    sdk_10_0-bin = dotnet10bin.sdk_10_0_1xx;
  };
}

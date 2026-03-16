#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl jq nix
# Adapted from nixpkgs/pkgs/development/compilers/dotnet/update.sh
#
# Updates overlays/dotnet-versions/10.0.nix to the latest .NET 10 release.
# Fetches URLs and hashes from Microsoft's release metadata, and NuGet package
# hashes from the NuGet API. Exits early (no changes) if already up to date.
#
# Usage: ./overlays/update-dotnet10.sh

set -Eeuo pipefail
shopt -s inherit_errexit

trap 'exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$SCRIPT_DIR/dotnet-versions/10.0.nix"

major_minor="10.0"
major_minor_underscore="10_0"

rids=({linux-{,musl-}{arm,arm64,x64},osx-{arm64,x64},win-{arm64,x64,x86}})

release() {
    local content="$1" version="$2"
    jq -er '.releases[] | select(."release-version" == "'"$version"'")' <<< "$content"
}

release_files() {
    local release="$1" expr="$2"
    jq -er '[('"$expr"').files[] | select(.name | test("^.*.tar.gz$"))]' <<< "$release"
}

release_platform_attr() {
    local release_files="$1" platform="$2" attr="$3"
    jq -r '.[] | select((.rid == "'"$platform"'") and (.name | contains("-composite-") or contains("-pack-") | not)) | ."'"$attr"'"' <<< "$release_files"
}

platform_sources() {
    local release_files="$1"
    echo "srcs = {"
    for rid in "${rids[@]}"; do
        local url hash
        url=$(release_platform_attr "$release_files" "$rid" url)
        hash=$(release_platform_attr "$release_files" "$rid" hash)
        [[ -z "$url" || -z "$hash" ]] && continue
        hash=$(nix --extra-experimental-features nix-command hash convert --to sri --hash-algo sha512 "$hash")
        echo "      $rid = {
        url = \"$url\";
        hash = \"$hash\";
      };"
    done
    echo "    };"
}

nuget_index="$(curl -fsSL "https://api.nuget.org/v3/index.json")"
get_nuget_resource() {
    jq -er '.resources[] | select(."@type" == "'"$1"'")."@id"' <<< "$nuget_index"
}
nuget_package_base_url="$(get_nuget_resource "PackageBaseAddress/3.0.0")"
nuget_registration_base_url="$(get_nuget_resource "RegistrationsBaseUrl/3.6.0")"

generate_package_list() {
    local version="$1" indent="$2"
    shift 2
    local pkgs=("$@") pkg url hash catalog_url catalog hash_algorithm

    for pkg in "${pkgs[@]}"; do
        url=${nuget_package_base_url}${pkg,,}/${version,,}/${pkg,,}.${version,,}.nupkg

        if hash=$(curl -s --head "$url" -o /dev/null -w '%header{x-ms-meta-sha512}') && [[ -n "$hash" ]]; then
            hash=$(nix --extra-experimental-features nix-command hash convert --to sri --hash-algo sha512 "$hash")
        elif {
            catalog_url=$(curl -sL --compressed "${nuget_registration_base_url}${pkg,,}/${version,,}.json" | jq -r ".catalogEntry") && [[ -n "$catalog_url" ]] &&
            catalog=$(curl -sL "$catalog_url") && [[ -n "$catalog" ]] &&
            hash_algorithm="$(jq -er '.packageHashAlgorithm' <<< "$catalog")" && [[ -n "$hash_algorithm" ]] &&
            hash=$(jq -er '.packageHash' <<< "$catalog") && [[ -n "$hash" ]]
        }; then
            hash=$(nix --extra-experimental-features nix-command hash convert --to sri --hash-algo "${hash_algorithm,,}" "$hash")
        elif hash=$(nix-prefetch-url "$url" --type sha512); then
            echo "Failed to fetch hash from nuget for $url, falling back to downloading locally" >&2
            hash=$(nix --extra-experimental-features nix-command hash convert --to sri --hash-algo sha512 "$hash")
        else
            echo "Failed to fetch hash for $url" >&2
            exit 1
        fi

        echo "$indent(fetchNupkg { pname = \"${pkg}\"; version = \"${version}\"; hash = \"${hash}\"; })"
    done
}

versionAtLeast() {
    local cur_version=$1 min_version=$2
    printf "%s\0%s" "$min_version" "$cur_version" | sort -zVC
}

aspnetcore_packages() {
    local version=$1
    local pkgs=(Microsoft.AspNetCore.App.Ref)
    if versionAtLeast "$version" 10; then
        pkgs+=(Microsoft.AspNetCore.App.Internal.Assets)
    fi
    generate_package_list "$version" '    ' "${pkgs[@]}"
}

aspnetcore_target_packages() {
    local version=$1 rid=$2
    generate_package_list "$version" '      ' "Microsoft.AspNetCore.App.Runtime.$rid"
}

netcore_packages() {
    local version=$1
    local pkgs=(Microsoft.NETCore.DotNetAppHost Microsoft.NETCore.App.Ref)
    if versionAtLeast "$version" 7; then pkgs+=(Microsoft.DotNet.ILCompiler); fi
    if versionAtLeast "$version" 8; then pkgs+=(Microsoft.NET.ILLink.Tasks); fi
    generate_package_list "$version" '    ' "${pkgs[@]}"
}

netcore_host_packages() {
    local version=$1 rid=$2
    local pkgs=("Microsoft.NETCore.App.Crossgen2.$rid")
    local min_ilcompiler=
    case "$rid" in
        linux-musl-arm|linux-arm|win-x86) ;;
        osx-arm64) min_ilcompiler=8 ;;
        *) min_ilcompiler=7 ;;
    esac
    if [[ -n "$min_ilcompiler" ]] && versionAtLeast "$version" "$min_ilcompiler"; then
        pkgs+=("runtime.$rid.Microsoft.DotNet.ILCompiler")
    fi
    generate_package_list "$version" '      ' "${pkgs[@]}"
}

netcore_target_packages() {
    local version=$1 rid=$2
    local pkgs=(
        "Microsoft.NETCore.App.Host.$rid"
        "Microsoft.NETCore.App.Runtime.$rid"
        "runtime.$rid.Microsoft.NETCore.DotNetAppHost"
    )
    if versionAtLeast "$version" 10; then
        pkgs+=("Microsoft.NETCore.App.Runtime.NativeAOT.$rid")
    fi
    generate_package_list "$version" '      ' "${pkgs[@]}"
}

# Fetch release metadata from Microsoft
echo "Fetching .NET $major_minor release metadata..."
content=$(curl -fsSL "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/$major_minor/releases.json")
major_minor_patch=$(jq -er '."latest-release"' <<< "$content")
echo "Latest release: $major_minor_patch"

# Check if update is needed by evaluating current version strings from the nix file
if [ -f "$OUTPUT" ]; then
    mapfile -d '' current_versions < <(
        nix-instantiate --eval --json -E "{ output }: with (import output {
            buildAspNetCore = { ... }: {};
            buildNetSdk = { version, ... }: { inherit version; };
            buildNetRuntime = { version, ... }: { inherit version; };
            fetchNupkg = { ... }: {};
        }); (x: builtins.deepSeq x x) [
            runtime_${major_minor_underscore}.version
            sdk_${major_minor_underscore}.version
        ]" --argstr output "$OUTPUT" | jq -e --raw-output0 .[]
    )
    mapfile -t sdk_versions_available < <(jq -er '.releases[] | select(."release-version" == "'"$major_minor_patch"'") | .sdks[] | .version' <<< "$content" | sort -rn)
    latest_sdk="${sdk_versions_available[0]}"

    if [[ "${current_versions[0]}" == "$major_minor_patch" && "${current_versions[1]}" == "$latest_sdk" ]]; then
        echo "Already up to date: runtime $major_minor_patch, sdk $latest_sdk"
        exit 0
    fi
    echo "Updating: runtime ${current_versions[0]} -> $major_minor_patch, sdk ${current_versions[1]} -> $latest_sdk"
fi

# Fetch the release details and generate the nix file
release_content=$(release "$content" "$major_minor_patch")
aspnetcore_version=$(jq -er '."aspnetcore-runtime".version' <<< "$release_content")
runtime_version=$(jq -er '.runtime.version' <<< "$release_content")
mapfile -t sdk_versions < <(jq -er '.sdks[] | .version' <<< "$release_content" | sort -rn)

aspnetcore_files="$(release_files "$release_content" '."aspnetcore-runtime"')"
runtime_files="$(release_files "$release_content" '.runtime')"
aspnetcore_sources="$(platform_sources "$aspnetcore_files")"
runtime_sources="$(platform_sources "$runtime_files")"

result=$(mktemp -t dotnet-XXXXXX.nix)
trap "rm -f $result" TERM INT EXIT

(
    echo "{ buildAspNetCore, buildNetRuntime, buildNetSdk, fetchNupkg }:

# v$major_minor (active)
# upstream: https://github.com/NixOS/nixpkgs/blob/nixos-unstable/pkgs/development/compilers/dotnet/versions/$major_minor.nix
# to update: change version strings and hashes when a new .NET $major_minor release ships
# get hashes with: nix store prefetch-file --hash-type sha512 <url>

let
  commonPackages = ["
    aspnetcore_packages "${aspnetcore_version}"
    netcore_packages "${runtime_version}"
    echo "  ];

  hostPackages = {"
    for rid in "${rids[@]}"; do
        echo "    $rid = ["
        netcore_host_packages "${runtime_version}" "$rid"
        echo "    ];"
    done
    echo "  };

  targetPackages = {"
    for rid in "${rids[@]}"; do
        echo "    $rid = ["
        aspnetcore_target_packages "${aspnetcore_version}" "$rid"
        netcore_target_packages "${runtime_version}" "$rid"
        echo "    ];"
    done
    echo "  };

in rec {
  release_$major_minor_underscore = \"$major_minor_patch\";

  aspnetcore_$major_minor_underscore = buildAspNetCore {
    version = \"${aspnetcore_version}\";
    $aspnetcore_sources
  };

  runtime_$major_minor_underscore = buildNetRuntime {
    version = \"${runtime_version}\";
    $runtime_sources
  };"

    declare -A feature_bands
    unset latest_sdk_attr

    for sdk_version in "${sdk_versions[@]}"; do
        sdk_base_version=${sdk_version%-*}
        feature_band=${sdk_base_version:0:-2}xx
        [[ ! ${feature_bands[$feature_band]+true} ]] || continue
        feature_bands[$feature_band]=$sdk_version
        sdk_files="$(release_files "$release_content" ".sdks[] | select(.version == \"$sdk_version\")")"
        sdk_sources="$(platform_sources "$sdk_files")"
        sdk_attrname=sdk_${feature_band//./_}
        [[ -v latest_sdk_attr ]] || latest_sdk_attr=$sdk_attrname

        echo "
  $sdk_attrname = buildNetSdk {
    version = \"${sdk_version}\";
    $sdk_sources
    inherit commonPackages hostPackages targetPackages;
    runtime = runtime_$major_minor_underscore;
    aspnetcore = aspnetcore_$major_minor_underscore;
  };"
    done

    echo "
  sdk_$major_minor_underscore = $latest_sdk_attr;
}"
) > "$result"

cp "$result" "$OUTPUT"
echo "Updated $OUTPUT to runtime $major_minor_patch / sdk ${sdk_versions[0]}"

nix fmt "$OUTPUT"

#!/usr/bin/env bash
# Updates the flyway version and hash in users/rgcompare-test-env.nix to the latest release.
set -euo pipefail

NIX_FILE="$(cd "$(dirname "$0")/.." && pwd)/users/rgcompare-test-env.nix"

if [[ ! -f "$NIX_FILE" ]]; then
  echo "Error: $NIX_FILE not found" >&2
  exit 1
fi

echo "Fetching latest flyway version from Maven Central..."
LATEST=$(curl -sfL "https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/maven-metadata.xml" \
  | grep '<release>' | sed 's/.*<release>\(.*\)<\/release>.*/\1/')

if [[ -z "$LATEST" ]]; then
  echo "Error: could not determine latest version" >&2
  exit 1
fi

CURRENT=$(grep 'version = ' "$NIX_FILE" | head -1 | sed 's/.*"\(.*\)".*/\1/')
echo "Current version: $CURRENT"
echo "Latest version:  $LATEST"

if [[ "$CURRENT" == "$LATEST" ]]; then
  echo "Already up to date."
  exit 0
fi

URL="https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/${LATEST}/flyway-commandline-${LATEST}-linux-x64.tar.gz"
echo "Prefetching hash for $URL..."
HASH=$(nix-prefetch-url --unpack --type sha256 "$URL")
SRI=$(nix hash convert --hash-algo sha256 --to sri "$HASH")

echo "New hash: $SRI"

sed -i "s|version = \"$CURRENT\"|version = \"$LATEST\"|" "$NIX_FILE"
sed -i "s|sha256 = \".*\"|sha256 = \"$SRI\"|" "$NIX_FILE"

echo "Updated $NIX_FILE: $CURRENT -> $LATEST"

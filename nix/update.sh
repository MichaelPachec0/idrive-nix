#!/usr/bin/env bash
# Refresh nix/sources.json with the current upstream iDrive Linux client.
# Replaces the old idrive/version.sh, which fed GitHub Actions outputs.
set -euo pipefail

VERSION_URL="https://www.idrivedownloads.com/downloads/linux/download-for-linux/version-linux.js"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "Error: not inside a git checkout; cannot locate nix/sources.json" >&2
  exit 1
}
SOURCES="$repo_root/nix/sources.json"

version_js="$(curl -fsSL "$VERSION_URL")"
version="$(echo "$version_js" \
  | sed -n 's/^var linuxScriptVersion = "Version \([0-9.]*\)".*/\1/p')"
url="$(echo "$version_js" \
  | sed -n "s|^var linuxScriptPackageURL = '\(https://[^']*\)'.*|\1|p")"

if [ -z "$version" ] || [ -z "$url" ]; then
  echo "Error: iDrive version or download URL not found" >&2
  exit 1
fi

echo "upstream version: $version"
echo "upstream url:     $url"

if jq -e --arg v "$version" 'has($v)' "$SOURCES" >/dev/null; then
  echo "already pinned, nothing to do"
  exit 0
fi

hash="$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -r .hash)"
echo "hash: $hash"

tmp="$(mktemp)"
jq --arg v "$version" --arg u "$url" --arg h "$hash" \
  '. + {($v): {url: $u, hash: $h}}' "$SOURCES" > "$tmp"
mv "$tmp" "$SOURCES"
echo "pinned $version"

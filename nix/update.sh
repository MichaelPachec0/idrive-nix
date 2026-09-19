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

# Fetch with retries, timeouts and a browser User-Agent. From GitHub-hosted
# (Azure) runner IPs this host is unreliable: it both times out (curl exit
# 28) and, worse, answers the default curl User-Agent with a 200 bot-challenge
# page that carries none of the expected variables. A realistic UA plus
# --retry/--retry-all-errors covers both failure modes; the local dev path is
# unaffected because it already succeeded without them.
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
version_js="$(curl -fsSL \
  --retry 5 --retry-all-errors --retry-delay 3 \
  --connect-timeout 15 --max-time 60 \
  -A "$UA" \
  "$VERSION_URL")"
version="$(echo "$version_js" \
  | sed -n 's/^var linuxScriptVersion = "Version \([0-9.]*\)".*/\1/p')"
url="$(echo "$version_js" \
  | sed -n "s|^var linuxScriptPackageURL = '\(https://[^']*\)'.*|\1|p")"

if [ -z "$version" ] || [ -z "$url" ]; then
  echo "Error: iDrive version or download URL not found" >&2
  # Dump what upstream actually returned so a future block/challenge page is
  # diagnosable from the CI log instead of just this bare message.
  echo "--- fetched ${#version_js} bytes from $VERSION_URL, first 500: ---" >&2
  echo "${version_js:0:500}" >&2
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

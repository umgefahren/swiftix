#!/usr/bin/env bash
#
# Fetches Swift release metadata and prefetches hashes for Nix.
# Usage: ./update.sh [version...]
#   No args: updates all releases from the API
#   With args: only updates the specified versions (e.g., ./update.sh 6.3 6.2.4)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_FILE="$SCRIPT_DIR/data/releases.json"
API_URL="https://www.swift.org/api/v1/install/releases.json"

# Fetch release list from Swift API
echo "Fetching release list from $API_URL..."
RELEASES_JSON=$(curl -sL "$API_URL")

# Parse requested versions (or all)
if [ $# -gt 0 ]; then
  FILTER_VERSIONS=("$@")
else
  FILTER_VERSIONS=()
fi

# Load existing data if present
if [ -f "$DATA_FILE" ]; then
  EXISTING=$(cat "$DATA_FILE")
else
  EXISTING="[]"
fi

# Helper: get existing hash for a version+system from the data file
get_existing_hash() {
  local version="$1" system_key="$2"
  echo "$EXISTING" | jq -r --arg v "$version" --arg s "$system_key" \
    '(.[] | select(.version == $v) | .hashes[$s]) // empty'
}

# Helper: construct download URL
make_url() {
  local tag="$1" platform="$2"
  local category
  category=$(echo "$tag" | sed 's/RELEASE/release/')

  case "$platform" in
    macOS)
      echo "https://download.swift.org/${category}/xcode/${tag}/${tag}-osx.pkg"
      ;;
    linux-x86_64)
      echo "https://download.swift.org/${category}/ubuntu2404/${tag}/${tag}-ubuntu24.04.tar.gz"
      ;;
    linux-aarch64)
      echo "https://download.swift.org/${category}/ubuntu2404-aarch64/${tag}/${tag}-ubuntu24.04-aarch64.tar.gz"
      ;;
  esac
}

# Prefetch a URL and return its sha256 hash
prefetch_hash() {
  local url="$1"
  echo "  Prefetching: $url" >&2

  # Check if URL exists first
  local status
  status=$(curl -sL -o /dev/null -w "%{http_code}" --head "$url" 2>/dev/null || echo "000")
  if [ "$status" != "200" ]; then
    echo "  -> HTTP $status, skipping" >&2
    echo ""
    return
  fi

  local hash
  hash=$(nix-prefetch-url --type sha256 "$url" 2>/dev/null || echo "")
  if [ -n "$hash" ]; then
    # Convert to SRI hash
    local sri
    sri=$(nix hash convert --hash-algo sha256 --to sri "$hash" 2>/dev/null || \
          nix hash to-sri --type sha256 "$hash" 2>/dev/null || \
          echo "$hash")
    echo "$sri"
  else
    echo ""
  fi
}

# Process releases
RESULT="[]"
PLATFORMS=("macOS" "linux-x86_64" "linux-aarch64")

echo "$RELEASES_JSON" | jq -c '.[]' | while read -r release; do
  version=$(echo "$release" | jq -r '.name')
  tag=$(echo "$release" | jq -r '.tag')
  date=$(echo "$release" | jq -r '.date')

  # Filter if specific versions requested
  if [ ${#FILTER_VERSIONS[@]} -gt 0 ]; then
    found=0
    for fv in "${FILTER_VERSIONS[@]}"; do
      if [ "$fv" = "$version" ]; then found=1; break; fi
    done
    if [ "$found" = "0" ]; then
      # Carry over existing entry if present
      existing_entry=$(echo "$EXISTING" | jq -c --arg v "$version" '.[] | select(.version == $v)')
      if [ -n "$existing_entry" ]; then
        RESULT=$(echo "$RESULT" | jq --argjson e "$existing_entry" '. + [$e]')
      fi
      continue
    fi
  fi

  echo "Processing Swift $version ($tag)..."

  hashes="{}"
  for platform in "${PLATFORMS[@]}"; do
    # Check if we already have this hash
    existing_hash=$(get_existing_hash "$version" "$platform")
    if [ -n "$existing_hash" ]; then
      echo "  $platform: using cached hash"
      hashes=$(echo "$hashes" | jq --arg k "$platform" --arg v "$existing_hash" '. + {($k): $v}')
      continue
    fi

    url=$(make_url "$tag" "$platform")
    hash=$(prefetch_hash "$url")
    if [ -n "$hash" ]; then
      echo "  $platform: $hash"
      hashes=$(echo "$hashes" | jq --arg k "$platform" --arg v "$hash" '. + {($k): $v}')
    else
      echo "  $platform: not available"
    fi
  done

  entry=$(jq -n \
    --arg version "$version" \
    --arg tag "$tag" \
    --arg date "$date" \
    --argjson hashes "$hashes" \
    '{version: $version, tag: $tag, date: $date, hashes: $hashes}')

  RESULT=$(echo "$RESULT" | jq --argjson e "$entry" '. + [$e]')
done

echo "$RESULT" | jq '.' > "$DATA_FILE"
echo "Written to $DATA_FILE"
echo "Total releases: $(echo "$RESULT" | jq 'length')"

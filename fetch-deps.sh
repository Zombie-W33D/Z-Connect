#!/usr/bin/env bash
# Download the two binaries Z-Connect needs into ./bin:
#
#   bin/adb    Android platform-tools (Linux x86_64 desktop)
#   bin/gost   gost proxy, built for the phone (ARM64 by default)
#
# Nothing is installed system-wide. Run this once after cloning.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/bin"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

GOST_VERSION="${GOST_VERSION:-v3.3.3}"
GOST_VERSION="v${GOST_VERSION#v}"
GOST_ASSET="${GOST_ASSET:-gost_${GOST_VERSION#v}_linux_arm64.tar.gz}"
GOST_URL="https://github.com/go-gost/gost/releases/download/${GOST_VERSION}/${GOST_ASSET}"
CHECKSUMS_URL="https://github.com/go-gost/gost/releases/download/${GOST_VERSION}/checksums.txt"
PLATFORM_TOOLS_URL="https://dl.google.com/android/repository/platform-tools-latest-linux.zip"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: $1 is required." >&2
    exit 1
  }
}

need curl

mkdir -p "$BIN"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ------------------------------------------------------------------- adb
if [[ -x "$BIN/adb" && "$FORCE" == "0" ]]; then
  echo "adb already present: $BIN/adb"
else
  echo "Downloading Android platform-tools..."
  curl -fL --retry 3 -o "$TMP/platform-tools.zip" "$PLATFORM_TOOLS_URL"

  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$TMP/platform-tools.zip" -d "$TMP/platform-tools"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m zipfile -e "$TMP/platform-tools.zip" "$TMP/platform-tools"
  else
    echo "error: unzip or python3 is required to extract platform-tools." >&2
    exit 1
  fi

  install -m 0755 "$TMP/platform-tools/platform-tools/adb" "$BIN/adb"
  echo "Installed $BIN/adb"
fi

# ------------------------------------------------------------------ gost
if [[ -x "$BIN/gost" && "$FORCE" == "0" ]]; then
  echo "gost already present: $BIN/gost"
else
  echo "Downloading gost ${GOST_VERSION} (${GOST_ASSET})..."
  curl -fL --retry 3 -o "$TMP/gost.tar.gz" "$GOST_URL"
  curl -fL --retry 3 -o "$TMP/checksums.txt" "$CHECKSUMS_URL"

  expected="$(awk -v f="$GOST_ASSET" '$2 == f { print $1; exit }' "$TMP/checksums.txt")"
  if [[ -z "$expected" ]]; then
    echo "error: checksum for $GOST_ASSET not found." >&2
    exit 1
  fi
  actual="$(sha256sum "$TMP/gost.tar.gz" | awk '{ print $1 }')"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: checksum mismatch for $GOST_ASSET." >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    exit 1
  fi

  tar -xzf "$TMP/gost.tar.gz" -C "$TMP" gost
  install -m 0755 "$TMP/gost" "$BIN/gost"
  echo "Installed $BIN/gost"
fi

echo
echo "Dependencies are ready. Next:"
echo "  ./connect.sh"
echo
echo "For an Omarchy bar widget, run:"
echo "  ./install.sh --enable"

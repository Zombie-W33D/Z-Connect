#!/usr/bin/env bash
# Download the three binaries Z-Connect needs into ./bin:
#
#   bin/adb           Android platform-tools (Linux desktop)
#   bin/gost          gost proxy, built for the phone (ARM64 by default)
#   bin/gost-desktop  gost proxy, built for this desktop (used by the TUN helper)
#
# Nothing is installed system-wide. Run this once after cloning.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/bin"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

GOST_VERSION="${GOST_VERSION:-v3.3.3}"
GOST_VERSION="v${GOST_VERSION#v}"
GOST_RELEASE="${GOST_VERSION#v}"
GOST_BASE="https://github.com/go-gost/gost/releases/download/${GOST_VERSION}"
CHECKSUMS_URL="${GOST_BASE}/checksums.txt"
PLATFORM_TOOLS_URL="https://dl.google.com/android/repository/platform-tools-latest-linux.zip"

# The phone is almost always ARM64. The desktop binary must match this host so
# the privileged TUN helper can execute it.
PHONE_ASSET="${GOST_PHONE_ASSET:-gost_${GOST_RELEASE}_linux_arm64.tar.gz}"
case "$(uname -m)" in
  x86_64|amd64) HOST_ARCH="amd64" ;;
  aarch64|arm64) HOST_ARCH="arm64" ;;
  armv7l|armv6l) HOST_ARCH="armv7" ;;
  i386|i686) HOST_ARCH="386" ;;
  *) HOST_ARCH="$(uname -m)" ;;
esac
DESKTOP_ASSET="${GOST_DESKTOP_ASSET:-gost_${GOST_RELEASE}_linux_${HOST_ARCH}.tar.gz}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: $1 is required." >&2
    exit 1
  }
}

need curl
need sha256sum
need tar

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
# One checksums file covers every asset in the release.
if [[ -x "$BIN/gost" && -x "$BIN/gost-desktop" && "$FORCE" == "0" ]]; then
  echo "gost already present: $BIN/gost and $BIN/gost-desktop"
else
  echo "Downloading gost ${GOST_VERSION} checksums..."
  curl -fL --retry 3 -o "$TMP/checksums.txt" "$CHECKSUMS_URL"
fi

download_gost() {
  local name="$1" asset="$2" dest="$3"
  local expected actual

  if [[ -x "$dest" && "$FORCE" == "0" ]]; then
    echo "gost already present: $dest"
    return 0
  fi

  echo "Downloading gost ${GOST_VERSION} (${asset})..."
  curl -fL --retry 3 -o "$TMP/${name}.tar.gz" "${GOST_BASE}/${asset}"

  expected="$(awk -v f="$asset" '$2 == f { print $1; exit }' "$TMP/checksums.txt")"
  if [[ -z "$expected" ]]; then
    echo "error: checksum for $asset not found." >&2
    return 1
  fi
  actual="$(sha256sum "$TMP/${name}.tar.gz" | awk '{ print $1 }')"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: checksum mismatch for $asset." >&2
    echo "  expected $expected" >&2
    echo "  actual   $actual" >&2
    return 1
  fi

  tar -xzf "$TMP/${name}.tar.gz" -C "$TMP" gost
  install -m 0755 "$TMP/gost" "$dest"
  rm -f "$TMP/gost"
  echo "Installed $dest"
}

download_gost phone "$PHONE_ASSET" "$BIN/gost"
download_gost desktop "$DESKTOP_ASSET" "$BIN/gost-desktop"

echo
echo "Dependencies are ready. Next:"
echo "  ./connect.sh"
echo
echo "For an Omarchy bar widget, run:"
echo "  ./install.sh --enable"
echo
echo "For mandatory system-wide routing, install the privileged helper once:"
echo "  sudo ./install.sh --privileged"

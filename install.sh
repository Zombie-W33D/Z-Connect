#!/usr/bin/env bash
# Install Z-Connect into ~/.local/share/z-connect and, optionally, install and
# enable the Omarchy bar widget.
#
#   ./install.sh             install files only
#   ./install.sh --enable    also enable the widget and place it after Network
#
# Override the install location with ZCONNECT_DIR.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${ZCONNECT_DIR:-$HOME/.local/share/z-connect}"
PLUGIN_ID="zconnect.phone-tether"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID"
ENABLE=0
[[ "${1:-}" == "--enable" ]] && ENABLE=1

echo "Installing Z-Connect to $DEST"
mkdir -p "$DEST"

if [[ "$SRC" != "$DEST" ]]; then
  # Copy the runtime files. bin binaries are copied when present; otherwise
  # fetch-deps.sh downloads them after installation.
  cp -a "$SRC"/connect.sh "$SRC"/disconnect.sh "$SRC"/status.sh \
        "$SRC"/proxy.sh "$SRC"/env.sh "$SRC"/lib.sh "$SRC"/fetch-deps.sh \
        "$SRC"/chromium-zconnect.sh "$SRC"/brave-zconnect.sh \
        "$SRC"/README.md "$SRC"/LICENSE "$DEST"/
  mkdir -p "$DEST/docs" "$DEST/bin" "$DEST/omarchy"
  cp -a "$SRC"/docs/. "$DEST/docs"/
  cp -a "$SRC"/bin/. "$DEST/bin"/
  cp -a "$SRC"/omarchy/. "$DEST/omarchy"/
fi

chmod +x "$DEST"/*.sh

echo "Installing the Omarchy widget to $PLUGIN_DIR"
mkdir -p "$PLUGIN_DIR"
cp -a "$DEST"/omarchy/"$PLUGIN_ID"/. "$PLUGIN_DIR"/

if [[ -x "$DEST/bin/adb" && -x "$DEST/bin/gost" ]]; then
  echo "Bundled adb and gost are present."
else
  echo
  echo "Binaries are not installed yet. Run:"
  echo "  cd \"$DEST\" && ./fetch-deps.sh"
fi

if [[ "$ENABLE" == "1" ]]; then
  if command -v omarchy >/dev/null 2>&1; then
    echo
    echo "Enabling the widget..."
    omarchy plugin enable "$PLUGIN_ID" --section right || true
    omarchy bar move "$PLUGIN_ID" --after omarchy.network || true
  else
    echo "warning: the omarchy command was not found; enable the widget from the shell settings." >&2
  fi
else
  echo
  echo "To enable the widget:"
  echo "  omarchy plugin enable $PLUGIN_ID --section right"
  echo "  omarchy bar move $PLUGIN_ID --after omarchy.network"
fi

echo
echo "Done. Start the tunnel with:"
echo "  cd \"$DEST\" && ./connect.sh"

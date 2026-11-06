#!/usr/bin/env bash
# Launch Chromium through the phone tunnel.
# Uses a separate profile so it never conflicts with an already-running browser.
set -euo pipefail
PORT="${ZCONNECT_PORT:-1080}"
exec chromium \
  --user-data-dir="${HOME}/.config/zconnect-chromium" \
  --proxy-server="socks5://127.0.0.1:${PORT}" \
  --no-first-run --no-default-browser-check \
  "$@"

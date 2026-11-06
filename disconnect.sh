#!/usr/bin/env bash
# Z-Connect: stop the phone-side proxy and remove the USB port forward.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

ADB="$(zconnect_adb)" || {
  echo "error: adb not found. Install platform-tools or run ./fetch-deps.sh." >&2
  exit 1
}

PORT="$ZCONNECT_PORT"

"$ADB" shell "pkill -f '[z]connect-gost' 2>/dev/null || true" >/dev/null 2>&1 || true
"$ADB" forward --remove "tcp:${PORT}" >/dev/null 2>&1 || true

echo "Disconnected. Phone-side proxy stopped and tcp:${PORT} forward removed."

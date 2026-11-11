#!/usr/bin/env bash
# Z-Connect: stop the phone-side proxy and remove the USB port forward.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

PORT="$ZCONNECT_PORT"

# Restore the desktop's previous proxy settings first. This does not need the
# phone, so it also works when the cable was pulled before Disconnect.
if [[ -x "$HERE/proxy.sh" ]]; then
  "$HERE/proxy.sh" disable >/dev/null 2>&1 || \
    echo "warning: could not restore the previous system proxy settings." >&2
fi

ADB="$(zconnect_adb)" || {
  echo "error: adb not found. Install platform-tools or run ./fetch-deps.sh." >&2
  exit 1
}

"$ADB" shell "pkill -f '[z]connect-gost' 2>/dev/null || true" >/dev/null 2>&1 || true
"$ADB" forward --remove "tcp:${PORT}" >/dev/null 2>&1 || true

echo "Disconnected. Phone-side proxy stopped and tcp:${PORT} forward removed."

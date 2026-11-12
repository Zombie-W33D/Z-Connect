#!/usr/bin/env bash
# Z-Connect: stop the phone-side proxy and remove the USB port forward.
#
# The stable local relay is left running in direct mode. Apps that were using
# the relay keep working through the normal network instead of holding a dead
# proxy endpoint.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RELAY_PORT="$ZCONNECT_PORT"
PHONE_PORT="$ZCONNECT_PHONE_PORT"
RELAY="$HERE/relay.sh"

# Restore the desktop's previous proxy settings first. This does not need the
# phone, so it also works when the cable was pulled before Disconnect.
if [[ -x "$HERE/proxy.sh" ]]; then
  "$HERE/proxy.sh" disable >/dev/null 2>&1 || \
    echo "warning: could not restore the previous system proxy settings." >&2
fi

# Make open relay users fall back to the normal network before stopping the
# phone-side process.
if [[ -x "$RELAY" ]]; then
  "$RELAY" mode direct >/dev/null 2>&1 || true
fi

ADB="$(zconnect_adb)" || {
  echo "error: adb not found. Install platform-tools or run ./fetch-deps.sh." >&2
  exit 1
}

"$ADB" shell "pkill -f '[z]connect-gost' 2>/dev/null || true" >/dev/null 2>&1 || true
"$ADB" forward --remove "tcp:${PHONE_PORT}" >/dev/null 2>&1 || true
# Remove a legacy forward from versions that forwarded the relay port directly.
"$ADB" forward --remove "tcp:${RELAY_PORT}" >/dev/null 2>&1 || true

echo "Disconnected. Phone-side proxy stopped."
if [[ -x "$RELAY" ]]; then
  echo "Relay is in direct mode; apps using 127.0.0.1:${RELAY_PORT} now use the normal network."
fi

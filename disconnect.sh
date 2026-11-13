#!/usr/bin/env bash
# Z-Connect: stop the phone-side proxy and remove the USB port forward.
#
# Mandatory routing is removed first, so the desktop does not lose its normal
# connection while the phone-side process is being stopped. The always-on
# system proxy is left in place by default: the stable relay switches to direct
# mode, so apps that use it keep working through the normal network.
#
#   ./disconnect.sh                 stop the phone, keep the system proxy on
#   ./disconnect.sh --proxy-off     also restore the previous proxy settings
#   ZCONNECT_DISCONNECT_PROXY=1 ./disconnect.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

PHONE_PORT="$ZCONNECT_PHONE_PORT"
RELAY="$HERE/relay.sh"
PROXY_OFF="${ZCONNECT_DISCONNECT_PROXY:-0}"

for arg in "$@"; do
  case "$arg" in
    --proxy-off) PROXY_OFF=1 ;;
    --keep-proxy) PROXY_OFF=0 ;;
    -h|--help)
      echo "usage: $0 [--proxy-off|--keep-proxy]"
      exit 0
      ;;
    *)
      echo "error: unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

# 1. Remove the mandatory routes before anything else. If this fails, say so
#    loudly: the desktop would otherwise stay pinned to a disappearing phone.
if [[ -x "$HERE/lockdown.sh" ]]; then
  if ! "$HERE/lockdown.sh" disable >/dev/null 2>&1; then
    echo "warning: could not remove mandatory routing. Run:" >&2
    echo "  $HERE/lockdown.sh disable" >&2
  fi
fi

# 2. Make open relay users fall back to the normal network before stopping the
#    phone-side process.
if [[ -x "$RELAY" ]]; then
  "$RELAY" mode direct >/dev/null 2>&1 || true
fi

# 3. Optionally restore the desktop's previous proxy settings.
if [[ "$PROXY_OFF" == "1" && -x "$HERE/proxy.sh" ]]; then
  "$HERE/proxy.sh" disable >/dev/null 2>&1 || \
    echo "warning: could not restore the previous system proxy settings." >&2
fi

# 4. Stop the phone-side process and remove the forward. A missing phone is not
#    an error: the relay is already in direct mode.
ADB="$(zconnect_adb)" || {
  echo "Disconnected. The relay is in direct mode."
  if [[ "$PROXY_OFF" == "0" ]]; then
    echo "The system proxy remains on and now uses the normal network."
  fi
  exit 0
}

zconnect_kill_phone_gost "$ADB"
"$ADB" forward --remove "tcp:${PHONE_PORT}" >/dev/null 2>&1 || true

echo "Disconnected. The phone-side proxy and USB forward are stopped."
if [[ "$PROXY_OFF" == "0" ]]; then
  echo "The system proxy remains on; the relay uses the normal network."
  echo "Run ./proxy.sh disable to restore the previous proxy settings."
else
  echo "The previous system proxy settings were restored."
fi

#!/usr/bin/env bash
# Z-Connect: start a SOCKS5 tether over USB/ADB.
#
# The phone-side process (gost) uses the phone's own mobile data. It is an
# ordinary app/shell process, not Android's tethering service, so Android's
# hotspot/tethering entitlement check is not involved.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

ADB="$(zconnect_adb)" || {
  echo "error: adb not found. Install platform-tools or run ./fetch-deps.sh." >&2
  exit 1
}

GOST="$HERE/bin/gost"
PHONE_GOST="/data/local/tmp/zconnect-gost"
PORT="$ZCONNECT_PORT"

if [[ ! -x "$GOST" ]]; then
  echo "error: gost not found at $GOST. Run ./fetch-deps.sh first." >&2
  exit 1
fi

echo "[1/5] Starting adb and waiting for the phone..."
"$ADB" start-server >/dev/null
if ! timeout "${ZCONNECT_WAIT:-25}" "$ADB" wait-for-device; then
  echo "error: no phone detected. Check the USB cable and that USB debugging is on." >&2
  exit 1
fi

state="$("$ADB" get-state 2>/dev/null || true)"
if [[ "$state" != "device" ]]; then
  echo "error: the phone is ${state:-offline}. Unlock it and allow USB debugging." >&2
  exit 1
fi

echo "[2/5] Detecting the phone's DNS resolver..."
PHONE_DNS="$(zconnect_phone_dns "$ADB")"
DNS="${ZCONNECT_DNS:-}"
if [[ -z "$DNS" ]]; then
  if [[ -n "$PHONE_DNS" ]]; then
    # gost wants host:port entries; add the public resolvers as fallbacks for
    # networks whose carrier DNS blocks or rewrites queries.
    DNS="$(printf '%s\n' "$PHONE_DNS" | paste -sd, - | sed 's/\([^,]*\)/\1:53/g'),8.8.8.8:53,1.1.1.1:53"
  else
    DNS="8.8.8.8:53,1.1.1.1:53"
  fi
fi

echo "[3/5] Ensuring the phone-side proxy binary is present..."
if ! "$ADB" shell "[ -x $PHONE_GOST ]" >/dev/null 2>&1; then
  "$ADB" push "$GOST" "$PHONE_GOST" >/dev/null
  "$ADB" shell chmod 755 "$PHONE_GOST"
fi

echo "[4/5] Restarting the phone-side SOCKS5 proxy..."
"$ADB" shell "pkill -f '[z]connect-gost' 2>/dev/null || true" >/dev/null 2>&1 || true
sleep 1
# The resolver list is explicit because Android's Go resolver does not always
# use the mobile network's DNS servers.
"$ADB" shell "cd /data/local/tmp && (nohup ./zconnect-gost -L 'socks5://127.0.0.1:${PORT}?resolver=${DNS}' > zconnect-gost.log 2>&1 &)"
sleep 1

echo "[5/5] Forwarding port ${PORT} over USB..."
"$ADB" forward --remove "tcp:${PORT}" >/dev/null 2>&1 || true
"$ADB" forward "tcp:${PORT}" "tcp:${PORT}" >/dev/null

echo
echo "Testing the tunnel..."
if IP="$(curl -fsS --socks5-hostname "127.0.0.1:${PORT}" --max-time 20 https://api.ipify.org 2>/dev/null)"; then
  echo
  echo "Connected."
  echo "  SOCKS5 proxy : 127.0.0.1:${PORT}"
  echo "  Phone egress : ${IP}"
  echo
  echo "Browser test   : $HERE/chromium-zconnect.sh"
  echo "Terminal apps  : source $HERE/env.sh"
  echo "Disconnect     : $HERE/disconnect.sh"
else
  echo "error: the proxy did not answer. Phone-side log:" >&2
  "$ADB" shell cat /data/local/tmp/zconnect-gost.log >&2 || true
  exit 1
fi

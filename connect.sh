#!/usr/bin/env bash
# Z-Connect: start a SOCKS5 tether over USB/ADB.
#
# The phone-side process (gost) uses the phone's own mobile data. It is an
# ordinary app/shell process, not Android's tethering service, so Android's
# hotspot/tethering entitlement check is not involved.
#
# Apps talk to a stable local relay on ZCONNECT_PORT. The relay forwards to the
# phone on ZCONNECT_PHONE_PORT, and falls back to the normal network when the
# phone disappears. Open apps using the relay therefore switch networks without
# a restart. TCP and UDP are both carried; UDP uses gost's UDP-over-TCP mode so
# it can cross the adb forward.
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
RELAY_PORT="$ZCONNECT_PORT"
PHONE_PORT="$ZCONNECT_PHONE_PORT"
RELAY="$HERE/relay.sh"

if [[ ! -x "$GOST" ]]; then
  echo "error: gost not found at $GOST. Run ./fetch-deps.sh first." >&2
  exit 1
fi
if [[ ! -x "$RELAY" ]]; then
  echo "error: relay.sh not found at $RELAY. Reinstall the scripts." >&2
  exit 1
fi

echo "[1/7] Starting adb and waiting for the phone..."
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

echo "[2/7] Preparing the stable local relay..."
# Older versions forwarded the relay port directly to the phone. Remove that
# forward so the local relay can own the port.
"$ADB" forward --remove "tcp:${RELAY_PORT}" >/dev/null 2>&1 || true
if ! "$RELAY" ensure; then
  echo "error: could not start the local relay on 127.0.0.1:${RELAY_PORT}." >&2
  exit 1
fi
"$RELAY" mode phone >/dev/null

echo "[3/7] Detecting the phone's DNS resolver..."
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

echo "[4/7] Ensuring the phone-side proxy binary is present..."
if ! "$ADB" shell "[ -x $PHONE_GOST ]" >/dev/null 2>&1; then
  "$ADB" push "$GOST" "$PHONE_GOST" >/dev/null
  "$ADB" shell chmod 755 "$PHONE_GOST"
fi

echo "[5/7] Restarting the phone-side SOCKS5 proxy (TCP + UDP)..."
zconnect_kill_phone_gost "$ADB"
sleep 1
# The resolver list is explicit because Android's Go resolver does not always
# use the mobile network's DNS servers. udp=true enables both standard SOCKS5
# UDP ASSOCIATE and gost's UDP-over-TCP extension (0xF3).
"$ADB" shell "cd /data/local/tmp && (nohup ./zconnect-gost -L 'socks5://127.0.0.1:${PHONE_PORT}?udp=true&resolver=${DNS}' > zconnect-gost.log 2>&1 &)"
sleep 1

echo "[6/7] Forwarding port ${PHONE_PORT} over USB..."
"$ADB" forward --remove "tcp:${PHONE_PORT}" >/dev/null 2>&1 || true
"$ADB" forward "tcp:${PHONE_PORT}" "tcp:${PHONE_PORT}" >/dev/null

echo "[7/7] Testing the tunnel..."
if ! IP="$(curl -fsS --socks5-hostname "127.0.0.1:${PHONE_PORT}" --max-time 20 https://api.ipify.org 2>/dev/null)"; then
  echo "error: the phone proxy did not answer. Phone-side log:" >&2
  "$ADB" shell cat /data/local/tmp/zconnect-gost.log >&2 || true
  "$RELAY" mode direct >/dev/null 2>&1 || true
  exit 1
fi
if ! RELAY_IP="$(curl -fsS --socks5-hostname "127.0.0.1:${RELAY_PORT}" --max-time 20 https://api.ipify.org 2>/dev/null)"; then
  echo "error: the phone proxy works, but the local relay did not answer." >&2
  "$RELAY" log >&2 || true
  "$RELAY" mode direct >/dev/null 2>&1 || true
  exit 1
fi

SYSTEM_PROXY="off"
if [[ "${ZCONNECT_AUTO_PROXY:-${PDANET_AUTO_PROXY:-1}}" != "0" && -x "$HERE/proxy.sh" ]]; then
  if PROXY_OUTPUT="$("$HERE/proxy.sh" enable 2>&1)"; then
    SYSTEM_PROXY="on"
  else
    echo
    echo "warning: the tunnel is up, but the system proxy was not enabled:" >&2
    printf '%s\n' "$PROXY_OUTPUT" | sed 's/^/  /' >&2
  fi
fi

LOCKDOWN="off"
if [[ "${ZCONNECT_AUTO_LOCKDOWN:-1}" != "0" && -x "$HERE/lockdown.sh" ]]; then
  if LOCK_OUTPUT="$("$HERE/lockdown.sh" enable 2>&1)"; then
    LOCKDOWN="on"
  else
    echo
    echo "warning: mandatory routing was not enabled:" >&2
    printf '%s\n' "$LOCK_OUTPUT" | sed 's/^/  /' >&2
  fi
fi

echo
echo "Connected."
echo "  Relay endpoint: 127.0.0.1:${RELAY_PORT} (TCP + UDP)"
echo "  Phone egress  : ${IP}"
echo "  System proxy  : ${SYSTEM_PROXY}"
echo "  Mandatory route: ${LOCKDOWN}"
if [[ "$RELAY_IP" != "$IP" ]]; then
  echo "  Relay egress  : ${RELAY_IP}"
fi
echo "  Route switch  : apps using 127.0.0.1:${RELAY_PORT} switch automatically"
echo
echo "Browser test   : $HERE/chromium-zconnect.sh"
echo "Terminal apps  : source $HERE/env.sh"
echo "Disconnect     : $HERE/disconnect.sh"

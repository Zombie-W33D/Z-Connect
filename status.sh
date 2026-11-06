#!/usr/bin/env bash
# Report the state of the phone tether as key=value lines.
#
#   status.sh          quick check (no network request)
#   status.sh --full   also test the SOCKS5 tunnel and fetch the phone egress IP
#
# This script never needs the desktop's own internet: the only network request
# it makes is through the phone-side proxy at 127.0.0.1:$PORT.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

ADB="$(zconnect_adb)" || {
  echo "adb_state=missing"
  echo "error=adb not found. Install platform-tools or run ./fetch-deps.sh."
  exit 0
}

PORT="$ZCONNECT_PORT"
FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

emit() {
  local key="$1" value="${2:-}"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  printf '%s=%s\n' "$key" "$value"
}

# First attached device, if any. `adb devices` prints:
#   List of devices attached
#   <serial>               device
line="$("$ADB" devices 2>/dev/null | awk 'NF >= 2 && $1 != "List" { print $1 " " $2; exit }')"
device=""
state="disconnected"
if [[ -n "$line" ]]; then
  read -r device state <<< "$line"
fi

emit adb_state "$state"

if [[ "$state" != "device" ]]; then
  emit forward no
  emit gost_pid ""
  emit proxy unknown
  emit port "$PORT"
  exit 0
fi

model="$("$ADB" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
operator="$("$ADB" shell getprop gsm.operator.alpha 2>/dev/null | tr -d '\r')"
if [[ -z "$operator" ]]; then
  operator="$("$ADB" shell getprop gsm.sim.operator.alpha 2>/dev/null | tr -d '\r')"
fi
network="$("$ADB" shell getprop gsm.network.type 2>/dev/null | tr -d '\r')"
battery="$("$ADB" shell dumpsys battery 2>/dev/null | awk -F': ' '/^[[:space:]]*level:/ { print $2; exit }' | tr -d '\r')"
gost_pid="$("$ADB" shell pidof zconnect-gost 2>/dev/null | tr -d '\r')"

forward="no"
if "$ADB" forward --list 2>/dev/null | awk -v p="tcp:$PORT" '$2 == p { found = 1 } END { exit(found ? 0 : 1) }'; then
  forward="yes"
fi

proxy="unknown"
egress=""
if [[ "$forward" == "yes" && -n "$gost_pid" && "$FULL" == "1" ]]; then
  if egress="$(curl -fsS --socks5-hostname "127.0.0.1:${PORT}" --max-time 12 https://api.ipify.org 2>/dev/null)"; then
    egress="$(printf '%s' "$egress" | tr -d '\r\n ')"
    proxy="yes"
  else
    proxy="no"
    egress=""
  fi
fi

emit model "$model"
emit operator "$operator"
emit network "$network"
emit battery "$battery"
emit gost_pid "$gost_pid"
emit forward "$forward"
emit proxy "$proxy"
emit port "$PORT"
emit egress_ip "$egress"

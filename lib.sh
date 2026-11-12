#!/usr/bin/env bash
# Shared helpers for Z-Connect. Source this file from the other scripts.

ZCONNECT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ZCONNECT_PORT is the stable local relay port that apps use. The phone-side
# SOCKS server and adb forward use ZCONNECT_PHONE_PORT so the relay can own the
# stable endpoint and switch between phone and direct routes.
ZCONNECT_PORT="${ZCONNECT_PORT:-${PDANET_PORT:-1080}}"
ZCONNECT_PHONE_PORT="${ZCONNECT_PHONE_PORT:-$((ZCONNECT_PORT + 1))}"

# Print a usable adb executable. Preference order:
#   1. $ADB, if it is a path or a command name
#   2. adb from PATH
#   3. the copy downloaded by fetch-deps.sh
zconnect_adb() {
  if [[ -n "${ADB:-}" ]]; then
    if [[ -x "$ADB" ]]; then
      printf '%s\n' "$ADB"
      return 0
    fi
    if command -v "$ADB" >/dev/null 2>&1; then
      command -v "$ADB"
      return 0
    fi
  fi

  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return 0
  fi

  if [[ -x "$ZCONNECT_HOME/bin/adb" ]]; then
    printf '%s\n' "$ZCONNECT_HOME/bin/adb"
    return 0
  fi

  return 1
}

# Print the phone's current IPv4 DNS servers, one per line. Falls back to
# nothing if the information is not available on this Android version.
zconnect_phone_dns() {
  local adb="$1"
  "$adb" shell dumpsys connectivity 2>/dev/null \
    | grep -o 'DnsAddresses: \[[^]]*\]' \
    | head -n 1 \
    | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
    | head -n 2 \
    || true
}

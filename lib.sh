#!/usr/bin/env bash
# Shared helpers for Z-Connect. Source this file from the other scripts.

ZCONNECT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ZCONNECT_PORT is the stable local relay port that apps use. The phone-side
# SOCKS server and adb forward use ZCONNECT_PHONE_PORT so the relay can own the
# stable endpoint and switch between phone and direct routes.
ZCONNECT_PORT="${ZCONNECT_PORT:-${PDANET_PORT:-1080}}"
ZCONNECT_PHONE_PORT="${ZCONNECT_PHONE_PORT:-${PDANET_PHONE_PORT:-$((ZCONNECT_PORT + 1))}}"
ZCONNECT_RELAY_FALLBACK_DIRECT="${ZCONNECT_RELAY_FALLBACK_DIRECT:-${PDANET_RELAY_FALLBACK_DIRECT:-1}}"

# Privileged helper installed by `install.sh --privileged`. It is root-owned and
# the only command allowed through the restricted sudoers entry.
ZCONNECT_LOCKDOWN_HELPER="${ZCONNECT_LOCKDOWN_HELPER:-/usr/local/libexec/zconnect-lockdown}"
ZCONNECT_LOCKDOWN_STATE="${ZCONNECT_LOCKDOWN_STATE:-/run/zconnect/lockdown.state}"

# User systemd units. `proxy.sh boot on` and `install.sh` both install these.
ZCONNECT_USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

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
    | head -n 2 || true
}

# Stop the phone-side gost. Android's toybox pkill does not reliably match -f,
# and the process name is not always the pushed filename, so kill by pid.
zconnect_kill_phone_gost() {
  local adb="$1"
  "$adb" shell 'for p in $(pidof zconnect-gost 2>/dev/null) $(pidof gost 2>/dev/null); do kill "$p" 2>/dev/null; done' \
    >/dev/null 2>&1 || true
}

# True when the phone-side gost and the USB forward are both present.
zconnect_tunnel_up() {
  local output forward gost
  [[ -x "$ZCONNECT_HOME/status.sh" ]] || return 1
  output="$("$ZCONNECT_HOME/status.sh" --quick 2>/dev/null || true)"
  forward="$(printf '%s\n' "$output" | awk -F= '$1 == "forward" { print $2; exit }')"
  gost="$(printf '%s\n' "$output" | awk -F= '$1 == "gost_pid" { print $2; exit }')"
  [[ "$forward" == "yes" && -n "$gost" ]]
}

# True when a phone is attached over adb (regardless of the tunnel state).
zconnect_phone_present() {
  local output
  [[ -x "$ZCONNECT_HOME/status.sh" ]] || return 1
  output="$("$ZCONNECT_HOME/status.sh" --quick 2>/dev/null || true)"
  [[ "$(printf '%s\n' "$output" | awk -F= '$1 == "adb_state" { print $2; exit }')" == "device" ]]
}

# Write the systemd user units. Safe to call repeatedly. Returns non-zero when
# systemd is unavailable, but still leaves the unit files in place.
zconnect_install_user_units() {
  local relay_unit="$ZCONNECT_USER_UNIT_DIR/zconnect-relay.service"
  local proxy_unit="$ZCONNECT_USER_UNIT_DIR/zconnect-proxy.service"

  mkdir -p "$ZCONNECT_USER_UNIT_DIR" 2>/dev/null || return 1

  cat > "$relay_unit" <<EOF
[Unit]
Description=Z-Connect stable SOCKS5 relay
After=default.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$ZCONNECT_HOME/relay.sh run
Restart=always
RestartSec=2
Environment=ZCONNECT_PORT=$ZCONNECT_PORT
Environment=ZCONNECT_PHONE_PORT=$ZCONNECT_PHONE_PORT
Environment=ZCONNECT_RELAY_FALLBACK_DIRECT=$ZCONNECT_RELAY_FALLBACK_DIRECT

[Install]
WantedBy=default.target
EOF

  cat > "$proxy_unit" <<EOF
[Unit]
Description=Z-Connect boot-time system proxy
After=zconnect-relay.service
Wants=zconnect-relay.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$ZCONNECT_HOME/proxy.sh boot-run
ExecStop=$ZCONNECT_HOME/proxy.sh boot-stop

[Install]
WantedBy=default.target
EOF

  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user daemon-reload >/dev/null 2>&1 || return 1
  return 0
}

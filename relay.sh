#!/usr/bin/env bash
# Manage the stable local SOCKS5 relay.
#
# Apps point at one fixed local port. The relay sends new connections through
# the phone when the mode is "phone", and through the normal network when it is
# "direct". If the phone disappears, phone mode falls back to the normal
# network so open apps keep working.
#
# Commands:
#   relay.sh start
#   relay.sh stop
#   relay.sh restart
#   relay.sh ensure
#   relay.sh mode phone|direct
#   relay.sh status
#   relay.sh cleanup
#   relay.sh log
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RELAY_PORT="$ZCONNECT_PORT"
PHONE_PORT="$ZCONNECT_PHONE_PORT"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zconnect"
PIDFILE="$STATE_DIR/relay.pid"
MODEFILE="$STATE_DIR/relay-mode"
LOGFILE="$STATE_DIR/relay.log"
LOCKFILE="$STATE_DIR/relay.lock"
FALLBACK_DIRECT="${ZCONNECT_RELAY_FALLBACK_DIRECT:-1}"

mkdir -p "$STATE_DIR" 2>/dev/null || true
chmod 700 "$STATE_DIR" 2>/dev/null || true
[[ -f "$MODEFILE" ]] || printf 'direct\n' > "$MODEFILE" 2>/dev/null || true

lock_state() {
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>"$LOCKFILE" || return 1
  if ! flock -w 10 9; then
    echo "error: another relay operation is already running." >&2
    return 1
  fi
}

relay_pid() {
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null)" || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'relay.py' || return 1
  printf '%s' "$pid"
}

is_running() {
  relay_pid >/dev/null 2>&1
}

port_listening() {
  command -v ss >/dev/null 2>&1 || return 1
  ss -ltn 2>/dev/null | awk -v p=":${RELAY_PORT}" '$4 ~ p "$" { found = 1 } END { exit(found ? 0 : 1) }'
}

read_mode() {
  local mode
  mode="$(cat "$MODEFILE" 2>/dev/null)" || mode="direct"
  mode="${mode//[[:space:]]/}"
  [[ "$mode" == "phone" || "$mode" == "direct" ]] || mode="direct"
  printf '%s' "$mode"
}

write_mode() {
  local mode="$1" tmp
  [[ "$mode" == "phone" || "$mode" == "direct" ]] || {
    echo "error: relay mode must be phone or direct." >&2
    return 2
  }
  tmp="$MODEFILE.tmp.$$"
  printf '%s\n' "$mode" > "$tmp" || return 1
  mv "$tmp" "$MODEFILE" || return 1
}

start_relay() {
  local pid fallback_args=()

  if pid="$(relay_pid)"; then
    echo "Relay is already running (pid $pid) on 127.0.0.1:${RELAY_PORT}."
    return 0
  fi

  if port_listening; then
    echo "error: port ${RELAY_PORT} is already in use." >&2
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 is required for the relay." >&2
    return 1
  fi
  if [[ ! -f "$HERE/relay.py" ]]; then
    echo "error: relay.py not found next to relay.sh." >&2
    return 1
  fi

  [[ "$FALLBACK_DIRECT" == "0" ]] && fallback_args+=(--no-fallback-direct)

  nohup python3 -u "$HERE/relay.py" \
    --listen "127.0.0.1:${RELAY_PORT}" \
    --upstream "127.0.0.1:${PHONE_PORT}" \
    --mode-file "$MODEFILE" \
    "${fallback_args[@]}" >> "$LOGFILE" 2>&1 9>&- &
  pid=$!
  printf '%s\n' "$pid" > "$PIDFILE"

  for _ in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "error: the relay exited during startup. Recent log:" >&2
      tail -n 10 "$LOGFILE" >&2 || true
      rm -f "$PIDFILE"
      return 1
    fi
    if port_listening; then
      echo "Relay started on 127.0.0.1:${RELAY_PORT} (phone upstream 127.0.0.1:${PHONE_PORT})."
      return 0
    fi
    sleep 0.1
  done

  echo "error: the relay did not open port ${RELAY_PORT}. Recent log:" >&2
  tail -n 10 "$LOGFILE" >&2 || true
  kill "$pid" 2>/dev/null || true
  rm -f "$PIDFILE"
  return 1
}

stop_relay() {
  local pid
  if ! pid="$(relay_pid)"; then
    rm -f "$PIDFILE"
    echo "Relay is not running."
    return 0
  fi

  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
  echo "Relay stopped."
}

cmd_status() {
  local pid="" running="no" mode
  if pid="$(relay_pid)"; then
    running="yes"
  fi
  mode="$(read_mode)"
  printf 'relay_running=%s\n' "$running"
  printf 'relay_pid=%s\n' "$pid"
  printf 'relay_mode=%s\n' "$mode"
  printf 'relay_port=%s\n' "$RELAY_PORT"
  printf 'phone_port=%s\n' "$PHONE_PORT"
  printf 'relay_fallback_direct=%s\n' "$FALLBACK_DIRECT"
}

cmd_cleanup() {
  local mode output forward gost
  if ! is_running; then
    echo "Relay is not running."
    return 0
  fi
  mode="$(read_mode)"
  [[ "$mode" == "phone" ]] || {
    echo "Relay is already in direct mode."
    return 0
  }

  output="$("$HERE/status.sh" --quick 2>/dev/null || true)"
  forward="$(printf '%s\n' "$output" | awk -F= '$1 == "forward" { print $2; exit }')"
  gost="$(printf '%s\n' "$output" | awk -F= '$1 == "gost_pid" { print $2; exit }')"
  if [[ "$forward" == "yes" && -n "$gost" ]]; then
    echo "Relay is in phone mode and the tunnel is up."
    return 0
  fi
  write_mode direct
  echo "Relay switched to direct mode because the phone tunnel is down."
}

case "${1:-status}" in
  start) lock_state || exit 1; start_relay ;;
  stop) lock_state || exit 1; stop_relay ;;
  restart) lock_state || exit 1; stop_relay; start_relay ;;
  ensure) lock_state || exit 1; start_relay ;;
  mode)
    lock_state || exit 1
    write_mode "${2:-}"
    echo "Relay mode: $(read_mode)"
    ;;
  status) cmd_status ;;
  cleanup) lock_state || exit 1; cmd_cleanup ;;
  log) tail -n 50 "$LOGFILE" 2>/dev/null || true ;;
  *)
    echo "usage: $0 {start|stop|restart|ensure|mode phone|mode direct|status|cleanup|log}" >&2
    exit 2
    ;;
esac

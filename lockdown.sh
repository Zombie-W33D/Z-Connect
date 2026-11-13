#!/usr/bin/env bash
# Enable or disable mandatory system-wide routing through the phone.
#
# This is the "no app can bypass the tunnel" mode. It uses a root-owned helper
# that runs gost as a transparent TCP/UDP proxy and installs the iptables and
# policy-routing rules. The helper is installed once with:
#
#   ./install.sh --privileged
#
# The helper is the only command allowed through the restricted sudoers entry,
# so the desktop does not need a general passwordless sudo rule.
#
# Commands:
#   lockdown.sh enable    route all desktop traffic through the phone
#   lockdown.sh disable   remove the rules and restore normal routing
#   lockdown.sh cleanup   disable when the phone tunnel is down
#   lockdown.sh status    print key=value state
#   lockdown.sh install   run install.sh --privileged
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

HELPER="$ZCONNECT_LOCKDOWN_HELPER"
STATE="$ZCONNECT_LOCKDOWN_STATE"

helper_installed() {
  [[ -x "$HELPER" ]]
}

is_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

run_helper() {
  if is_root; then
    "$HELPER" "$@"
  elif [[ -t 0 && -t 1 ]]; then
    # Interactive terminal: allow sudo to ask for a password.
    sudo "$HELPER" "$@"
  else
    # The panel and other non-interactive callers must never block on a prompt.
    sudo -n "$HELPER" "$@"
  fi
}

read_state() {
  local key="$1"
  [[ -r "$STATE" ]] || return 1
  awk -F= -v k="$key" '$1 == k { print $2; exit }' "$STATE"
}

state_pid() {
  local pid
  pid="$(read_state lockdown_gost_pid 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$pid"
}

lockdown_state_on() {
  [[ "$(read_state lockdown 2>/dev/null || true)" == "on" ]]
}

lockdown_on() {
  local pid
  lockdown_state_on || return 1
  pid="$(state_pid)" || return 1
  # The helper runs gost as root, so an unprivileged `kill -0` can return EPERM
  # even while the process is alive. /proc is readable and does not need sudo.
  [[ -d "/proc/$pid" ]]
}

emit() {
  printf '%s=%s\n' "$1" "${2:-}"
}

cmd_enable() {
  if ! helper_installed; then
    echo "error: the privileged helper is not installed." >&2
    echo "Run: $HERE/install.sh --privileged" >&2
    return 1
  fi
  if ! zconnect_tunnel_up; then
    echo "error: the phone tunnel is not up. Connect the phone first." >&2
    return 1
  fi
  if ! run_helper apply; then
    echo "error: could not enable mandatory routing." >&2
    echo "If sudo asked for a password, reinstall the helper with:" >&2
    echo "  $HERE/install.sh --privileged" >&2
    return 1
  fi
  echo "Mandatory routing enabled: all TCP and UDP traffic uses the phone."
  echo "Apps that ignore the system proxy are captured too."
}

cmd_disable() {
  if ! helper_installed; then
    echo "Mandatory routing helper is not installed; nothing to disable."
    return 0
  fi
  if ! run_helper cleanup; then
    echo "error: could not disable mandatory routing." >&2
    return 1
  fi
  echo "Mandatory routing disabled; normal desktop routing restored."
}

cmd_cleanup() {
  lockdown_state_on || return 0
  # If the phone-side tunnel is gone, the transparent rules would strand the
  # desktop: every connection would be sent to a proxy that cannot answer.
  # Remove them even when adb still sees the phone.
  if zconnect_tunnel_up; then
    echo "Mandatory routing stays on because the phone tunnel is still up."
    return 0
  fi
  cmd_disable
}

cmd_status() {
  local helper="missing" lock="off" pid="" port="" mark="" phone_port="" ipv6="" lan=""

  helper_installed && helper="installed"
  if lockdown_on; then
    lock="on"
    pid="$(state_pid 2>/dev/null || true)"
    port="$(read_state lockdown_port 2>/dev/null || true)"
    mark="$(read_state lockdown_mark 2>/dev/null || true)"
    phone_port="$(read_state lockdown_phone_port 2>/dev/null || true)"
    ipv6="$(read_state lockdown_ipv6 2>/dev/null || true)"
    lan="$(read_state lockdown_allow_lan 2>/dev/null || true)"
  fi

  emit lockdown "$lock"
  emit lockdown_helper "$helper"
  emit lockdown_gost_pid "$pid"
  emit lockdown_port "$port"
  emit lockdown_phone_port "$phone_port"
  emit lockdown_mark "$mark"
  emit lockdown_allow_lan "$lan"
  emit lockdown_ipv6 "$ipv6"
  emit lockdown_udp yes
}

case "${1:-status}" in
  enable) cmd_enable ;;
  disable) cmd_disable ;;
  cleanup) cmd_cleanup ;;
  status) cmd_status ;;
  install) exec "$HERE/install.sh" --privileged ;;
  *)
    echo "usage: $0 {enable|disable|cleanup|status|install}" >&2
    exit 2
    ;;
esac

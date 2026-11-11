#!/usr/bin/env bash
# Enable or disable a user-level system proxy for the phone tunnel.
#
# This does not create a VPN or change routes. It tells applications that honor
# the desktop's proxy settings (GNOME/GIO settings, and the Hyprland session
# environment for newly launched apps) to use the phone's SOCKS5 port.
#
# Commands:
#   proxy.sh status   print key=value state
#   proxy.sh enable   save the current settings, then turn the proxy on
#   proxy.sh disable  restore the saved settings
#   proxy.sh cleanup  disable only if the tunnel is no longer up
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

PORT="$ZCONNECT_PORT"
PROXY_HOST="127.0.0.1"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zconnect"
BACKUP="$STATE_DIR/proxy-backup.env"
MARKER="$STATE_DIR/proxy-active"
LOCK="$STATE_DIR/proxy.lock"

NO_PROXY_VALUE="localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local"
# Chromium reads the traditional http_proxy/https_proxy/all_proxy variables and
# treats them as HTTP proxies. Our relay is SOCKS5, so those variables must be
# empty while the system proxy is on. Chromium's own SOCKS variables are
# SOCKS_SERVER/SOCKS_VERSION, which every Chromium-based browser understands.
CLEAR_ENV_VARS=(http_proxy https_proxy all_proxy ftp_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY FTP_PROXY)
SET_ENV_VARS=(SOCKS_SERVER SOCKS_VERSION NO_PROXY no_proxy)
ENV_VARS=("${CLEAR_ENV_VARS[@]}" "${SET_ENV_VARS[@]}")

mkdir -p "$STATE_DIR" 2>/dev/null || true
chmod 700 "$STATE_DIR" 2>/dev/null || true

have_gsettings() {
  command -v gsettings >/dev/null 2>&1
}

gsettings_string() {
  local value
  value="$(gsettings get "$1" "$2" 2>/dev/null)" || return 1
  value="${value#\'}"
  value="${value%\'}"
  printf '%s' "$value"
}

gsettings_raw() {
  gsettings get "$1" "$2" 2>/dev/null
}

hypr_env_set() {
  local name="$1" value="$2" escaped
  command -v hyprctl >/dev/null 2>&1 || return 0
  [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || return 0
  escaped="${value//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  hyprctl eval "hl.env(\"$name\", \"$escaped\")" >/dev/null 2>&1 || true
}

systemd_env_set() {
  local name="$1" value="$2"
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl --user set-environment "$name=$value" >/dev/null 2>&1 || true
}

systemd_env_unset() {
  local name="$1"
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl --user unset-environment "$name" >/dev/null 2>&1 || true
}

dbus_env_set() {
  local name="$1" value="$2"
  command -v dbus-update-activation-environment >/dev/null 2>&1 || return 0
  dbus-update-activation-environment --systemd "$name=$value" >/dev/null 2>&1 || true
}

dbus_env_unset() {
  local name="$1"
  command -v dbus-update-activation-environment >/dev/null 2>&1 || return 0
  # An empty value is treated as unset by Chromium and most other clients.
  dbus-update-activation-environment --systemd "$name=" >/dev/null 2>&1 || true
}

env_value_or_unset() {
  local name="$1"
  if [[ -n "${!name+x}" ]]; then
    printf '%s' "${!name}"
  else
    printf '__UNSET__'
  fi
}

lock_state() {
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>"$LOCK" || return 1
  if ! flock -w 10 9; then
    echo "error: another system-proxy operation is already running." >&2
    return 1
  fi
}

save_state() {
  local mode="" host="" port="" ignore="" name tmp
  if have_gsettings; then
    mode="$(gsettings_string org.gnome.system.proxy mode)" || mode="none"
    host="$(gsettings_string org.gnome.system.proxy.socks host)" || host=""
    port="$(gsettings_string org.gnome.system.proxy.socks port)" || port="0"
    ignore="$(gsettings_raw org.gnome.system.proxy ignore-hosts)" || ignore="['localhost', '127.0.0.0/8', '::1']"
  fi

  tmp="$BACKUP.tmp.$$"
  {
    printf '# Z-Connect system-proxy backup. Restored by proxy.sh disable.\n'
    printf 'BACKUP_MODE=%q\n' "$mode"
    printf 'BACKUP_SOCKS_HOST=%q\n' "$host"
    printf 'BACKUP_SOCKS_PORT=%q\n' "$port"
    printf 'BACKUP_IGNORE_HOSTS=%q\n' "$ignore"
    for name in "${ENV_VARS[@]}"; do
      printf 'BACKUP_%s=%q\n' "$name" "$(env_value_or_unset "$name")"
    done
  } > "$tmp" || return 1
  mv "$tmp" "$BACKUP" || return 1
  : > "$MARKER"
}

merge_ignore_hosts() {
  local current="$1" item
  local additions=("10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "*.local")

  [[ "$current" == @as* ]] && current="[]"
  [[ "$current" == \[*\] ]] || current="[]"

  for item in "${additions[@]}"; do
    if [[ "$current" != *"'$item'"* ]]; then
      current="${current%]}"
      [[ "$current" == "[" ]] || current+=", "
      current+="'$item']"
    fi
  done
  printf '%s' "$current"
}

env_value_for() {
  case "$1" in
    NO_PROXY|no_proxy) printf '%s' "$NO_PROXY_VALUE" ;;
    SOCKS_SERVER) printf '%s:%s' "$PROXY_HOST" "$PORT" ;;
    SOCKS_VERSION) printf '5' ;;
    *) printf '' ;;
  esac
}

apply_settings() {
  local rc=0 name value current ignore

  if have_gsettings; then
    gsettings set org.gnome.system.proxy.socks host "$PROXY_HOST" || rc=1
    gsettings set org.gnome.system.proxy.socks port "$PORT" || rc=1

    current="$(gsettings_raw org.gnome.system.proxy ignore-hosts)" || current="['localhost', '127.0.0.0/8', '::1']"
    ignore="$(merge_ignore_hosts "$current")"
    gsettings set org.gnome.system.proxy ignore-hosts "$ignore" || rc=1

    # Set manual mode last: if anything above failed, we have not cut over yet.
    gsettings set org.gnome.system.proxy mode 'manual' || rc=1
  fi

  for name in "${ENV_VARS[@]}"; do
    value="$(env_value_for "$name")"
    export "$name=$value"
    hypr_env_set "$name" "$value"
    systemd_env_set "$name" "$value"
    dbus_env_set "$name" "$value"
  done

  return "$rc"
}

restore_settings() {
  local name value var

  if [[ -f "$BACKUP" ]]; then
    # shellcheck disable=SC1090
    source "$BACKUP" || true

    if have_gsettings; then
      gsettings set org.gnome.system.proxy.socks host "${BACKUP_SOCKS_HOST:-}" >/dev/null 2>&1 || true
      gsettings set org.gnome.system.proxy.socks port "${BACKUP_SOCKS_PORT:-0}" >/dev/null 2>&1 || true
      gsettings set org.gnome.system.proxy ignore-hosts "${BACKUP_IGNORE_HOSTS:-['localhost', '127.0.0.0/8', '::1']}" >/dev/null 2>&1 || true
      if ! gsettings set org.gnome.system.proxy mode "${BACKUP_MODE:-none}" >/dev/null 2>&1; then
        # Never leave a broken manual proxy behind if the saved mode is invalid.
        gsettings set org.gnome.system.proxy mode 'none' >/dev/null 2>&1 || true
      fi
    fi

    for name in "${ENV_VARS[@]}"; do
      var="BACKUP_${name}"
      value="${!var:-__UNSET__}"
      if [[ "$value" == "__UNSET__" ]]; then
        unset "$name"
        hypr_env_set "$name" ""
        systemd_env_unset "$name"
        dbus_env_unset "$name"
      else
        export "$name=$value"
        hypr_env_set "$name" "$value"
        systemd_env_set "$name" "$value"
        dbus_env_set "$name" "$value"
      fi
    done

    rm -f "$BACKUP" "$MARKER"
    return 0
  fi

  # No backup file: only clear settings that still point at our own endpoint.
  if have_gsettings; then
    local mode host port
    mode="$(gsettings_string org.gnome.system.proxy mode)" || mode=""
    host="$(gsettings_string org.gnome.system.proxy.socks host)" || host=""
    port="$(gsettings_string org.gnome.system.proxy.socks port)" || port=""
    if [[ "$mode" == "manual" && "$host" == "$PROXY_HOST" && "$port" == "$PORT" ]]; then
      gsettings set org.gnome.system.proxy mode 'none' >/dev/null 2>&1 || true
      gsettings set org.gnome.system.proxy.socks host '' >/dev/null 2>&1 || true
      gsettings set org.gnome.system.proxy.socks port 0 >/dev/null 2>&1 || true
    fi
  fi

  if [[ "${SOCKS_SERVER:-}" == "$PROXY_HOST:$PORT" ]]; then
    for name in "${ENV_VARS[@]}"; do
      unset "$name"
      hypr_env_set "$name" ""
      systemd_env_unset "$name"
      dbus_env_unset "$name"
    done
  fi
}

tunnel_up() {
  local output forward gost
  output="$("$HERE/status.sh" --quick 2>/dev/null || true)"
  forward="$(printf '%s\n' "$output" | awk -F= '$1 == "forward" { print $2; exit }')"
  gost="$(printf '%s\n' "$output" | awk -F= '$1 == "gost_pid" { print $2; exit }')"
  [[ "$forward" == "yes" && -n "$gost" ]]
}

cmd_status() {
  local mode="" host="" port="" on="off" managed="no" error=""

  if have_gsettings; then
    mode="$(gsettings_string org.gnome.system.proxy mode)" || { mode=""; error="could not read gsettings"; }
    host="$(gsettings_string org.gnome.system.proxy.socks host)" || host=""
    port="$(gsettings_string org.gnome.system.proxy.socks port)" || port=""
  else
    error="gsettings is not installed"
  fi

  [[ -f "$BACKUP" ]] && managed="yes"
  if [[ "$mode" == "manual" && "$host" == "$PROXY_HOST" && "$port" == "$PORT" ]]; then
    on="on"
  fi
  # If the environment was applied but gsettings is unavailable, the backup is
  # still the authoritative "we turned it on" marker.
  [[ "$managed" == "yes" ]] && on="on"

  printf 'system_proxy=%s\n' "$on"
  printf 'system_proxy_managed=%s\n' "$managed"
  printf 'system_proxy_mode=%s\n' "$mode"
  printf 'system_proxy_socks=%s:%s\n' "$host" "$port"
  printf 'system_proxy_error=%s\n' "$error"
}

cmd_enable() {
  lock_state || return 1

  if ! curl -fsS --socks5-hostname "$PROXY_HOST:$PORT" --max-time 8 https://api.ipify.org >/dev/null 2>&1; then
    echo "error: the phone tunnel is not working. Connect the phone first." >&2
    return 1
  fi

  if [[ ! -f "$BACKUP" ]]; then
    save_state || {
      echo "error: could not save the current proxy settings." >&2
      return 1
    }
  fi

  if ! apply_settings; then
    echo "error: could not apply the system proxy settings." >&2
    restore_settings >/dev/null 2>&1 || true
    return 1
  fi

  echo "System proxy enabled: SOCKS5 ${PROXY_HOST}:${PORT}"
  echo "Restart apps that were already open so they pick up the proxy."
}

cmd_disable() {
  lock_state || return 1

  if [[ -f "$BACKUP" ]]; then
    restore_settings
    echo "System proxy disabled; previous proxy settings restored."
  else
    restore_settings >/dev/null 2>&1 || true
    echo "System proxy is already off."
  fi
}

cmd_cleanup() {
  if [[ ! -f "$BACKUP" ]]; then
    echo "System proxy is off."
    return 0
  fi
  if tunnel_up; then
    echo "System proxy is on and the tunnel is up."
    return 0
  fi
  cmd_disable
}

case "${1:-status}" in
  status) cmd_status ;;
  enable) cmd_enable ;;
  disable) cmd_disable ;;
  cleanup) cmd_cleanup ;;
  *)
    echo "usage: $0 {status|enable|disable|cleanup}" >&2
    exit 2
    ;;
esac

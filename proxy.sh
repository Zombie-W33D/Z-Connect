#!/usr/bin/env bash
# Enable or disable the system proxy for the phone tunnel.
#
# This does not create a VPN or change routes. It tells applications that honor
# the desktop's proxy settings (GNOME/GIO settings, the systemd user environment,
# and the Hyprland session environment) to use the stable local relay, which
# forwards to the phone or falls back to the normal network.
#
# The proxy is designed to stay on across phone connects and disconnects. It can
# also be enabled at login by a systemd user service, so apps are proxied from
# the first moment the desktop starts.
#
# Commands:
#   proxy.sh status          print key=value state
#   proxy.sh enable          apply the proxy and enable it at login
#   proxy.sh enable --no-boot
#                            apply now, but do not enable it at login
#   proxy.sh disable         restore the saved settings and turn login proxying off
#   proxy.sh cleanup         keep the proxy on; switch the relay to direct when
#                            the phone tunnel is down
#   proxy.sh boot on|off     control login proxying explicitly
#   proxy.sh boot-run        internal: used by zconnect-proxy.service
#   proxy.sh boot-stop       internal: used by zconnect-proxy.service
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

PORT="$ZCONNECT_PORT"
PHONE_PORT="$ZCONNECT_PHONE_PORT"
RELAY="$HERE/relay.sh"
PROXY_HOST="127.0.0.1"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/zconnect"
BACKUP="$STATE_DIR/proxy-backup.env"
MARKER="$STATE_DIR/proxy-active"
LOCK="$STATE_DIR/proxy.lock"
ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/90-zconnect.conf"
RELAY_UNIT="$ZCONNECT_USER_UNIT_DIR/zconnect-relay.service"
PROXY_UNIT="$ZCONNECT_USER_UNIT_DIR/zconnect-proxy.service"

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

save_state_once() {
  [[ -f "$BACKUP" ]] && return 0
  save_state
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

write_env_file() {
  local dir
  dir="$(dirname "$ENV_FILE")"
  mkdir -p "$dir" 2>/dev/null || return 1
  {
    printf '# Managed by Z-Connect. Remove with: proxy.sh disable\n'
    printf 'SOCKS_SERVER=%s:%s\n' "$PROXY_HOST" "$PORT"
    printf 'SOCKS_VERSION=5\n'
    printf 'NO_PROXY=%s\n' "$NO_PROXY_VALUE"
    # Empty values keep Chromium from treating these as HTTP proxies.
    printf 'http_proxy=\n'
    printf 'https_proxy=\n'
    printf 'all_proxy=\n'
    printf 'ftp_proxy=\n'
    printf 'HTTP_PROXY=\n'
    printf 'HTTPS_PROXY=\n'
    printf 'ALL_PROXY=\n'
    printf 'FTP_PROXY=\n'
  } > "$ENV_FILE" || return 1
}

remove_env_file() {
  rm -f "$ENV_FILE" 2>/dev/null || true
}

unit_enabled() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user is-enabled --quiet "$1" 2>/dev/null
}

unit_active() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user is-active --quiet "$1" 2>/dev/null
}

boot_enabled() {
  [[ -f "$ENV_FILE" ]] || return 1
  unit_enabled zconnect-proxy.service || return 1
  unit_enabled zconnect-relay.service || return 1
}

boot_enable() {
  if ! zconnect_install_user_units; then
    echo "error: could not install the systemd user units." >&2
    return 1
  fi
  write_env_file || {
    echo "error: could not write $ENV_FILE." >&2
    return 1
  }
  if ! systemctl --user enable zconnect-relay.service zconnect-proxy.service >/dev/null 2>&1; then
    echo "error: could not enable the systemd user units." >&2
    return 1
  fi
  systemctl --user start zconnect-relay.service >/dev/null 2>&1 || true
  # Starting the proxy unit applies the same settings again. boot-run does not
  # take the proxy lock, so this cannot deadlock against cmd_enable.
  systemctl --user start zconnect-proxy.service >/dev/null 2>&1 || true
  return 0
}

boot_disable() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now zconnect-proxy.service >/dev/null 2>&1 || true
    systemctl --user disable zconnect-relay.service >/dev/null 2>&1 || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  remove_env_file
}

ensure_relay_and_mode() {
  if [[ ! -x "$RELAY" ]]; then
    echo "error: relay.sh not found. Reinstall the scripts." >&2
    return 1
  fi
  if ! "$RELAY" ensure; then
    echo "error: could not start the stable local relay." >&2
    return 1
  fi
  if zconnect_tunnel_up; then
    "$RELAY" mode phone >/dev/null || return 1
  else
    "$RELAY" mode direct >/dev/null || return 1
  fi
  return 0
}

cmd_status() {
  local mode="" host="" port="" on="off" managed="no" error=""
  local boot="off" env_file="no" service="inactive" enabled="no"

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

  [[ -f "$ENV_FILE" ]] && env_file="yes"
  unit_active zconnect-proxy.service && service="active"
  unit_enabled zconnect-proxy.service && enabled="yes"
  if [[ "$env_file" == "yes" && "$enabled" == "yes" ]] && unit_enabled zconnect-relay.service; then
    boot="on"
  fi

  printf 'system_proxy=%s\n' "$on"
  printf 'system_proxy_managed=%s\n' "$managed"
  printf 'system_proxy_mode=%s\n' "$mode"
  printf 'system_proxy_socks=%s:%s\n' "$host" "$port"
  printf 'system_proxy_error=%s\n' "$error"
  printf 'system_proxy_boot=%s\n' "$boot"
  printf 'system_proxy_env_file=%s\n' "$env_file"
  printf 'system_proxy_service=%s\n' "$service"
}

cmd_enable() {
  local boot=1
  [[ "${1:-}" == "--no-boot" ]] && boot=0

  lock_state || return 1

  ensure_relay_and_mode || return 1

  if ! save_state_once; then
    echo "error: could not save the current proxy settings." >&2
    return 1
  fi

  if ! apply_settings; then
    echo "error: could not apply the system proxy settings." >&2
    restore_settings >/dev/null 2>&1 || true
    "$RELAY" mode direct >/dev/null 2>&1 || true
    return 1
  fi

  if [[ "$boot" == "1" ]]; then
    if ! boot_enable; then
      echo "warning: the proxy is on now, but it could not be enabled at login." >&2
    fi
  fi

  echo "System proxy enabled: SOCKS5 ${PROXY_HOST}:${PORT} (stable relay)"
  echo "Open apps already using the relay switch routes automatically."
  if [[ "$boot" == "1" ]]; then
    echo "It will also start automatically at login."
  fi
}

cmd_disable() {
  lock_state || return 1

  boot_disable

  # Keep the relay alive in direct mode so apps that were already pointed at it
  # continue working through the normal network instead of a dead phone proxy.
  if [[ -x "$RELAY" ]]; then
    "$RELAY" ensure >/dev/null 2>&1 || true
    "$RELAY" mode direct >/dev/null 2>&1 || true
  fi

  if [[ -f "$BACKUP" ]]; then
    restore_settings
    echo "System proxy disabled; previous proxy settings restored."
    echo "Relay is in direct mode; open apps using it now use the normal network."
  else
    restore_settings >/dev/null 2>&1 || true
    echo "System proxy is already off."
  fi
}

cmd_cleanup() {
  local up=0
  if zconnect_tunnel_up; then
    up=1
  fi

  if [[ "$up" == "0" ]]; then
    [[ -x "$RELAY" ]] && "$RELAY" mode direct >/dev/null 2>&1 || true
    # Mandatory routing must not strand the desktop after the cable is pulled.
    # lockdown.sh cleanup only disables it when the phone tunnel is down.
    if [[ -x "$HERE/lockdown.sh" ]]; then
      "$HERE/lockdown.sh" cleanup >/dev/null 2>&1 || true
    fi
  fi

  if [[ ! -f "$BACKUP" ]]; then
    echo "System proxy is off."
    return 0
  fi
  if [[ "$up" == "1" ]]; then
    echo "System proxy is on and the tunnel is up."
    return 0
  fi
  echo "System proxy stays on; the relay is using the normal network."
  echo "Run proxy.sh disable to restore the previous proxy settings."
}

cmd_boot() {
  case "${1:-status}" in
    on)
      # Reuse the normal enable path so the current session is applied too.
      cmd_enable
      ;;
    off)
      cmd_disable
      ;;
    run)
      # Executed by zconnect-proxy.service. No proxy lock: cmd_enable may be
      # waiting for this service while holding it.
      ensure_relay_and_mode || return 1
      save_state_once || return 1
      if ! apply_settings; then
        echo "warning: could not apply every system proxy setting." >&2
      fi
      write_env_file || true
      return 0
      ;;
    stop)
      restore_settings || true
      return 0
      ;;
    status)
      cmd_status
      ;;
    *)
      echo "usage: $0 boot {on|off|run|stop|status}" >&2
      return 2
      ;;
  esac
}

case "${1:-status}" in
  status) cmd_status ;;
  enable) shift; cmd_enable "${1:-}" ;;
  disable) cmd_disable ;;
  cleanup) cmd_cleanup ;;
  boot) shift; cmd_boot "${1:-status}" ;;
  boot-run) cmd_boot run ;;
  boot-stop) cmd_boot stop ;;
  *)
    echo "usage: $0 {status|enable [--no-boot]|disable|cleanup|boot on|boot off|boot-run|boot-stop}" >&2
    exit 2
    ;;
esac

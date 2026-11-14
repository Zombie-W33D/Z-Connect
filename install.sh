#!/usr/bin/env bash
# Install the Phone Tether runtime in place (this directory).
#
#   ./install.sh                  install the user-facing files
#   ./install.sh --enable         also enable the Omarchy bar widget
#   ./install.sh --privileged     install the root-owned mandatory-routing helper
#   ./install.sh --enable --privileged
#
# --privileged is the only step that needs root. It installs:
#
#   /usr/local/libexec/zconnect-lockdown   the helper
#   /usr/local/libexec/zconnect-gost       desktop gost used for the TUN
#   /etc/zconnect/lockdown.conf            fixed, root-owned configuration
#   /etc/sudoers.d/zconnect-lockdown       allow only apply/cleanup/status
#
# The user-facing scripts never need a general sudo rule.
#
# Override the install location with ZCONNECT_DIR.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The local runtime lives in this directory. Use it in place instead of making
# a second copy under ~/.local/share.
DEST="${ZCONNECT_DIR:-$SRC}"
DEST_EXPLICIT=0
[[ -n "${ZCONNECT_DIR:-}" ]] && DEST_EXPLICIT=1
PLUGIN_ID="zombie.phone-tether"
PLUGIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID"
HELPER="/usr/local/libexec/zconnect-lockdown"
HELPER_GOST="/usr/local/libexec/zconnect-gost"
CONF_DIR="/etc/zconnect"
CONF="$CONF_DIR/lockdown.conf"
SUDOERS="/etc/sudoers.d/zconnect-lockdown"
ENABLE=0
PRIVILEGED=0
ROOT_ONLY=0
PHONE_PORT_ARG=""

for arg in "$@"; do
  case "$arg" in
    --enable) ENABLE=1 ;;
    --privileged) PRIVILEGED=1 ;;
    # Internal: used by the sudo re-exec so the user files are not rewritten as
    # root. Not part of the public interface.
    --privileged-only) PRIVILEGED=1; ROOT_ONLY=1 ;;
    # Internal: the install directory and phone port are passed explicitly to
    # the sudo re-exec because sudo may reset HOME and the environment.
    --dest=*) DEST="${arg#--dest=}"; DEST_EXPLICIT=1 ;;
    --phone-port=*) PHONE_PORT_ARG="${arg#--phone-port=}" ;;
    -h|--help)
      echo "usage: $0 [--enable] [--privileged]"
      exit 0
      ;;
    *)
      echo "error: unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

# When --privileged is run through sudo directly, sudo's HOME may point at
# /root. Find the desktop user's install unless the caller named a directory.
if [[ "${EUID:-$(id -u)}" -eq 0 && "$DEST_EXPLICIT" == "0" && -n "${SUDO_USER:-}" ]]; then
  user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
  if [[ -n "$user_home" ]]; then
    DEST="$user_home/.local/share/z-connect"
  fi
fi

# `sudo ./install.sh --privileged` should use the directory the script lives in
# when the inferred install has no runtime files.
if [[ "${EUID:-$(id -u)}" -eq 0 && "$PRIVILEGED" == "1" && \
      "$DEST_EXPLICIT" == "0" && \
      ! -f "$DEST/privileged/zconnect-lockdown" && \
      -f "$SRC/privileged/zconnect-lockdown" ]]; then
  DEST="$SRC"
fi

if [[ "${EUID:-$(id -u)}" -eq 0 && "$PRIVILEGED" == "1" ]]; then
  ROOT_ONLY=1
fi

# ------------------------------------------------------------- privileged part
privileged_install() {
  local user="${SUDO_USER:-${USER:-$(id -un)}}"
  local gost_src="$DEST/bin/gost-desktop"
  local conf_tmp sudoers_tmp

  [[ "${EUID:-$(id -u)}" -eq 0 ]] || {
    echo "error: --privileged must run as root (use sudo)." >&2
    exit 1
  }

  if [[ ! -f "$DEST/privileged/zconnect-lockdown" ]]; then
    echo "error: privileged/zconnect-lockdown is missing from $DEST." >&2
    if [[ -f "$SRC/privileged/zconnect-lockdown" ]]; then
      echo "It is present in $SRC. Run that copy instead:" >&2
      echo "  \"$SRC/install.sh\" --privileged" >&2
    fi
    exit 1
  fi

  if [[ ! -x "$gost_src" ]]; then
    echo "error: $gost_src is missing." >&2
    echo "Run ./fetch-deps.sh first so the desktop gost binary is available." >&2
    exit 1
  fi

  command -v ip >/dev/null 2>&1 || {
    echo "error: the ip command is required for mandatory routing." >&2
    exit 1
  }
  if [[ "${ZCONNECT_BLOCK_IPV6:-1}" == "1" ]]; then
    command -v ip6tables >/dev/null 2>&1 || {
      echo "error: ip6tables is required while IPv6 blocking is enabled." >&2
      echo "Install ip6tables, or set ZCONNECT_BLOCK_IPV6=0 to opt out." >&2
      exit 1
    }
  fi
  command -v visudo >/dev/null 2>&1 || {
    echo "error: visudo is required to validate the sudoers entry." >&2
    exit 1
  }

  # shellcheck source=/dev/null
  source "$DEST/lib.sh"
  # Keep the privileged helper on the same phone port as the user scripts even
  # when the sudo re-exec did not preserve the environment.
  if [[ -n "$PHONE_PORT_ARG" ]]; then
    ZCONNECT_PHONE_PORT="$PHONE_PORT_ARG"
  fi

  echo "Installing the mandatory-routing helper..."
  install -D -m 0755 -o root -g root "$DEST/privileged/zconnect-lockdown" "$HELPER"
  install -D -m 0755 -o root -g root "$gost_src" "$HELPER_GOST"

  install -d -m 0755 -o root -g root "$CONF_DIR"
  conf_tmp="$(mktemp)"
  {
    printf '# Z-Connect mandatory-routing configuration. Root-owned.\n'
    printf '# Generated by install.sh --privileged. Edit only if you know why.\n'
    printf 'ZCONNECT_PHONE_PORT=%s\n' "$ZCONNECT_PHONE_PORT"
    printf 'ZCONNECT_TUN_NAME=%s\n' "${ZCONNECT_TUN_NAME:-zconnect0}"
    printf 'ZCONNECT_TUN_NET=%s\n' "${ZCONNECT_TUN_NET:-198.18.0.1/15}"
    printf 'ZCONNECT_TUN_MTU=%s\n' "${ZCONNECT_TUN_MTU:-1400}"
    printf 'ZCONNECT_TUN_TABLE=%s\n' "${ZCONNECT_TUN_TABLE:-9010}"
    printf 'ZCONNECT_TUN_DNS=%s\n' "${ZCONNECT_TUN_DNS:-1.1.1.1,1.0.0.1}"
    printf 'ZCONNECT_GOST=%s\n' "$HELPER_GOST"
    printf 'ZCONNECT_RUN_DIR=%s\n' "${ZCONNECT_RUN_DIR:-/run/zconnect}"
    printf 'ZCONNECT_ALLOW_LAN=%s\n' "${ZCONNECT_ALLOW_LAN:-1}"
    printf 'ZCONNECT_BLOCK_IPV6=%s\n' "${ZCONNECT_BLOCK_IPV6:-1}"
  } > "$conf_tmp"
  install -m 0644 -o root -g root "$conf_tmp" "$CONF"
  rm -f "$conf_tmp"

  sudoers_tmp="$(mktemp)"
  {
    printf '# Z-Connect mandatory routing. Installed by install.sh --privileged.\n'
    printf '%s ALL=(root) NOPASSWD: %s apply, %s cleanup, %s status\n' \
      "$user" "$HELPER" "$HELPER" "$HELPER"
  } > "$sudoers_tmp"
  if ! visudo -cf "$sudoers_tmp" >/dev/null 2>&1; then
    rm -f "$sudoers_tmp"
    echo "error: the generated sudoers entry is invalid; nothing was changed." >&2
    exit 1
  fi
  install -m 0440 -o root -g root "$sudoers_tmp" "$SUDOERS"
  rm -f "$sudoers_tmp"

  echo "Installed $HELPER"
  echo "Installed $HELPER_GOST"
  echo "Installed $CONF"
  echo "Installed $SUDOERS"
  echo
  echo "Mandatory routing is ready. Enable it with:"
  echo "  $DEST/lockdown.sh enable"
}

if [[ "$ROOT_ONLY" == "1" ]]; then
  privileged_install
  exit 0
fi

# ------------------------------------------------------------------ user files
echo "Installing Z-Connect to $DEST"
mkdir -p "$DEST"

if [[ "$SRC" != "$DEST" ]]; then
  # Copy the runtime files. bin binaries are copied when present; otherwise
  # fetch-deps.sh downloads them after installation.
  cp -a "$SRC"/connect.sh "$SRC"/disconnect.sh "$SRC"/status.sh \
        "$SRC"/proxy.sh "$SRC"/relay.sh "$SRC"/relay.py \
        "$SRC"/lockdown.sh "$SRC"/env.sh "$SRC"/lib.sh \
        "$SRC"/fetch-deps.sh \
        "$SRC"/chromium-zconnect.sh "$SRC"/brave-zconnect.sh \
        "$SRC"/README.md "$DEST"/
  if [[ -f "$SRC/LICENSE" ]]; then
    cp -a "$SRC/LICENSE" "$DEST"/
  fi
  mkdir -p "$DEST/docs" "$DEST/bin" "$DEST/omarchy" "$DEST/privileged"
  cp -a "$SRC"/docs/. "$DEST/docs"/
  cp -a "$SRC"/bin/. "$DEST/bin"/
  cp -a "$SRC"/omarchy/. "$DEST/omarchy"/
  cp -a "$SRC"/privileged/. "$DEST/privileged"/
fi

chmod +x "$DEST"/*.sh "$DEST"/relay.py
chmod +x "$DEST"/privileged/zconnect-lockdown 2>/dev/null || true

# Write (but do not enable) the systemd user units. proxy.sh boot on enables
# them, and connect.sh turns the boot proxy on automatically.
# shellcheck source=/dev/null
source "$DEST/lib.sh"
zconnect_install_user_units >/dev/null 2>&1 || \
  echo "warning: could not install the systemd user units." >&2

if [[ "$PRIVILEGED" == "1" ]]; then
  echo
  echo "Root is required for --privileged; re-running that part with sudo..."
  sudo bash "$DEST/install.sh" --privileged-only \
    --dest="$DEST" --phone-port="$ZCONNECT_PHONE_PORT"
fi

# ------------------------------------------------------------------ bar widget
if [[ -d "$DEST/omarchy/$PLUGIN_ID" ]]; then
  echo "Installing the Omarchy widget to $PLUGIN_DIR"
  mkdir -p "$PLUGIN_DIR"
  cp -a "$DEST"/omarchy/"$PLUGIN_ID"/. "$PLUGIN_DIR"/
else
  echo "warning: widget files are not present in $DEST/omarchy/$PLUGIN_ID; skipping the widget." >&2
fi

if [[ -x "$DEST/bin/adb" && -x "$DEST/bin/gost" && -x "$DEST/bin/gost-desktop" ]]; then
  echo "Bundled adb and gost binaries are present."
else
  echo
  echo "Some binaries are not installed yet. Run:"
  echo "  cd \"$DEST\" && ./fetch-deps.sh"
fi

if [[ "$ENABLE" == "1" && -d "$DEST/omarchy/$PLUGIN_ID" ]]; then
  if command -v omarchy >/dev/null 2>&1; then
    echo
    echo "Enabling the widget..."
    omarchy plugin enable "$PLUGIN_ID" --section right || true
    omarchy bar move "$PLUGIN_ID" --after omarchy.network || true
  else
    echo "warning: the omarchy command was not found; enable the widget from the shell settings." >&2
  fi
elif [[ "$ENABLE" == "1" ]]; then
  echo "warning: --enable was requested, but the widget files are missing." >&2
else
  echo
  echo "To enable the widget:"
  echo "  omarchy plugin enable $PLUGIN_ID --section right"
  echo "  omarchy bar move $PLUGIN_ID --after omarchy.network"
fi

echo
echo "Done. Start the tunnel with:"
echo "  cd \"$DEST\" && ./connect.sh"
echo
echo "The system proxy is turned on automatically by connect.sh and can stay on"
echo "across phone disconnects. To keep it on from login, run:"
echo "  \"$DEST/proxy.sh\" boot on"
echo
if [[ "$PRIVILEGED" != "1" ]]; then
  echo "To let apps that ignore proxies route through the phone too, install the"
  echo "optional privileged helper once:"
  echo "  sudo \"$DEST/install.sh\" --privileged"
fi

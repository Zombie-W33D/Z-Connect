# Z-Connect

**USB phone tethering for Linux without Android's hotspot stack.**

Z-Connect turns an Android phone connected by USB into a SOCKS5 internet
gateway for a Linux desktop. It is PdaNet-style in spirit: traffic is relayed by
an ordinary user-space process on the phone instead of Android's
tethering/RNDIS path. No root is required on either side, and the desktop does
not need any internet of its own to bring the tunnel up.

TCP **and UDP** are supported. UDP uses gost's UDP-over-TCP extension so it can
cross the adb forward, which means games and other UDP-dependent apps work too.

The system proxy can start at login, and an optional privileged helper adds
**mandatory system-wide routing** for apps that ignore proxy settings.

It also includes an optional **Omarchy bar widget** with a phone icon, a
Connect/Disconnect panel, and live connection details.

```
Desktop app
    │  SOCKS5  127.0.0.1:1080  (stable local relay, TCP + UDP)
    ▼
relay.py on the desktop ──► phone mode: 127.0.0.1:1081
    │                       direct mode: normal network
    ▼
adb forward over the USB cable
    ▼
gost running on the phone (ordinary shell process)
    │  normal TCP/UDP sockets
    ▼
phone mobile data ──► internet
```

The relay is the key to live switching. Apps point at one fixed local endpoint,
`127.0.0.1:1080`. The relay decides per new connection whether to send it
through the phone or the normal network. Disconnecting the phone flips the relay
to direct mode, so apps that were already open keep working instead of holding a
dead proxy. Reconnecting flips it back to the phone.

> **Status:** working reference implementation. Linux desktop + Android phone
> over USB/ADB. Tested with an ARM64 Android phone and an Omarchy/Quickshell
> desktop. Not affiliated with PdaNet.

---

## Features

- **No root.** The phone side runs as the normal `shell` user in
  `/data/local/tmp`.
- **No local internet needed.** The desktop only needs the USB cable; all DNS
  and traffic goes through the phone.
- **No Android tethering service.** The relay is a normal app/shell process, so
  Android's hotspot/tethering entitlement path is not involved.
- **SOCKS5, not a proprietary tunnel.** Any Linux app that understands a SOCKS
  proxy can use it. TCP and UDP are both carried; UDP uses gost's UDP-over-TCP
  extension, so it works through the adb forward.
- **Live route switching.** A small user-level relay owns `127.0.0.1:1080`.
  Apps keep one proxy setting while the relay switches between the phone and the
  normal network. Already-open apps reroute on their next connection; only apps
  that were direct before the first Connect need one restart.
- **Automatic fallback.** If the phone disappears while the relay is in phone
  mode, new connections fall back to the normal network instead of failing.
- **DNS resolved on the phone.** `socks5h` keeps hostname resolution on the
  phone, so the desktop needs no working DNS.
- **User-level system proxy.** Connect can point GNOME/GIO apps and newly
  launched Hyprland apps at the stable relay, with no root. It can start at
  login, stays on across phone disconnects, and falls back to direct mode.
- **Optional mandatory routing.** A one-time privileged install adds transparent
  TCP + UDP capture with TPROXY, so apps that ignore proxy settings still use
  the phone. No app can silently bypass the tunnel while it is enabled.
- **One-command setup and teardown.** `connect.sh`, `disconnect.sh`, and a
  machine-readable `status.sh`.
- **Omarchy bar widget.** Phone icon, green/amber state dot, Connect and
  Disconnect buttons, system-proxy and mandatory-routing toggles, and live
  details.
- **No secrets in this repository.** No device identifiers, phone numbers, IP
  addresses, carrier names, hostnames, or user paths are committed. Runtime
  values are read from the attached phone.

---

## How it works

### 1. The desktop relay listens locally

`connect.sh` starts a small Python relay on `127.0.0.1:1080`. That is the stable
endpoint apps use. The relay forwards new connections to either the phone or the
normal network, depending on a mode file:

```text
app ──► 127.0.0.1:1080 (relay.py)
             ├── phone mode  ──► 127.0.0.1:1081 ──USB──► phone 127.0.0.1:1081
             └── direct mode ──► normal desktop network
```

`connect.sh` also creates an `adb` port forward for the phone-side port:

```text
desktop 127.0.0.1:1081  ──USB──►  phone 127.0.0.1:1081
```

Only the desktop's loopback interface is used. Nothing is exposed on Wi-Fi,
ethernet, or the internet.

### 2. The phone runs a SOCKS5 proxy

The script pushes a static `gost` binary to `/data/local/tmp/zconnect-gost` and
starts it as an ordinary process:

```text
gost -L 'socks5://127.0.0.1:1081?resolver=<phone-dns>,8.8.8.8:53,1.1.1.1:53'
```

`gost` accepts SOCKS5 connections from the forwarded port and opens normal
outbound TCP connections using the phone's mobile data.

### 3. DNS happens on the phone

The resolver list is passed explicitly because Android's Go resolver does not
always use the mobile network's DNS servers. Z-Connect reads the phone's current
IPv4 DNS servers from `dumpsys connectivity` and adds public resolvers as
fallbacks. You can override the whole list with `ZCONNECT_DNS`.

Because clients use `socks5h://` (or `--socks5-hostname`), hostnames are sent to
the phone and resolved there. The desktop does not need working DNS.

### 4. Why the tethering check is not involved

Android's normal USB/Wi-Fi tethering path creates a `dun` APN or an RNDIS
interface and asks the carrier/entitlement service whether tethering is allowed.
Z-Connect never creates that path. The traffic is generated by a user-space
process on the phone, exactly like a browser or chat app using mobile data.

This is a technical property, not a promise about your carrier's terms. See
[Legal and fair use](#legal-and-fair-use).

### 5. Optional user-level system proxy

SOCKS5 is only useful to apps that know to use it. `proxy.sh` adds a per-user
system proxy so ordinary desktop apps can use the tunnel without per-app setup:

- GNOME/GIO apps read the `org.gnome.system.proxy` `gsettings` values.
- Newly launched apps inherit `SOCKS_SERVER`, `SOCKS_VERSION`, and `NO_PROXY`
  from the Hyprland session environment (plus the systemd/D-Bus activation
  environment and `~/.config/environment.d/90-zconnect.conf`).
- Chromium-based browsers (Chrome, Chromium, Brave, Electron apps) read
  `SOCKS_SERVER` and `SOCKS_VERSION`.

Chromium treats the traditional `http_proxy`, `https_proxy`, and `all_proxy`
variables as **HTTP** proxies. Our relay is SOCKS5, so `proxy.sh` clears those
variables while the system proxy is on. That is deliberate: setting them breaks
Brave/Chromium. Use `env.sh` or `curl --socks5-hostname` for terminal tools that
need the traditional variables.

`connect.sh` enables the system proxy automatically after a successful tunnel
test, and enables it at login too. The proxy can stay on permanently: it points
at the stable relay, which switches to direct mode when the phone is gone.

`proxy.sh cleanup` is what runs after a cable pull. It keeps the proxy on and
switches the relay to direct mode, so open apps keep working through the normal
network. Only an explicit `proxy.sh disable` restores the previous proxy
settings.

Because the system proxy points at the stable relay, apps that already use the
relay switch routes without a restart. Apps that were launched before the first
Connect and were using a direct connection need one restart to pick up the
proxy; after that they stay pointed at the relay across phone connects and
disconnects.

This is a user-level proxy, not a VPN. It does not change routes and does not
capture apps that ignore both `gsettings` and the Chromium SOCKS variables. Use
mandatory routing for those.

### 6. Optional mandatory routing (TPROXY)

The system proxy is cooperative: an app can ignore it and keep using the normal
network. Mandatory routing closes that gap.

`install.sh --privileged` installs a root-owned helper once. After that,
`lockdown.sh enable` (or the panel toggle, or `connect.sh` automatically) starts
a root-owned gost process as a transparent TCP and UDP proxy and installs:

- an `iptables` mangle chain that marks all local TCP/UDP output,
- a policy route that sends marked packets to a local TPROXY listener,
- a `DIVERT` rule so established transparent sockets keep working,
- LAN, loopback, link-local, and multicast exclusions,
- a final drop for protocols the SOCKS tunnel cannot carry,
- an IPv6 block, because the tunnel itself is IPv4.

While mandatory routing is on, every app on the desktop uses the phone,
including games, daemons, and apps with their own network stack. There is no
per-app bypass. This mode needs root; there is no rootless way to capture the
whole desktop.

LAN destinations are excluded by default so printers, routers, and local
servers keep working. To force even LAN traffic through the phone, set
`ZCONNECT_ALLOW_LAN=0` before `install.sh --privileged` (or edit
`/etc/zconnect/lockdown.conf` and re-run `lockdown.sh enable`).

The helper is the only command allowed through a restricted sudoers entry:

```text
/usr/local/libexec/zconnect-lockdown apply|cleanup|status
```

All ports, marks, and paths come from a root-owned
`/etc/zconnect/lockdown.conf`, never from the caller.

If you use Tailscale, WireGuard, Docker, or another overlay, review
[Limitations](#limitations): mandatory routing deliberately captures their
traffic too, and IPv6 is blocked.

---

## Requirements

### Desktop

- Linux (x86_64 for the bundled `adb`; another architecture can use a system
  `adb`).
- `curl`.
- `unzip` or `python3` (only for `fetch-deps.sh`).
- `python3` for the relay.
- Optional: GNOME/GIO `gsettings` and a Hyprland session for the user-level
  system proxy.
- Optional: systemd user services for boot-time proxying.
- Optional: `iptables`, `ip`, and root for mandatory routing.
- Optional: Omarchy with the Quickshell-based shell, for the bar widget.

### Phone

- Android phone with **USB debugging** enabled and authorized.
- ARM64 userspace for the default gost binary (almost all modern phones). See
  [`bin/README.md`](bin/README.md) for other ABIs.
- Mobile data enabled.
- USB cable that supports data (not a charge-only cable).

### Not required

- Root for the normal SOCKS5 tunnel or the user-level system proxy.
- A hotspot/tethering add-on.
- Wi-Fi on the desktop.
- Any desktop internet connection.

Root is only required for the optional mandatory-routing helper.

---

## Install

```bash
git clone https://github.com/Zombie-W33D/Z-Connect.git ~/.local/share/z-connect
cd ~/.local/share/z-connect
./fetch-deps.sh
```

`fetch-deps.sh` downloads:

- Android platform-tools, and extracts `adb` to `bin/adb`
- the pinned `gost` release for ARM64 Android, verifies its SHA-256 checksum,
  and puts it in `bin/gost`
- the pinned `gost` release for this desktop's architecture, verifies its
  checksum, and puts it in `bin/gost-desktop`

Then install the optional Omarchy widget:

```bash
./install.sh --enable
```

Or install files without enabling the widget:

```bash
./install.sh
```

The installer copies the runtime to `~/.local/share/z-connect` (unless you are
already there), writes the systemd user units, and copies the widget to
`~/.config/omarchy/plugins/zconnect.phone-tether/`.

To enable it manually:

```bash
omarchy plugin enable zconnect.phone-tether --section right
omarchy bar move zconnect.phone-tether --after omarchy.network
```

If you already have an older local copy of this widget under a different plugin
ID, disable it first so you do not end up with two phone icons.

### Optional: mandatory routing

To capture apps that ignore the system proxy, install the privileged helper
once:

```bash
sudo ~/.local/share/z-connect/install.sh --privileged
```

This installs the root-owned helper, the desktop gost binary, a fixed
configuration, and a restricted sudoers entry. It does not enable anything by
itself. `connect.sh` turns mandatory routing on automatically when the helper is
present; use `ZCONNECT_AUTO_LOCKDOWN=0` to opt out, or control it from the panel
or `lockdown.sh`.

To remove it:

```bash
sudo rm -f /usr/local/libexec/zconnect-lockdown \
           /usr/local/libexec/zconnect-gost \
           /etc/sudoers.d/zconnect-lockdown
sudo rm -rf /etc/zconnect
```

---

## Usage

### Connect

```bash
cd ~/.local/share/z-connect
./connect.sh
```

The script:

1. starts `adb` and waits up to 25 seconds for the phone,
2. starts the stable local relay on `127.0.0.1:1080` and puts it in phone mode,
3. detects the phone's DNS servers,
4. pushes `gost` if it is missing,
5. restarts the phone-side SOCKS5 proxy with TCP and UDP enabled,
6. recreates the USB port forward for `1081`,
7. tests the phone tunnel and the relay,
8. enables the user-level system proxy and login proxying unless
   `ZCONNECT_AUTO_PROXY=0`,
9. enables mandatory routing when the privileged helper is installed, unless
   `ZCONNECT_AUTO_LOCKDOWN=0`.

A successful run looks like:

```text
[1/7] Starting adb and waiting for the phone...
[2/7] Preparing the stable local relay...
[3/7] Detecting the phone's DNS resolver...
[4/7] Ensuring the phone-side proxy binary is present...
[5/7] Restarting the phone-side SOCKS5 proxy (TCP + UDP)...
[6/7] Forwarding port 1081 over USB...
[7/7] Testing the tunnel...

Connected.
  Relay endpoint: 127.0.0.1:1080 (TCP + UDP)
  Phone egress  : <phone public IP>
  System proxy  : on
  Mandatory route: on
  Route switch  : apps using 127.0.0.1:1080 switch automatically
```

If the system proxy cannot be enabled, the tunnel still works. The script prints
a warning and you can use the panel toggle or `proxy.sh enable` after fixing the
cause. The same applies to mandatory routing: without the helper it is skipped
with a warning.

### Test it manually

```bash
curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```

### Use it from a terminal

```bash
source ~/.local/share/z-connect/env.sh
curl https://example.com
```

`env.sh` exports `ALL_PROXY`, `HTTP_PROXY`, and `HTTPS_PROXY` as
`socks5h://127.0.0.1:1080`, so tools that honor those variables use the phone.

Do not launch Brave/Chromium from a shell that has `env.sh` sourced. Chromium
interprets those variables as HTTP proxies and fails against the SOCKS5 relay.
Use the system proxy toggle or the browser launcher instead.

### Use it from a browser

```bash
~/.local/share/z-connect/chromium-zconnect.sh
# or
~/.local/share/z-connect/brave-zconnect.sh
```

The launchers use a separate browser profile so they do not disturb an
already-running browser session.

### Use the system proxy

`connect.sh` turns the user-level system proxy on automatically and enables it at
login. You can also control it directly:

```bash
./proxy.sh status    # key=value state
./proxy.sh enable    # apply now and enable at login
./proxy.sh enable --no-boot
                     # apply now, do not enable at login
./proxy.sh disable   # restore the previous settings and turn login proxying off
./proxy.sh cleanup   # keep the proxy on; switch the relay to direct when the
                     # phone tunnel is down
./proxy.sh boot on   # enable at login without changing the current session
./proxy.sh boot off  # disable at login without changing the current session
```

The panel has the same control as a **System proxy** toggle. Turning it on sets
GNOME/GIO's manual SOCKS proxy and adds `SOCKS_SERVER`/`SOCKS_VERSION` to the
Hyprland session environment, the systemd/D-Bus activation environment, and
`~/.config/environment.d/90-zconnect.conf` for the next login. It does not use
`sudo`.

Boot-time proxying is implemented with two systemd user units:

- `zconnect-relay.service` keeps the stable relay running,
- `zconnect-proxy.service` re-applies the proxy settings at login.

Because the proxy is always safe to leave on, `cleanup` never turns it off. When
the phone disappears, the relay switches to direct mode and apps that use it
continue through the normal network. Run `proxy.sh disable` when you actually
want to stop using the proxy.

The previous proxy settings are saved in
`~/.local/state/zconnect/proxy-backup.env` and restored by `proxy.sh disable`.

To keep the tunnel but skip the automatic system proxy:

```bash
ZCONNECT_AUTO_PROXY=0 ./connect.sh
```

### Use mandatory routing

Mandatory routing is the "no app can bypass the phone" mode:

```bash
./lockdown.sh status   # key=value state
./lockdown.sh enable   # all TCP and UDP through the phone
./lockdown.sh disable  # remove the rules, restore normal routing
./lockdown.sh cleanup  # disable when the phone tunnel is down
```

It needs the helper from `install.sh --privileged`. `connect.sh` enables it
automatically when the helper is installed. To opt out:

```bash
ZCONNECT_AUTO_LOCKDOWN=0 ./connect.sh
```

While it is on, IPv6 is blocked and non-TCP/UDP traffic is dropped so nothing
can slip past the tunnel. See [Limitations](#limitations) for overlays and
containers.

### Check status

```bash
./status.sh          # quick, no network request
./status.sh --full   # tests the proxy and prints the phone egress IP
```

Output is `key=value`, one per line:

```text
relay_running=yes
relay_pid=12345
relay_mode=phone
relay_port=1080
phone_port=1081
relay_fallback_direct=1
relay_systemd=yes
relay_udp=yes
system_proxy=on
system_proxy_managed=yes
system_proxy_mode=manual
system_proxy_socks=127.0.0.1:1080
system_proxy_error=
system_proxy_boot=on
system_proxy_env_file=yes
system_proxy_service=active
lockdown=on
lockdown_helper=installed
lockdown_gost_pid=12345
lockdown_port=12345
lockdown_phone_port=1081
lockdown_mark=9011
lockdown_allow_lan=1
lockdown_ipv6=1
lockdown_udp=yes
adb_state=device
model=...
operator=...
network=LTE
battery=84
gost_pid=12345
forward=yes
proxy=yes
port=1080
phone_port=1081
egress_ip=...
```

`status.sh` exits without failing when the phone is absent, so it is safe for a
bar widget to poll.

### Disconnect

```bash
./disconnect.sh
```

This removes mandatory routing first, switches the relay to direct mode, then
stops `zconnect-gost` on the phone and removes the `adb` forward. It does not
change the phone's mobile data settings.

The system proxy stays on by default: it now uses the normal network through the
relay, so apps that were using it keep working. To restore the previous proxy
settings too:

```bash
./disconnect.sh --proxy-off
# or
ZCONNECT_DISCONNECT_PROXY=1 ./disconnect.sh
```

---

## Omarchy bar widget

Reopen the shell after installing the widget if it does not appear
immediately. The widget shows a phone icon in the bar:

- **Green dot**: tunnel is up and the phone has internet.
- **Amber dot**: tunnel exists but the proxy test failed.
- **Dimmed icon**: no tunnel.

Click the icon for a panel with:

- current state and a short explanation
- phone egress IP
- carrier and network type
- battery level
- phone model
- SOCKS5 endpoint and current route (Phone or Direct)
- current capture mode (all apps or proxy-aware apps)
- a **System proxy** toggle
- a **Mandatory routing** toggle (when the privileged helper is installed)
- **Connect**, **Disconnect**, and **Refresh** controls

The panel starts `connect.sh` / `disconnect.sh` and then runs `status.sh`.
Its only network request is through the phone-side proxy, so it works while the
desktop has no internet. If the cable is pulled while the proxy or mandatory
routing is on, the panel runs `proxy.sh cleanup`, which keeps the proxy on,
switches the relay to direct mode, and removes the transparent rules.

The widget can also be driven from a terminal or a Hyprland hotkey:

```bash
omarchy-shell zconnect.phone-tether connect
omarchy-shell zconnect.phone-tether disconnect
omarchy-shell zconnect.phone-tether proxyOn
omarchy-shell zconnect.phone-tether proxyOff
omarchy-shell zconnect.phone-tether proxyToggle
omarchy-shell zconnect.phone-tether proxyStatus
omarchy-shell zconnect.phone-tether lockdownOn
omarchy-shell zconnect.phone-tether lockdownOff
omarchy-shell zconnect.phone-tether lockdownToggle
omarchy-shell zconnect.phone-tether lockdownStatus
omarchy-shell zconnect.phone-tether relayStatus
omarchy-shell zconnect.phone-tether status
omarchy-shell shell toggle zconnect.phone-tether
```

The default script directory is `~/.local/share/z-connect`. If you installed
elsewhere, set the widget's `scriptDir` setting to the directory containing
`connect.sh`, `disconnect.sh`, `status.sh`, `proxy.sh`, and `lockdown.sh`.

### Testing with no local internet

1. Unplug the phone and disconnect the desktop's ethernet/Wi-Fi.
2. Plug the phone back in. Make sure USB debugging is authorized and mobile
   data is on.
3. Click the phone icon, then **Connect**.
4. Wait up to 25 seconds. The panel should show `Connected`, the phone egress
   IP, carrier/network details, and a green dot.
5. Confirm the **System proxy** toggle is on. Connect enables it automatically;
   if it is off, turn it on manually.
6. If the helper is installed, confirm **Mandatory routing** is on. This is what
   makes apps that ignore proxy settings use the phone too.
7. If an app was already open before the first Connect, restart it once so it
   picks up the system proxy. After that it points at the stable relay and
   switches routes without another restart.
8. Unplug the phone while the app is still open. The relay switches to direct
   mode and the app keeps working through the normal network. Plug the phone
   back in and press Connect; the same open app switches back to the phone.

If the panel shows `Ready`, the USB link works but the phone-side proxy is not
running — press Connect.

If the panel shows `Connected` but a browser still uses the normal connection,
restart that browser once. If it still ignores the proxy, use the included
browser launcher, turn on mandatory routing, or configure the app's SOCKS5
setting explicitly.

### Testing mandatory routing

With the phone connected and mandatory routing on, these should all use the
phone's egress IP:

```bash
curl https://api.ipify.org                 # proxy-aware
curl --noproxy '*' https://api.ipify.org   # ignores proxy settings
```

The second command is the important one: it bypasses proxy environment
variables and still leaves through the phone because the kernel rules capture
it. A UDP check with the same standard SOCKS5 UDP `ASSOCIATE` that apps use:

```bash
python3 - <<'PY'
import socket, struct
t = socket.create_connection(("127.0.0.1", 1080), timeout=5)
t.sendall(b"\x05\x01\x00"); t.recv(2)
t.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
r = t.recv(10)
bnd = (socket.inet_ntoa(r[4:8]), struct.unpack("!H", r[8:10])[0])
q = (b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
     b"\x07example\x03com\x00\x00\x01\x00\x01")
pkt = b"\x00\x00\x00\x01" + socket.inet_aton("8.8.8.8") + struct.pack("!H", 53) + q
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(6)
u.sendto(pkt, bnd)
print(len(u.recv(2048)), "UDP bytes")
PY
```

If `curl --noproxy '*'` still shows the normal IP, mandatory routing is not
active; run `./lockdown.sh status`.

---

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZCONNECT_PORT` | `1080` | Stable local relay port that apps use. `PDANET_PORT` is also accepted for compatibility. |
| `ZCONNECT_PHONE_PORT` | relay port + 1 (`1081`) | Phone-side SOCKS5 port and the matching `adb` forward. |
| `ZCONNECT_RELAY_FALLBACK_DIRECT` | `1` | Set to `0` to fail instead of falling back to the normal network when the phone is unreachable. |
| `ZCONNECT_DNS` | auto-detect + public fallbacks | Comma-separated `ip:port` resolver list for gost on the phone. |
| `ZCONNECT_WAIT` | `25` | Seconds `connect.sh` waits for the phone. |
| `ZCONNECT_AUTO_PROXY` | `1` | Set to `0` to connect without enabling the user-level system proxy. |
| `ZCONNECT_AUTO_LOCKDOWN` | `1` | Set to `0` to skip mandatory routing even when the helper is installed. |
| `ZCONNECT_DISCONNECT_PROXY` | `0` | Set to `1` to restore the previous proxy settings on disconnect. |
| `ZCONNECT_LOCKDOWN_HELPER` | `/usr/local/libexec/zconnect-lockdown` | Helper path used by `lockdown.sh`. |
| `ZCONNECT_LOCKDOWN_STATE` | `/run/zconnect/lockdown.state` | World-readable state file written by the helper. |
| `ADB` | auto | Path or command name for `adb`. |
| `ZCONNECT_DIR` | `~/.local/share/z-connect` | Installer destination. |
| `GOST_VERSION` | `v3.3.3` | gost release used by `fetch-deps.sh`. |
| `GOST_PHONE_ASSET` | `gost_3.3.3_linux_arm64.tar.gz` | gost asset for a different phone ABI. |
| `GOST_DESKTOP_ASSET` | host architecture | Override the desktop gost asset. |

Examples:

```bash
ZCONNECT_PORT=1081 ./connect.sh
ZCONNECT_PHONE_PORT=2081 ./connect.sh
ZCONNECT_DNS="9.9.9.9:53,1.1.1.1:53" ./connect.sh
ZCONNECT_WAIT=60 ./connect.sh
ZCONNECT_AUTO_PROXY=0 ./connect.sh
ZCONNECT_AUTO_LOCKDOWN=0 ./connect.sh
```

---

## Security model

- **Loopback only.** The desktop relay listens on `127.0.0.1:1080`, and `gost`
  listens on the phone's `127.0.0.1:1081`. The desktop reaches the phone only
  through the `adb` USB forward. There is no LAN or internet listener.
- **Restricted privileged helper.** Mandatory routing uses one root-owned helper
  with a fixed configuration. The sudoers entry allows only `apply`, `cleanup`,
  and `status`; no path, port, or command comes from the caller.
- **No credentials stored.** Z-Connect does not save passwords, tokens, or
  account data. The only local state is the optional installed scripts, the
  binaries in `bin/`, and a small proxy backup file containing the desktop's
  previous proxy settings (not credentials).
- **No telemetry.** Nothing is sent anywhere except the traffic you route
  through the tunnel and the one `api.ipify.org` request used to display the
  phone's egress IP.
- **ADB is powerful.** Enabling USB debugging lets a trusted computer control
  the phone. Use a trusted cable/computer, keep the phone locked when not in
  use, and revoke USB debugging authorizations when you no longer need them.
- **Not an anonymity tool.** The carrier can still see your traffic, data usage,
  and destinations. This is a transport workaround, not a VPN.
- **Review screenshots.** The panel intentionally shows runtime carrier, model,
  and battery information. Do not publish screenshots or `status.sh` output if
  you consider those details private.

This repository is written to contain no device identifiers, phone numbers,
serial numbers, public IPs, carrier DNS addresses, hostnames, or user-specific
paths. `bin/`, logs, and downloaded archives are ignored by Git.

---

## Limitations

- **User-level system proxy, not a VPN.** `proxy.sh` covers apps that honor
  GNOME/GIO settings and Chromium-based apps launched after it is enabled. Apps
  with their own proxy settings, or that ignore both, need mandatory routing or
  explicit configuration.
- **Mandatory routing needs root and captures everything.** While it is on,
  every local TCP/UDP flow uses the phone. Tailscale, WireGuard, Docker
  containers, and other overlays may break or lose connectivity because their
  traffic is captured too. IPv6 is blocked. Turn it off with
  `lockdown.sh disable` when you need those tools.
- **Non-TCP/UDP traffic is dropped in mandatory mode.** ICMP and raw-IP
  protocols cannot cross a SOCKS tunnel, so they are blocked rather than allowed
  to bypass the phone.
- **The relay switches new connections.** Existing connections that are already
  open keep using the route they started on. A browser may keep a pooled
  connection alive for a while; new tabs, requests, or a reload use the new
  route. Apps that were direct before the first Connect need one restart to
  start using the relay.
- **The phone must stay connected.** Unplugging the cable drops the `adb`
  forward. The relay falls back to direct mode so open apps keep working,
  `lockdown.sh cleanup` removes the transparent rules, and `connect.sh`
  recreates the forward on the next run.
- **USB debugging must stay enabled.** The phone-side process is started over
  ADB.
- **Phone binary architecture matters.** The default phone gost asset is ARM64.
  See [`bin/README.md`](bin/README.md) for armv7 and emulator options.
- **No IPv6 DNS auto-detection.** The DNS detector currently extracts IPv4
  servers. On an IPv6-only network, set `ZCONNECT_DNS` manually. Mandatory
  routing blocks IPv6 egress entirely.
- **UDP depends on gost on both ends.** The phone-side gost must run with
  `udp=true` (the scripts do this). Apps that use raw sockets or their own
  non-SOCKS UDP stack need mandatory routing.
- **Chromium-based apps must be restarted once** after the system proxy is first
  enabled.

---

## Troubleshooting

See [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) for detailed steps.
Quick checks:

```bash
adb devices
adb shell pidof zconnect-gost
adb shell cat /data/local/tmp/zconnect-gost.log
adb forward --list
ss -ltnp | grep -E '1080|1081'
./relay.sh status
```

Common causes:

| Symptom | Likely cause |
| --- | --- |
| `no phone detected` | Cable, USB debugging off, or phone locked/unauthorized. |
| `unauthorized` | Unlock the phone and accept the USB debugging prompt. |
| `gost not found` | Run `./fetch-deps.sh`. |
| Proxy starts but every request fails | Mobile data off, no signal, or DNS blocked; set `ZCONNECT_DNS`. |
| `adb: error: cannot bind listener` | Port 1081 is already in use; set `ZCONNECT_PHONE_PORT`. |
| `relay did not open port 1080` | Port 1080 is already in use; set `ZCONNECT_PORT`, then use the same port in apps. |
| Browser ignores the tunnel | Restart the browser once after enabling the system proxy; if it still ignores it, use the included launcher, turn on mandatory routing, or configure the app explicitly. |
| `curl --noproxy '*'` still uses the normal IP | Mandatory routing is off or the helper is not installed. Run `./lockdown.sh status` and `sudo ./install.sh --privileged`. |
| `lockdown.sh enable` says sudo needs a password | The restricted sudoers entry is missing. Re-run `sudo ./install.sh --privileged`. |
| Tailscale/Docker broke after Connect | Mandatory routing captures their traffic and blocks IPv6. Run `./lockdown.sh disable` when you need them. |
| UDP app cannot connect | Confirm `relay_udp=yes` in `./relay.sh status` and `lockdown_udp=yes`; UDP needs the phone-side gost started with `udp=true`, which `connect.sh` does. |
| No internet after unplugging the phone | The relay should fall back to direct mode automatically. If mandatory routing was on, run `./lockdown.sh cleanup`. The system proxy can stay on; run `./proxy.sh disable` only if you want to stop using it. |
| Relay says Direct while the phone is connected | Check `./relay.sh status` and `./status.sh --quick`; press Connect again or run `./relay.sh mode phone` after the tunnel is up. |

---

## Legal and fair use

Z-Connect is a general-purpose SOCKS5 relay over ADB. It does not modify your
carrier's network, hide traffic from the carrier, or unlock anything. Whether
you may use your phone's mobile data to provide internet to a computer depends
on your plan, carrier terms, and local law. Use it only where you are permitted
to do so, and respect your carrier's fair-use rules. The authors are not
responsible for misuse or for charges on your account.

PdaNet+ is a trademark of its respective owner. Z-Connect is an independent
project and is not affiliated with, endorsed by, or compatible with PdaNet's
desktop clients or proprietary USB protocol.

---

## Repository layout

```text
Z-Connect/
├── connect.sh                 # start proxy + adb forward
├── disconnect.sh              # stop proxy + remove forward
├── status.sh                  # machine-readable status
├── proxy.sh                   # system proxy on/off, boot units, cleanup
├── lockdown.sh                # mandatory routing on/off/status
├── relay.sh                   # manage the stable local relay
├── relay.py                   # TCP + UDP relay
├── env.sh                     # export proxy variables for a shell
├── chromium-zconnect.sh       # browser launcher
├── brave-zconnect.sh          # browser launcher
├── fetch-deps.sh              # download adb and both gost binaries
├── install.sh                 # install scripts, widget, and optional helper
├── lib.sh                     # shared shell helpers
├── bin/README.md              # binary download notes
├── privileged/
│   └── zconnect-lockdown      # root-owned TPROXY helper
├── omarchy/
│   └── zconnect.phone-tether/
│       ├── manifest.json
│       └── Panel.qml
├── docs/
│   ├── HOW-IT-WORKS.md        # deeper protocol/design notes
│   └── TROUBLESHOOTING.md
├── LICENSE
└── README.md
```

---

## License

MIT. See [LICENSE](LICENSE).

# How Z-Connect works

This document is the deeper technical companion to the README. It explains the
problem, the design, the packet flow, and the trade-offs.

---

## 1. The problem

PdaNet+ is an Android app that lets a phone share its mobile data with a
computer. Its desktop clients exist for Windows and macOS, but not for Linux.

On Android, PdaNet+'s USB mode is not a standard HTTP or SOCKS proxy. It uses a
proprietary binary framing over a TCP connection, and only the official PdaNet
desktop client speaks that protocol. Its documented Linux workaround is an HTTP
proxy exposed in Wi-Fi Direct mode — which requires a Wi-Fi adapter on the
desktop and does not help a wired-only machine.

So a Linux desktop cannot simply "connect to PdaNet" over USB. It needs a
different relay.

At the same time, Android's built-in USB tethering is a separate path:

```text
phone tethering toggle
    → RNDIS / dun APN
    → carrier entitlement check
    → hotspot plan required
```

Some carriers require a hotspot add-on or block tethering entirely. The goal of
Z-Connect is to avoid that path without pretending to be a VPN or modifying the
phone.

---

## 2. The core idea

A phone already has internet for its own apps. A normal app can open TCP
connections through mobile data without asking the tethering service for
permission. If we run a proxy **on the phone**, the phone's own networking stack
carries the traffic, and the desktop only needs a way to talk to that proxy.

Z-Connect uses three standard pieces:

1. **`relay.py`** — a small user-level SOCKS5 relay on the desktop that owns a
   stable loopback port and switches between the phone and the normal network.
2. **`gost`** — a small static Go proxy that listens for SOCKS5 on the phone's
   loopback interface.
3. **`adb forward`** — a USB tunnel that maps a desktop loopback port to a phone
   loopback port.

No root, no RNDIS, no `dun` APN, no tethering entitlement check.

---

## 3. Packet flow

```text
┌──────────────────────────── desktop ────────────────────────────┐
│                                                                  │
│  browser / curl / app                                            │
│      │                                                           │
│      │ SOCKS5 (or socks5h) to 127.0.0.1:1080 (stable relay)       │
│      ▼                                                           │
│  relay.py                                                        │
│      ├── phone mode  ──► 127.0.0.1:1081                          │
│      └── direct mode ──► normal desktop network                  │
│                              │                                   │
│  adb server ◄────────────────┘                                   │
│      │  USB cable                                                │
└──────┼───────────────────────────────────────────────────────────┘
       │
┌──────▼──────────────────────── phone ────────────────────────────┐
│                                                                  │
│  adbd  ──► 127.0.0.1:1081                                        │
│                 │                                                │
│                 ▼                                                │
│          gost (UID 2000, /data/local/tmp/zconnect-gost)          │
│                 │                                                │
│                 │ ordinary outbound TCP/DNS                      │
│                 ▼                                                │
│          mobile data / carrier network                           │
└──────────────────────────────────────────────────────────────────┘
```

### Step by step

1. The desktop application connects to `127.0.0.1:1080`.
2. `relay.py` reads its mode file. In phone mode it opens a SOCKS5 connection
   to `127.0.0.1:1081`; in direct mode it connects to the destination itself.
3. In phone mode, the `adb` client forwards the connection over USB to the
   phone's `127.0.0.1:1081`.
4. `gost` accepts the SOCKS5 request. With `socks5h`, the hostname arrives
   unresolved.
5. `gost` resolves the hostname using its configured resolver list, then opens a
   normal TCP or UDP connection from the phone.
6. Return traffic follows the same path in reverse.

UDP uses gost's UDP-over-TCP extension (SOCKS5 command `0xF3`) so datagrams can
cross the adb forward, which only carries TCP. The desktop relay speaks both
standard `UDP ASSOCIATE` to local apps and the extension to the phone.

The desktop never needs a default route, a working DNS server, or a Wi-Fi
adapter. It only needs the USB cable and a local loopback port.

### Live route switching

Windows lets an open app move to a new network because the app keeps using the
same socket API and the operating system re-routes new connections. A proxy
setup normally cannot do that: if an app is configured to use a dead proxy, the
app fails until it is restarted with new settings.

The relay fixes that by making the app-facing endpoint permanent:

- apps always use `127.0.0.1:1080`;
- the relay reads its mode for each new connection;
- `connect.sh` sets phone mode after the tunnel is up;
- `disconnect.sh` and `proxy.sh disable` set direct mode before tearing the
  tunnel down;
- if the phone fails while the mode says phone, the relay logs the failure and
  falls back to a direct connection instead of returning an error.

So an open browser, terminal, or chat app that was pointed at the relay switches
on its next connection. Connections that are already established stay on their
original route, and a browser may reuse a pooled connection for a while. A new
tab, a reload, or a fresh request uses the new route.

Apps that were launched before the first Connect and were talking directly to
the internet need one restart to start using the relay. After that, every phone
connect/disconnect is transparent to them.

---

## 4. Why this avoids the tethering entitlement check

Android's tethering service is responsible for sharing the phone's connection
with **other devices**. It creates a separate interface/APN and asks the carrier
whether that is allowed.

Z-Connect does not ask Android to share anything. It runs a process on the phone
that makes its own connections. From Android's and the carrier's point of view,
this looks like an app using mobile data. The desktop is not a tethered client;
it is a client of a proxy running on the phone.

This is why the approach works without a hotspot plan on networks that gate the
tethering API. It is also why it is not a loophole in the phone's security
model: the proxy is reachable only over the authorized ADB connection.

**Important:** this does not hide traffic from the carrier, bypass data caps, or
make the connection anonymous. It only changes which Android component
originates the traffic. See the legal note in the README.

---

## 5. Components

### `relay.py` and `relay.sh`

`relay.py` is a small Python 3 SOCKS5 relay with a switchable upstream. It
implements TCP `CONNECT`, standard UDP `ASSOCIATE`, and gost's UDP-over-TCP
extension (`0xF3`) for phone mode. It listens on the desktop's `127.0.0.1:1080`
and reads a mode file for each new connection:

```text
phone  → SOCKS5 to 127.0.0.1:1081 (the adb-forwarded phone proxy)
direct → resolve and connect to the destination from the desktop
```

If phone mode cannot reach the phone, the relay logs a rate-limited warning and
falls back to direct. That fallback is what keeps open apps working when the
cable is pulled. Set `ZCONNECT_RELAY_FALLBACK_DIRECT=0` to make failures
explicit instead.

`relay.sh` manages the relay process:

```text
relay.sh start | stop | restart | ensure
relay.sh run                 (foreground, used by the systemd unit)
relay.sh mode phone | mode direct
relay.sh status | cleanup | log
```

When a systemd user unit named `zconnect-relay.service` is installed, `start`,
`stop`, and `restart` delegate to it so the relay restarts after a crash and
survives a logout/login cycle. Otherwise they use a background process.

State lives in `~/.local/state/zconnect/`:

- `relay.pid` — the relay process ID;
- `relay-mode` — `phone` or `direct`;
- `relay.log` — relay output;
- `relay.lock` — serializes start/stop/mode changes.

The relay uses no root, no TUN device, and no route changes. It is a user-space
proxy, not a VPN. Mandatory system-wide capture is a separate, optional mode that
does need root.

### `gost`

[gost](https://github.com/go-gost/gost) is a static Go proxy. Z-Connect uses it
in SOCKS5 server mode:

```text
gost -L 'socks5://127.0.0.1:1081?udp=true&resolver=<dns-list>'
```

Why gost:

- single static binary, no runtime dependencies on the phone;
- runs as an ordinary unprivileged user;
- supports SOCKS5 with remote DNS;
- can be given an explicit resolver list;
- supports UDP ASSOCIATE and UDP-over-TCP (`0xF3`) with `udp=true`.

The binary is pushed to `/data/local/tmp/zconnect-gost`. That directory is
writable by the `shell` user and survives phone reboots. The process does not
survive a phone reboot, but `connect.sh` starts it again.

### `adb forward`

`adb forward tcp:1081 tcp:1081` creates a listener on the desktop's loopback
interface and forwards each connection to the phone's loopback interface over
the USB transport. The stable app-facing relay owns `1080`, so the forward uses
the phone port (`1081` by default).

Properties:

- survives while the `adb` server and USB connection stay alive;
- is removed when the phone is unplugged or the `adb` server restarts;
- is recreated by `connect.sh`;
- does not open a port on the LAN.

### `connect.sh`

Responsibilities:

1. Find a usable `adb` (explicit `ADB`, `PATH`, or `bin/adb`).
2. Start the `adb` server and wait for an authorized device.
3. Start the stable local relay on `ZCONNECT_PORT` and set it to phone mode.
4. Detect the phone's IPv4 DNS servers from `dumpsys connectivity`.
5. Push `gost` if `/data/local/tmp/zconnect-gost` is missing or not executable.
6. Kill any previous `zconnect-gost` process and start a fresh one on
   `ZCONNECT_PHONE_PORT` with `udp=true`.
7. Recreate the `adb` forward for `ZCONNECT_PHONE_PORT`.
8. Test the phone tunnel directly, then through the relay, and print the egress
   IP.
9. Enable the user-level system proxy and login proxying unless
   `ZCONNECT_AUTO_PROXY=0`.
10. Enable mandatory routing when the privileged helper is installed unless
    `ZCONNECT_AUTO_LOCKDOWN=0`.

The script is idempotent: running it repeatedly is safe.

### `disconnect.sh`

Removes mandatory routing first, sets the relay to direct mode so open apps fall
back to the normal network, then kills `zconnect-gost` on the phone and removes
the port forward. The system proxy stays on by default and now uses the normal
network through the relay; `--proxy-off` also restores the previous proxy
settings. It leaves the rest of the desktop's networking untouched.

### `status.sh`

Emits `key=value` lines. Quick mode only inspects `adb` state, the forward, and
the phone-side process. `--full` additionally makes one request through the
phone proxy to confirm end-to-end connectivity and retrieve the phone's egress
IP.

It also emits the relay state (`relay_running`, `relay_pid`, `relay_mode`,
`relay_port`, `phone_port`, `relay_fallback_direct`, `relay_systemd`,
`relay_udp`), the system-proxy state (`system_proxy`, `system_proxy_managed`,
`system_proxy_mode`, `system_proxy_socks`, `system_proxy_error`,
`system_proxy_boot`, `system_proxy_env_file`, `system_proxy_service`), and the
mandatory-routing state (`lockdown`, `lockdown_helper`, `lockdown_gost_pid`,
`lockdown_tun`, `lockdown_port`, `lockdown_phone_port`, `lockdown_mark`,
`lockdown_allow_lan`, `lockdown_ipv6`, `lockdown_udp`) before the phone checks. The panel uses this to
recover after a crash or cable pull.

The script deliberately exits 0 even when the phone is missing, because the bar
widget polls it.

### `proxy.sh`

Manages the optional user-level system proxy:

- `status` prints the current state, whether Z-Connect owns it, and whether boot
  proxying is enabled;
- `enable` ensures the relay is running, sets it to phone or direct mode based on
  the tunnel, saves the current settings, applies the GNOME/GIO manual SOCKS
  proxy and the session environment, writes
  `~/.config/environment.d/90-zconnect.conf`, and enables the systemd user units;
- `enable --no-boot` applies the settings without enabling login proxying;
- `disable` disables login proxying, sets the relay to direct mode, then restores
  the saved settings;
- `cleanup` keeps the proxy on. When the tunnel is down it puts the relay in
  direct mode and asks `lockdown.sh` to remove mandatory routing if the phone is
  gone;
- `boot on|off` controls login proxying without changing the current session.

The boot units are `zconnect-relay.service` (stable relay, restart on failure)
and `zconnect-proxy.service` (oneshot that re-applies the proxy settings). The
environment file gives apps launched by the desktop the same `SOCKS_SERVER`,
`SOCKS_VERSION`, and `NO_PROXY` values before any shell runs.

The backup lives in `~/.local/state/zconnect/proxy-backup.env`; a marker and a
lock file live next to it. No root is required.

### Omarchy widget

The widget is a single `Panel.qml` registered as a bar widget. It:

- renders the phone icon and state dot;
- runs `status.sh` every 60 seconds when closed and every 15 seconds when open;
- runs `connect.sh` / `disconnect.sh` as child processes;
- shows the current route (Phone or Direct), capture mode, and SOCKS5 endpoint;
- shows the latest error output if an action fails;
- exposes **System proxy** and **Mandatory routing** toggles;
- exposes IPC methods (`open`, `close`, `toggle`, `connect`, `disconnect`,
  `proxyOn`, `proxyOff`, `proxyToggle`, `proxyStatus`, `lockdownOn`,
  `lockdownOff`, `lockdownToggle`, `lockdownStatus`, `relayStatus`, `refresh`,
  `status`) so it can be driven by a hotkey.

It does not need local internet because the only network request it triggers is
the `--full` status probe through the phone proxy.

---

## 6. DNS design

DNS is the most common failure point in a proxy setup.

If the desktop resolves a hostname before opening the SOCKS connection, it needs
working DNS. With no local internet, that fails. The fix is remote DNS:

- `curl --socks5-hostname`
- `socks5h://` proxy URLs
- browser proxy settings that send hostnames to the proxy

Then the phone resolves the name. But Android's Go resolver does not always use
the mobile network's DNS servers when a process runs outside the app framework.
The symptom is that IP addresses work but names do not.

`connect.sh` therefore:

1. reads the phone's current IPv4 DNS servers from
   `dumpsys connectivity` (the `DnsAddresses` field of the default network);
2. appends public resolvers as fallbacks;
3. passes the whole list to gost with `?resolver=...`.

The public fallbacks matter because some carrier DNS servers are only reachable
from inside the carrier network, and some networks block third-party DNS. Having
both maximizes the chance that at least one resolver works.

Override the list when needed:

```bash
ZCONNECT_DNS="9.9.9.9:53,1.1.1.1:53" ./connect.sh
```

---

## 7. User-level system proxy

SOCKS5 only helps apps that know to use it. `proxy.sh` bridges that gap without
root by changing per-user settings in two places:

1. **GNOME/GIO settings.** Apps that use GLib's proxy resolver read
   `org.gnome.system.proxy`. `proxy.sh` sets the mode to `manual`, points the
   SOCKS host at `127.0.0.1` and the configured port, and merges private ranges
   into `ignore-hosts`.
2. **Session environment for new processes.** Hyprland can set the environment
   for future launches with `hl.env(...)`. The script also updates the systemd
   user environment and the D-Bus activation environment so services started
   later inherit the same values.

The environment variables are deliberately narrow:

```text
SOCKS_SERVER=127.0.0.1:1080
SOCKS_VERSION=5
NO_PROXY=localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.local
no_proxy=<same>
```

### Why the traditional proxy variables are cleared

Chromium and Electron read `http_proxy`, `https_proxy`, and `all_proxy` and treat
them as **HTTP** proxies. A SOCKS5 relay at that address does not speak HTTP, so
Brave/Chromium fails with `ERR_EMPTY_RESPONSE` when those variables are present.
Chromium's own SOCKS variables are `SOCKS_SERVER` and `SOCKS_VERSION`.

`proxy.sh` therefore saves and clears both the lowercase and uppercase
traditional variables while the system proxy is on, and restores them on
disable. This is what makes the system proxy work with Brave/Chromium.

Terminal tools that need the traditional variables can still use
`source env.sh` or `curl --socks5-hostname`. Do not launch Chromium from a shell
that has `env.sh` sourced; the system proxy and the launcher scripts are the
supported paths for browsers.

### Saved state and failure handling

Before changing anything, `proxy.sh enable` saves:

- the previous `gsettings` mode, SOCKS host/port, and ignore-hosts;
- whether each managed environment variable was set, and its value.

The backup is `~/.local/state/zconnect/proxy-backup.env`. A marker file
(`proxy-active`) and a lock file (`proxy.lock`) live in the same directory,
which is created with mode `700`. The lock uses `flock` so a panel toggle and a
script cannot apply settings at the same time.

`enable` first ensures the relay is running and in phone mode, then checks the
phone tunnel directly (so the relay's direct fallback cannot hide a dead phone),
then checks the relay endpoint. It applies the `gsettings` values, then the
environment, and sets `mode=manual` last so a partial failure does not cut the
desktop over to a dead proxy. If applying the settings fails, it restores the
backup immediately and puts the relay back in direct mode.

`disable` puts the relay in direct mode first, then restores the saved settings
and removes the backup. The relay stays alive, so apps that were pointed at it
continue through the normal network. If there is no backup, `disable` only clears
settings that still point at Z-Connect's own endpoint, so it does not stomp on an
unrelated proxy configuration.

`cleanup` is the cable-pull path. It checks whether the tunnel is still up; if
the forward or the phone-side process is gone, it puts the relay in direct mode
and asks `lockdown.sh` to remove mandatory routing. It does **not** turn the
system proxy off: the relay is now direct, so apps keep working through the
normal network. The Omarchy panel calls `cleanup` whenever `status.sh` reports a
managed proxy or active lockdown while the tunnel is down.

### Automatic behavior

- `connect.sh` enables the system proxy after a successful tunnel test unless
  `ZCONNECT_AUTO_PROXY=0`, and enables it at login.
- `disconnect.sh` keeps the proxy on by default, so open apps fall back to the
  normal network. `--proxy-off` restores the previous settings.
- The panel's **System proxy** toggle can turn it on or off independently while
  the tunnel is up.

### Limits

This is a user-level proxy, not a VPN. It does not change routes, and it cannot
capture an app that ignores both `gsettings` and the Chromium SOCKS variables.
Apps that were already running need one restart the first time the proxy is
enabled so they inherit the environment. After that they point at the stable
relay and switch routes automatically on new connections.
On a non-GNOME desktop without Hyprland, fewer apps will see the change; the
browser launchers and explicit proxy settings remain the fallback. Mandatory
routing covers those apps when it is installed.

---

## 8. Mandatory routing (TUN)

The user-level proxy is cooperative. Mandatory routing makes the kernel capture
the traffic instead, so an app cannot bypass the phone by ignoring proxy
settings.

### Why a TUN

The desktop needs transparent TCP **and UDP** capture. Options considered:

- **TPROXY** — mangle marking plus policy routing. It captures forwarded traffic,
  but on current kernels a mark set in the `OUTPUT` hook does not reroute an
  already-resolved local socket, so locally generated desktop traffic keeps
  using the normal interface.
- **REDIRECT** — iptables-only. TCP preserves the original destination, but UDP
  REDIRECT rewrites the destination before the socket receives it, so the proxy
  cannot recover the original target.
- **TUN** — a virtual interface captures every IPv4 packet. gost's `tungo`
  handler runs tun2socks in userspace, terminates TCP and UDP, and forwards each
  flow through the existing SOCKS5 chain. This handles both protocols without
  conntrack tricks and leaves the normal default route untouched.

Z-Connect uses a TUN.

### Components

The privileged helper (`privileged/zconnect-lockdown`) is installed to
`/usr/local/libexec/zconnect-lockdown`. It reads only
`/etc/zconnect/lockdown.conf`, which is root-owned, and accepts three commands:
`apply`, `cleanup`, and `status`. The sudoers entry allows exactly those.

On `apply` it:

1. starts a root-owned desktop gost
   (`/usr/local/libexec/zconnect-gost`) with:

   ```text
   -L tungo://:0?name=zconnect0&net=198.18.0.1/15&mtu=1400
   -F socks5://127.0.0.1:1081
   ```

   `tungo` creates the TUN device, assigns the address, and runs tun2socks. The
   `-F socks5://127.0.0.1:1081` chain carries TCP CONNECT and gost's `0xF3`
   UDP-over-TCP extension across the adb forward. gost's own connection to the
   phone is loopback, so it is never captured by the TUN.

2. adds policy rules at preference 9000-9010. Loopback, link-local, multicast,
   broadcast, `0.0.0.0/8`, and (by default) the private LAN ranges stay on the
   normal table. All other IPv4 traffic looks up table 9010, whose default route
   is the TUN. The normal default route in the main table is not modified.
3. sets `rp_filter=0` on the TUN only. tun2socks writes replies back with the
   remote address as the source, which strict reverse-path filtering would
   otherwise drop.
4. points systemd-resolved at the TUN (`resolvectl dns` and a `~.` routing
   domain) when `resolvectl` is available, so DNS also uses the phone. On
   cleanup the per-link setting is reverted.
5. blocks IPv6 egress in both `OUTPUT` and `FORWARD`, because the tunnel carries
   IPv4 only.

The helper writes a world-readable state file at
`/run/zconnect/lockdown.state` so `lockdown.sh status` and the panel can report
the state without sudo.

### Lifecycle

- `connect.sh` enables mandatory routing automatically when the helper is
  installed. `ZCONNECT_AUTO_LOCKDOWN=0` opts out.
- `disconnect.sh` removes the rules before stopping the phone-side process, so
  the desktop does not lose its normal connection during teardown.
- `proxy.sh cleanup` and `lockdown.sh cleanup` remove the rules whenever the
  phone tunnel is down, so a dead or missing phone cannot strand the desktop.
  Reconnect and re-enable mandatory routing when the phone is back.
- `lockdown.sh disable` removes the rules and stops the root gost process.

### Trade-offs

- **Root is required.** There is no rootless way to capture the whole desktop.
- **Everything is captured.** Tailscale, WireGuard, Docker, and other overlays
  are affected while the mode is on. Turn it off when you need them.
- **Existing connections keep their route.** A socket that connected before the
  mode was enabled has already cached its route; new connections from the same
  app use the TUN immediately.
- **IPv6 is blocked.** The tunnel is IPv4 over adb.
- **ICMP does not cross the tunnel.** Ping and other non-TCP/UDP protocols are
  delivered to the TUN and dropped; TCP and UDP are unaffected.
- **The LAN is excluded by default.** `ZCONNECT_ALLOW_LAN=0` sends even private
  ranges through the phone.

---

## 9. Lifecycle and persistence

| Event | What survives | What breaks |
| --- | --- | --- |
| Desktop reboot | Phone-side gost may still run; `bin/` files; boot units re-apply the proxy | `adb` server and forward are gone; the relay restarts from its unit |
| Unplug/replug phone | Phone-side gost may still run; relay falls back to direct | `adb` forward is gone |
| Unplug while system proxy is on | The saved proxy backup; the relay in direct mode | `proxy.sh cleanup` removes mandatory routing; the proxy stays on and uses the normal network |
| Unplug while mandatory routing is on | The saved proxy backup | The TUN route is removed by cleanup; without cleanup, traffic is pinned to a dead phone |
| Phone reboot | Nothing on the phone side | `gost` process and forward are gone |
| `disconnect.sh` | Binaries, scripts, and the relay in direct mode | gost process and forward are gone; mandatory routing is removed; the proxy stays on unless `--proxy-off` |
| `adb kill-server` | Phone-side gost; the relay in direct mode | Forward is gone |

In all cases, run `./connect.sh` again. It re-pushes gost only if missing,
recreates the forward, and sets the relay back to phone mode.

---

## 10. Security analysis

### What is exposed

- A SOCKS5 relay listener on the **desktop's** `127.0.0.1:1080`.
- An `adb` forward on the **desktop's** `127.0.0.1:1081`.
- A SOCKS5 listener on the **phone's** `127.0.0.1:1081`.
- In mandatory mode, a userspace TUN device (`zconnect0`) owned by the root
  gost process. It has no listening socket; the only network endpoint remains
  the loopback SOCKS server.

None of these listeners is bound to a LAN interface. An attacker on the same
Wi-Fi or ethernet network cannot connect to any of them. Access requires either
the desktop's local user account or the USB/ADB connection.

### Trust assumptions

- The desktop is trusted. Anyone who can run `adb` against the phone can run
  commands as the `shell` user.
- The USB cable and computer are trusted. USB debugging is a powerful
  capability; do not enable it on public machines.
- The phone's mobile data connection is not automatically private. The carrier
  sees the traffic.
- The privileged helper is trusted. It is root-owned, reads a root-owned config,
  and is the only command allowed by the restricted sudoers entry. Anyone who
  can edit those files already has root.

### What is not protected

- Z-Connect does not encrypt traffic beyond what the application already uses.
  Use HTTPS/TLS as usual.
- It does not prevent the carrier from observing destinations, timing, or data
  volume.
- It does not stop Android from showing the USB debugging notification.
- It does not hide the proxy process from the phone's user.

### Repository hygiene

The repo intentionally excludes:

- device serial numbers and phone numbers;
- public or private IP addresses observed at runtime;
- carrier names and carrier-specific DNS servers;
- hostnames and usernames;
- logs and downloaded binaries.

`bin/adb`, `bin/gost`, `bin/gost-desktop`, archives, and logs are in
`.gitignore`. Runtime status does display carrier/model/battery and the phone
egress IP; review those before sharing a screenshot. The system-proxy backup in
`~/.local/state/zconnect/` is outside the repository and contains only the
desktop's previous proxy settings.

---

## 11. Alternatives considered

### Android USB tethering (RNDIS)

The simplest option, but it is the exact path that triggers carrier entitlement
checks and may require a hotspot plan.

### PdaNet+ USB mode

No Linux client, proprietary framing. Reverse-engineering it would require
maintaining a protocol implementation tied to a closed-source app. Not worth it
when a standard SOCKS5 relay does the same job.

### PdaNet+ Wi-Fi Direct HTTP proxy

Requires a Wi-Fi adapter on the desktop and is tied to PdaNet's app. A wired-only
desktop cannot use it.

### `tun2socks` / `redsocks` / sing-box on the desktop

Useful for transparent whole-desktop routing, but requires root and more moving
parts. Z-Connect's user-level system proxy covers GNOME/GIO apps and
Chromium-based apps without root. For apps that ignore both, Z-Connect now ships
an optional TUN mode with a restricted helper. It reuses the same gost binary
and SOCKS chain, so there is no second proxy stack to install.

### SSH reverse tunnel

Could provide a SOCKS proxy, but requires an SSH server on the phone (not
standard on Android) and more setup. `gost` + `adb` is lighter.

---

## 12. Design trade-offs

| Choice | Benefit | Cost |
| --- | --- | --- |
| SOCKS5 instead of a TUN device | No root; simple; works with common apps | Per-app configuration; not system-wide on its own |
| Stable local relay | Apps keep one proxy setting and switch routes without a restart | One extra user-level process |
| User-level system proxy | No root; GNOME/GIO and Chromium apps work; can start at login | Not a VPN; apps that were direct need one restart; apps with their own proxy config may ignore it |
| Optional TUN mode | Every app, including UDP, uses the phone; no bypass | Requires root; captures overlays too; blocks IPv6 and ICMP |
| gost on the phone | Avoids tethering stack; static binary; TCP + UDP | Must match phone ABI; process must be started over ADB |
| `adb forward` | No extra network listener; USB-only | Forward does not survive unplug/reboot |
| Remote DNS | Works with no desktop DNS | Requires `socks5h`-aware clients |
| Explicit resolver list | Reliable on Android | Needs auto-detection or manual override on unusual networks |
| Omarchy widget | One-click connect/disconnect and visible route | Optional; tied to Omarchy/Quickshell |

---

## 13. Failure modes and diagnostics

| Failure | Where to look |
| --- | --- |
| Phone not seen | `adb devices`, cable, USB debugging authorization |
| gost not starting | `adb shell cat /data/local/tmp/zconnect-gost.log` |
| Wrong binary format | `file bin/gost`; use the correct ABI asset |
| Port conflict | `ss -ltnp | grep -E '1080|1081'`; change `ZCONNECT_PORT` or `ZCONNECT_PHONE_PORT` |
| Relay says Direct while the phone is up | `./relay.sh status`, `./status.sh --quick`; run `./relay.sh mode phone` or press Connect |
| Relay missing or crashed | `./relay.sh log`; `./relay.sh ensure` |
| Proxy up, DNS fails | Set `ZCONNECT_DNS`; test with `curl --socks5-hostname` |
| Proxy up, phone has no data | Check mobile data toggle and signal |
| UDP app cannot connect | `./relay.sh status` (`relay_udp=yes`), `./lockdown.sh status` (`lockdown_udp=yes`); phone gost must run with `udp=true` |
| System proxy on, app still direct | Restart the app once; check `./proxy.sh status` and the gsettings values; turn on mandatory routing |
| `curl --noproxy '*'` bypasses the phone | Mandatory routing is off or its helper is missing; `./lockdown.sh status`, `sudo ./install.sh --privileged` |
| Mandatory routing breaks Tailscale/Docker | Expected; run `./lockdown.sh disable` while you need those tools |
| No internet after unplugging the phone | The relay should be in direct mode; run `./proxy.sh cleanup` (keeps the proxy on) or `./lockdown.sh cleanup`; the panel also does this |
| Browser ignores system proxy | Use `chromium-zconnect.sh`, turn on mandatory routing, or configure the app explicitly |

More detail: [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

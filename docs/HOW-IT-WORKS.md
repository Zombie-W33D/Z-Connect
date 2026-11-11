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

Z-Connect uses two standard pieces:

1. **`gost`** — a small static Go proxy that listens for SOCKS5 on the phone's
   loopback interface.
2. **`adb forward`** — a USB tunnel that maps a desktop loopback port to a phone
   loopback port.

No root, no RNDIS, no `dun` APN, no tethering entitlement check.

---

## 3. Packet flow

```text
┌──────────────────────────── desktop ────────────────────────────┐
│                                                                  │
│  browser / curl / app                                            │
│      │                                                           │
│      │ SOCKS5 (or socks5h) to 127.0.0.1:1080                     │
│      ▼                                                           │
│  adb server                                                      │
│      │  USB cable                                                │
└──────┼───────────────────────────────────────────────────────────┘
       │
┌──────▼──────────────────────── phone ────────────────────────────┐
│                                                                  │
│  adbd  ──► 127.0.0.1:1080                                        │
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
2. The `adb` client forwards that connection over USB to the phone's
   `127.0.0.1:1080`.
3. `gost` accepts the SOCKS5 request. With `socks5h`, the hostname arrives
   unresolved.
4. `gost` resolves the hostname using its configured resolver list, then opens a
   normal TCP connection from the phone.
5. Return traffic follows the same path in reverse.

The desktop never needs a default route, a working DNS server, or a Wi-Fi
adapter. It only needs the USB cable and a local loopback port.

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

### `gost`

[gost](https://github.com/go-gost/gost) is a static Go proxy. Z-Connect uses it
in SOCKS5 server mode:

```text
gost -L 'socks5://127.0.0.1:1080?resolver=<dns-list>'
```

Why gost:

- single static binary, no runtime dependencies on the phone;
- runs as an ordinary unprivileged user;
- supports SOCKS5 with remote DNS;
- can be given an explicit resolver list.

The binary is pushed to `/data/local/tmp/zconnect-gost`. That directory is
writable by the `shell` user and survives phone reboots. The process does not
survive a phone reboot, but `connect.sh` starts it again.

### `adb forward`

`adb forward tcp:1080 tcp:1080` creates a listener on the desktop's loopback
interface and forwards each connection to the phone's loopback interface over
the USB transport.

Properties:

- survives while the `adb` server and USB connection stay alive;
- is removed when the phone is unplugged or the `adb` server restarts;
- is recreated by `connect.sh`;
- does not open a port on the LAN.

### `connect.sh`

Responsibilities:

1. Find a usable `adb` (explicit `ADB`, `PATH`, or `bin/adb`).
2. Start the `adb` server and wait for an authorized device.
3. Detect the phone's IPv4 DNS servers from `dumpsys connectivity`.
4. Push `gost` if `/data/local/tmp/zconnect-gost` is missing or not executable.
5. Kill any previous `zconnect-gost` process and start a fresh one.
6. Recreate the `adb` forward.
7. Test the tunnel through `https://api.ipify.org` and print the egress IP.
8. Enable the user-level system proxy unless `ZCONNECT_AUTO_PROXY=0`.

The script is idempotent: running it repeatedly is safe.

### `disconnect.sh`

Restores the previous system-proxy settings first (this works even if the cable
is already gone), then kills `zconnect-gost` on the phone and removes the port
forward. It leaves the rest of the desktop's networking untouched.

### `status.sh`

Emits `key=value` lines. Quick mode only inspects `adb` state, the forward, and
the phone-side process. `--full` additionally makes one request through the
proxy to confirm end-to-end connectivity and retrieve the phone's egress IP.

It also emits `system_proxy`, `system_proxy_managed`, `system_proxy_mode`,
`system_proxy_socks`, and `system_proxy_error` before the phone checks, so the
panel can restore a proxy left behind after a crash or cable pull.

The script deliberately exits 0 even when the phone is missing, because the bar
widget polls it.

### `proxy.sh`

Manages the optional user-level system proxy:

- `status` prints the current state and whether Z-Connect owns it;
- `enable` saves the current settings, then sets the GNOME/GIO manual SOCKS
  proxy and the Hyprland session environment;
- `disable` restores the saved settings;
- `cleanup` restores them only when the phone tunnel is no longer up.

The backup lives in `~/.local/state/zconnect/proxy-backup.env`; a marker and a
lock file live next to it. No root is required.

### Omarchy widget

The widget is a single `Panel.qml` registered as a bar widget. It:

- renders the phone icon and state dot;
- runs `status.sh` every 60 seconds when closed and every 15 seconds when open;
- runs `connect.sh` / `disconnect.sh` as child processes;
- shows the latest error output if an action fails;
- exposes IPC methods (`open`, `close`, `toggle`, `connect`, `disconnect`,
  `proxyOn`, `proxyOff`, `proxyToggle`, `proxyStatus`, `refresh`, `status`) so
  it can be driven by a hotkey.

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

`enable` first checks the tunnel through the SOCKS proxy. It applies the
`gsettings` values, then the environment, and sets `mode=manual` last so a
partial failure does not cut the desktop over to a dead proxy. If applying the
settings fails, it restores the backup immediately.

`disable` restores the saved settings and removes the backup. If there is no
backup, it only clears settings that still point at Z-Connect's own endpoint, so
it does not stomp on an unrelated proxy configuration.

`cleanup` is the crash-recovery path. It checks whether the tunnel is still up;
if the forward or the phone-side process is gone, it calls `disable`. The
Omarchy panel calls `cleanup` whenever `status.sh` reports
`system_proxy_managed=yes` while the tunnel is down. That is what prevents a
stale SOCKS proxy from making the desktop look offline after the phone is
unplugged.

### Automatic behavior

- `connect.sh` enables the system proxy after a successful tunnel test unless
  `ZCONNECT_AUTO_PROXY=0`.
- `disconnect.sh` restores the previous settings before stopping the tunnel, so
  it still works when the cable has already been pulled.
- The panel's **System proxy** toggle can turn it on or off independently while
  the tunnel is up.

### Limits

This is a user-level proxy, not a VPN. It does not change routes, and it cannot
capture an app that ignores both `gsettings` and the Chromium SOCKS variables.
Apps that were already running must be restarted to inherit the environment.
On a non-GNOME desktop without Hyprland, fewer apps will see the change; the
browser launchers and explicit proxy settings remain the fallback.

---

## 8. Lifecycle and persistence

| Event | What survives | What breaks |
| --- | --- | --- |
| Desktop reboot | Phone-side gost may still run; `bin/` files | `adb` server and forward are gone |
| Unplug/replug phone | Phone-side gost may still run | `adb` forward is gone |
| Unplug while system proxy is on | The saved proxy backup | The panel/`proxy.sh cleanup` restores the previous proxy settings |
| Phone reboot | Nothing on the phone side | `gost` process and forward are gone |
| `disconnect.sh` | Binaries and scripts | gost process and forward are gone; previous proxy settings are restored |
| `adb kill-server` | Phone-side gost | Forward is gone |

In all cases, run `./connect.sh` again. It re-pushes gost only if missing and
recreates the forward.

---

## 9. Security analysis

### What is exposed

- A SOCKS5 listener on the **phone's** `127.0.0.1:1080`.
- An `adb` forward on the **desktop's** `127.0.0.1:1080`.

Neither listener is bound to a LAN interface. An attacker on the same Wi-Fi or
ethernet network cannot connect to either one. Access requires either the
desktop's local user account or the USB/ADB connection.

### Trust assumptions

- The desktop is trusted. Anyone who can run `adb` against the phone can run
  commands as the `shell` user.
- The USB cable and computer are trusted. USB debugging is a powerful
  capability; do not enable it on public machines.
- The phone's mobile data connection is not automatically private. The carrier
  sees the traffic.

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

`bin/adb`, `bin/gost`, archives, and logs are in `.gitignore`. Runtime status
does display carrier/model/battery and the phone egress IP; review those before
sharing a screenshot. The system-proxy backup in `~/.local/state/zconnect/` is
outside the repository and contains only the desktop's previous proxy settings.

---

## 10. Alternatives considered

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

### `tun2socks` / `redsocks` on the desktop

Useful for transparent whole-desktop routing, but requires root and more moving
parts. Z-Connect's user-level system proxy covers GNOME/GIO apps and
Chromium-based apps without root; these tools remain the option for apps that
ignore both, or when every packet must be captured.

### SSH reverse tunnel

Could provide a SOCKS proxy, but requires an SSH server on the phone (not
standard on Android) and more setup. `gost` + `adb` is lighter.

---

## 11. Design trade-offs

| Choice | Benefit | Cost |
| --- | --- | --- |
| SOCKS5 instead of a TUN device | No root; simple; works with common apps | Per-app configuration; not system-wide |
| User-level system proxy | No root; GNOME/GIO and Chromium apps work | Not a VPN; already-open apps need a restart; apps with their own proxy config may ignore it |
| gost on the phone | Avoids tethering stack; static binary | Must match phone ABI; process must be started over ADB |
| `adb forward` | No extra network listener; USB-only | Forward does not survive unplug/reboot |
| Remote DNS | Works with no desktop DNS | Requires `socks5h`-aware clients |
| Explicit resolver list | Reliable on Android | Needs auto-detection or manual override on unusual networks |
| Omarchy widget | One-click connect/disconnect | Optional; tied to Omarchy/Quickshell |

---

## 12. Failure modes and diagnostics

| Failure | Where to look |
| --- | --- |
| Phone not seen | `adb devices`, cable, USB debugging authorization |
| gost not starting | `adb shell cat /data/local/tmp/zconnect-gost.log` |
| Wrong binary format | `file bin/gost`; use the correct ABI asset |
| Port conflict | `ss -ltnp | grep 1080`; change `ZCONNECT_PORT` |
| Proxy up, DNS fails | Set `ZCONNECT_DNS`; test with `curl --socks5-hostname` |
| Proxy up, phone has no data | Check mobile data toggle and signal |
| System proxy on, app still direct | Restart the app; check `./proxy.sh status` and the gsettings values |
| No internet after unplugging the phone | Run `./proxy.sh cleanup` or `./proxy.sh disable`; the panel also does this |
| Browser ignores system proxy | Use `chromium-zconnect.sh` or configure the app explicitly |

More detail: [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

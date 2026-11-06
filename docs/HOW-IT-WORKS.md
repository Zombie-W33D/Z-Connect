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

The script is idempotent: running it repeatedly is safe.

### `disconnect.sh`

Kills `zconnect-gost` on the phone and removes the port forward. It leaves the
desktop's own networking untouched.

### `status.sh`

Emits `key=value` lines. Quick mode only inspects `adb` state, the forward, and
the phone-side process. `--full` additionally makes one request through the
proxy to confirm end-to-end connectivity and retrieve the phone's egress IP.

The script deliberately exits 0 even when the phone is missing, because the bar
widget polls it.

### Omarchy widget

The widget is a single `Panel.qml` registered as a bar widget. It:

- renders the phone icon and state dot;
- runs `status.sh` every 60 seconds when closed and every 15 seconds when open;
- runs `connect.sh` / `disconnect.sh` as child processes;
- shows the latest error output if an action fails;
- exposes IPC methods (`open`, `close`, `toggle`, `connect`, `disconnect`,
  `refresh`, `status`) so it can be driven by a hotkey.

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

## 7. Lifecycle and persistence

| Event | What survives | What breaks |
| --- | --- | --- |
| Desktop reboot | Phone-side gost may still run; `bin/` files | `adb` server and forward are gone |
| Unplug/replug phone | Phone-side gost may still run | `adb` forward is gone |
| Phone reboot | Nothing on the phone side | `gost` process and forward are gone |
| `disconnect.sh` | Binaries and scripts | gost process and forward are gone |
| `adb kill-server` | Phone-side gost | Forward is gone |

In all cases, run `./connect.sh` again. It re-pushes gost only if missing and
recreates the forward.

---

## 8. Security analysis

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
sharing a screenshot.

---

## 9. Alternatives considered

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

Useful for system-wide routing, but requires root and more moving parts. The
SOCKS5 proxy is enough for browsers and most CLI tools, and it can be combined
with these tools later if system-wide routing is needed.

### SSH reverse tunnel

Could provide a SOCKS proxy, but requires an SSH server on the phone (not
standard on Android) and more setup. `gost` + `adb` is lighter.

---

## 10. Design trade-offs

| Choice | Benefit | Cost |
| --- | --- | --- |
| SOCKS5 instead of a TUN device | No root; simple; works with common apps | Per-app configuration; not system-wide |
| gost on the phone | Avoids tethering stack; static binary | Must match phone ABI; process must be started over ADB |
| `adb forward` | No extra network listener; USB-only | Forward does not survive unplug/reboot |
| Remote DNS | Works with no desktop DNS | Requires `socks5h`-aware clients |
| Explicit resolver list | Reliable on Android | Needs auto-detection or manual override on unusual networks |
| Omarchy widget | One-click connect/disconnect | Optional; tied to Omarchy/Quickshell |

---

## 11. Failure modes and diagnostics

| Failure | Where to look |
| --- | --- |
| Phone not seen | `adb devices`, cable, USB debugging authorization |
| gost not starting | `adb shell cat /data/local/tmp/zconnect-gost.log` |
| Wrong binary format | `file bin/gost`; use the correct ABI asset |
| Port conflict | `ss -ltnp | grep 1080`; change `ZCONNECT_PORT` |
| Proxy up, DNS fails | Set `ZCONNECT_DNS`; test with `curl --socks5-hostname` |
| Proxy up, phone has no data | Check mobile data toggle and signal |
| Browser ignores proxy | Use `chromium-zconnect.sh` or configure the app explicitly |

More detail: [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

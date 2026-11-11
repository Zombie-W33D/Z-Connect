# Troubleshooting

Start with the three most useful commands:

```bash
adb devices
adb shell pidof zconnect-gost
adb shell cat /data/local/tmp/zconnect-gost.log
```

Then check the forward and the local port:

```bash
adb forward --list
ss -ltnp | grep 1080
```

For a full end-to-end check:

```bash
cd ~/.local/share/z-connect
./status.sh --full
```

---

## The phone is not detected

Symptoms:

```text
error: no phone detected. Check the USB cable and that USB debugging is on.
```

Checks:

1. Use a data cable, not a charge-only cable.
2. Unlock the phone.
3. Enable **Developer options → USB debugging**.
4. Accept the **Allow USB debugging?** prompt.
5. Try `adb devices` directly.

Expected:

```text
List of devices attached
<serial>    device
```

If it says `unauthorized`, unlock the phone and accept the prompt. If it says
`offline`, replug the cable or run `adb kill-server` and try again.

If `adb` is not found, run `./fetch-deps.sh`, or install platform-tools through
your distribution and make sure `adb` is in `PATH`.

---

## gost is missing or will not start

If `connect.sh` says:

```text
error: gost not found at .../bin/gost
```

run:

```bash
./fetch-deps.sh
```

If the proxy starts but every request fails, read the phone-side log:

```bash
adb shell cat /data/local/tmp/zconnect-gost.log
```

Common messages:

- `exec format error` — the binary is for the wrong CPU architecture. Download
  the correct asset with `GOST_ASSET=... ./fetch-deps.sh --force`.
- `address already in use` — another process is using the port on the phone.
  Kill it with `adb shell pkill -f zconnect-gost`, or change
  `ZCONNECT_PORT`.
- `permission denied` — the binary was pushed without the executable bit.
  `connect.sh` normally handles this; run
  `adb shell chmod 755 /data/local/tmp/zconnect-gost`.

---

## The proxy is up but names do not resolve

Symptoms:

- `curl` to an IP works, but `https://example.com` fails.
- The browser shows DNS errors.
- `status.sh --full` reports `proxy=no`.

Causes and fixes:

1. **The client is resolving names locally.** Use `socks5h://` or
   `curl --socks5-hostname`. A plain `socks5://` URL may resolve on the desktop.
2. **The phone's DNS is not reachable.** Try explicit resolvers:

   ```bash
   ZCONNECT_DNS="9.9.9.9:53,1.1.1.1:53" ./connect.sh
   ```

3. **IPv6-only network.** The auto-detector currently reads IPv4 DNS. Set
   `ZCONNECT_DNS` manually to a reachable resolver.

Check what the phone sees:

```bash
adb shell dumpsys connectivity | grep DnsAddresses
```

---

## Port 1080 is already in use

Symptoms:

```text
adb: error: cannot bind listener: Address already in use
```

Find the local listener:

```bash
ss -ltnp | grep 1080
```

Either stop that process or use another port:

```bash
ZCONNECT_PORT=1081 ./connect.sh
```

If you change the port, use the same value for clients:

```bash
curl --socks5-hostname 127.0.0.1:1081 https://api.ipify.org
export ZCONNECT_PORT=1081
source ./env.sh
```

---

## Connected, but the browser still uses the normal connection

First check whether the system proxy is on:

```bash
cd ~/.local/share/z-connect
./proxy.sh status
gsettings get org.gnome.system.proxy mode
gsettings get org.gnome.system.proxy.socks host
gsettings get org.gnome.system.proxy.socks port
```

If `system_proxy=on` but the browser was already open, **restart the browser**.
Already-running apps keep the environment they started with. New apps launched
after the proxy is enabled inherit `SOCKS_SERVER`/`SOCKS_VERSION`.

If the browser still ignores it, use the included launcher:

```bash
./chromium-zconnect.sh
./brave-zconnect.sh
```

Or configure the application's proxy setting manually to
`socks5://127.0.0.1:1080` (or `socks5h://` if the app supports remote DNS).

Do **not** launch Brave/Chromium from a shell that has `env.sh` sourced. That
sets the traditional `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` variables, which
Chromium interprets as HTTP proxies and fails against the SOCKS5 relay. Use the
system proxy or the launcher for browsers.

Use a test that definitely honors the proxy:

```bash
curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```

If that `curl` works, the tunnel is fine and the problem is the app's proxy
configuration.

---

## No internet after unplugging the phone (stale system proxy)

If the desktop cannot reach the internet after the phone is gone, the system
proxy may still be pointing at the dead tunnel. Restore it:

```bash
cd ~/.local/share/z-connect
./proxy.sh cleanup
# or force it:
./proxy.sh disable
```

`cleanup` only acts when the tunnel is down, so it is safe to run at any time.
`disable` restores the saved settings unconditionally.

Check the result:

```bash
./proxy.sh status
gsettings get org.gnome.system.proxy mode
```

The panel does this automatically when it sees `system_proxy_managed=yes` while
the tunnel is down. If it does not, open the panel and press **Refresh**, or run
the commands above.

---

## The System proxy toggle is greyed out

The toggle is disabled until the tunnel is up. Connect first. If the tunnel is
up but the toggle stays disabled, refresh the panel or run:

```bash
./status.sh --quick
```

Look for `forward=yes` and a non-empty `gost_pid`. If either is missing, the
panel does not consider the tunnel usable.

If `system_proxy_error` is non-empty, the desktop could not read or write the
GNOME proxy settings. The environment part may still work for Chromium, but
install `gsettings`/`dconf` or use the browser launcher on a non-GNOME desktop.

---

## The bar widget does not appear

Check that the plugin is enabled and in the bar layout:

```bash
omarchy plugin list | grep zconnect
```

Enable and place it:

```bash
omarchy plugin enable zconnect.phone-tether --section right
omarchy bar move zconnect.phone-tether --after omarchy.network
```

If the panel opens but says **adb missing**, the widget's `scriptDir` does not
contain the scripts. The default is `~/.local/share/z-connect`. Install there,
or set the widget's `scriptDir` setting to the directory containing
`connect.sh`, `disconnect.sh`, and `status.sh`.

If the widget shows **Ready** but Connect fails, run the command manually to see
the full error:

```bash
~/.local/share/z-connect/connect.sh
```

---

## The tunnel works, then stops after unplugging the phone

Expected. `adb forward` is tied to the USB connection. Replug the phone and run
`./connect.sh` again. The phone-side binary stays in `/data/local/tmp`, so it
does not need to be re-pushed.

If the phone rebooted, the process is gone too; `connect.sh` starts it again.

---

## Everything works, but I need system-wide routing

Z-Connect includes a user-level system proxy for GNOME/GIO apps and
Chromium-based apps, but it is not a VPN. To route every packet on the desktop,
including apps that ignore proxy settings, you need root and a TUN device or
transparent proxy. Options include `tun2socks` or `redsocks` + iptables. That is
outside the scope of this project.

---

## Collecting logs for a bug report

```bash
cd ~/.local/share/z-connect
./status.sh --full
./proxy.sh status
gsettings get org.gnome.system.proxy mode
gsettings get org.gnome.system.proxy.socks host
gsettings get org.gnome.system.proxy.socks port
adb devices
adb forward --list
adb shell cat /data/local/tmp/zconnect-gost.log
```

Before posting logs publicly, remove your device serial, carrier details, and
egress IP if you consider them private.

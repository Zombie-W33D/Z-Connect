# Troubleshooting

Start with the three most useful commands:

```bash
adb devices
adb shell pidof zconnect-gost
adb shell cat /data/local/tmp/zconnect-gost.log
```

Then check the forward, the relay, and the local ports:

```bash
adb forward --list
./relay.sh status
ss -ltnp | grep -E '1080|1081'
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

## Port 1080 or 1081 is already in use

Symptoms:

```text
adb: error: cannot bind listener: Address already in use
error: port 1080 is already in use.
```

Find the local listeners:

```bash
ss -ltnp | grep -E '1080|1081'
```

The relay owns `1080`; the `adb` forward and the phone-side `gost` own `1081`.
Stop whatever else is using those ports, or move Z-Connect:

```bash
ZCONNECT_PORT=1082 ZCONNECT_PHONE_PORT=1083 ./connect.sh
```

If you change the ports, use the same relay port for clients:

```bash
curl --socks5-hostname 127.0.0.1:1082 https://api.ipify.org
export ZCONNECT_PORT=1082
source ./env.sh
```

`ZCONNECT_PHONE_PORT` defaults to the relay port plus one.

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

If `system_proxy=on` but the browser was already open, **restart the browser
once**. Already-running apps keep the environment they started with. After that
restart the browser points at the stable relay and switches routes without
another restart. New apps launched after the proxy is enabled inherit
`SOCKS_SERVER`/`SOCKS_VERSION` immediately.

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

## The relay is in Direct mode while the phone is connected

Check the pieces:

```bash
cd ~/.local/share/z-connect
./relay.sh status
./status.sh --quick
./relay.sh log
```

`status.sh` should show `forward=yes` and a non-empty `gost_pid`. If it does,
put the relay back in phone mode:

```bash
./relay.sh mode phone
curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
```

If that prints the desktop's normal public IP instead of the phone's, the relay
is still falling back. The log will contain `phone upstream unavailable`. Check
the phone-side proxy directly:

```bash
curl --socks5-hostname 127.0.0.1:1081 https://api.ipify.org
```

If the `1081` test fails, the phone side is down; press Connect or rerun
`./connect.sh`. If `1081` works but `1080` still falls back, restart the relay:

```bash
./relay.sh restart
./relay.sh mode phone
```

`./relay.sh ensure` starts the relay without changing the mode. The relay is
optional for basic use, but the system proxy and live switching depend on it.

---

## The relay will not start

Symptoms:

```text
error: python3 is required for the relay.
error: relay.py not found next to relay.sh.
error: the relay exited during startup.
```

Fixes:

- install Python 3 (`python3 --version`);
- reinstall the scripts, or copy `relay.py` next to `relay.sh`;
- free the relay port, or set `ZCONNECT_PORT`;
- read `~/.local/state/zconnect/relay.log`.

You can run the relay by hand to see errors directly:

```bash
cd ~/.local/share/z-connect
python3 relay.py --listen 127.0.0.1:1080 --upstream 127.0.0.1:1081 \
  --mode-file ~/.local/state/zconnect/relay-mode
```

To make the relay fail instead of falling back to the normal network when the
phone is unreachable, start it with `--no-fallback-direct` or set
`ZCONNECT_RELAY_FALLBACK_DIRECT=0` before `./relay.sh start`.

---

## No internet after unplugging the phone (stale system proxy)

If the desktop cannot reach the internet after the phone is gone, the system
proxy may still be pointing at the dead tunnel. The relay should already be in
direct mode, so apps using it fall back automatically. Restore the proxy
settings as well:

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
./relay.sh status
gsettings get org.gnome.system.proxy mode
```

`proxy.sh disable` and `cleanup` both put the relay in direct mode. The panel
does this automatically when it sees `system_proxy_managed=yes` while the tunnel
is down. If it does not, open the panel and press **Refresh**, or run the
commands above.

---

## The System proxy toggle is greyed out

The toggle is disabled until the tunnel is up. Connect first. If the tunnel is
up but the toggle stays disabled, refresh the panel or run:

```bash
./status.sh --quick
```

Look for `forward=yes` and a non-empty `gost_pid`. If either is missing, the
panel does not consider the tunnel usable. Also check that `relay_running=yes`;
the system proxy points at the relay, not directly at the phone.

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
`connect.sh`, `disconnect.sh`, `status.sh`, `proxy.sh`, `relay.sh`, and
`relay.py`.

If the widget shows **Ready** but Connect fails, run the command manually to see
the full error:

```bash
~/.local/share/z-connect/connect.sh
```

---

## The tunnel works, then stops after unplugging the phone

Expected. `adb forward` is tied to the USB connection. The relay notices that the
phone upstream is gone and switches new connections to the normal network, so
apps that use it keep working. The phone-side binary stays in
`/data/local/tmp`, so it does not need to be re-pushed.

Replug the phone and run `./connect.sh` again. It recreates the forward and puts
the relay back in phone mode; open apps switch back on their next connection.

If the phone rebooted, the process is gone too; `connect.sh` starts it again.

---

## Everything works, but I need system-wide routing

Z-Connect includes a user-level system proxy for GNOME/GIO apps and
Chromium-based apps, plus a stable relay that lets open apps switch routes
without a restart. It is still not a VPN. To route every packet on the desktop,
including apps that ignore proxy settings, you need root and a TUN device or
transparent proxy. Options include `tun2socks` or `redsocks` + iptables. That is
outside the scope of this project.

The relay is also TCP-only. It rejects UDP `ASSOCIATE`, so apps that require UDP
through the tunnel will not work through it.

---

## Collecting logs for a bug report

```bash
cd ~/.local/share/z-connect
./status.sh --full
./proxy.sh status
./relay.sh status
./relay.sh log
gsettings get org.gnome.system.proxy mode
gsettings get org.gnome.system.proxy.socks host
gsettings get org.gnome.system.proxy.socks port
adb devices
adb forward --list
adb shell cat /data/local/tmp/zconnect-gost.log
```

Before posting logs publicly, remove your device serial, carrier details, and
egress IP if you consider them private.

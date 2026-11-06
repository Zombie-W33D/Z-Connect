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

Not every application honors proxy variables. Options:

- Use the included launcher:

  ```bash
  ./chromium-zconnect.sh
  ./brave-zconnect.sh
  ```

- Configure the application's proxy setting manually to
  `socks5://127.0.0.1:1080` (or `socks5h://` if the app supports remote DNS).

- Use a test that definitely honors the proxy:

  ```bash
  curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
  ```

If that `curl` works, the tunnel is fine and the problem is the app's proxy
configuration.

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

Z-Connect is a SOCKS5 proxy, not a VPN. To route the entire desktop, you need
root and a TUN device or transparent proxy. Options include `tun2socks` or
`redsocks` + iptables. That is outside the scope of this project.

---

## Collecting logs for a bug report

```bash
cd ~/.local/share/z-connect
./status.sh --full
adb devices
adb forward --list
adb shell cat /data/local/tmp/zconnect-gost.log
```

Before posting logs publicly, remove your device serial, carrier details, and
egress IP if you consider them private.

# Binary dependencies

`Z-Connect` uses three binaries that are intentionally **not committed** to this
repository:

| File | Purpose | Where it comes from |
| --- | --- | --- |
| `bin/adb` | Android Debug Bridge on the desktop | [Android platform-tools](https://developer.android.com/tools/releases/platform-tools) |
| `bin/gost` | SOCKS5 proxy pushed to the phone (TCP + UDP) | [go-gost/gost releases](https://github.com/go-gost/gost/releases) |
| `bin/gost-desktop` | Desktop gost used by the optional TUN helper | [go-gost/gost releases](https://github.com/go-gost/gost/releases) |

Run this once after cloning:

```bash
./fetch-deps.sh
```

The script downloads platform-tools, extracts `adb`, downloads the pinned gost
release for ARM64 Android and for this desktop's architecture, verifies every
SHA-256 checksum, and places the files in this directory.

## Different phone architecture

The default phone gost asset is `linux_arm64`, which covers almost all modern
Android phones. For a 32-bit ARM phone or an emulator, override the asset:

```bash
GOST_PHONE_ASSET=gost_3.3.3_linux_armv7.tar.gz ./fetch-deps.sh --force
```

The desktop binary is selected automatically from `uname -m`. Override it with
`GOST_DESKTOP_ASSET` if needed.

## Using system adb

If `adb` is already installed and in `PATH`, the scripts use it automatically.
`bin/adb` is only a fallback.

## Why a desktop gost?

The optional mandatory-routing mode (`install.sh --privileged`) runs gost as a
root-owned userspace TUN service. That process cannot use the phone copy, so a second
binary for the desktop architecture is installed to
`/usr/local/libexec/zconnect-gost`.

# Binary dependencies

`Z-Connect` uses two binaries that are intentionally **not committed** to this
repository:

| File | Purpose | Where it comes from |
| --- | --- | --- |
| `bin/adb` | Android Debug Bridge on the desktop | [Android platform-tools](https://developer.android.com/tools/releases/platform-tools) |
| `bin/gost` | SOCKS5 proxy pushed to the phone | [go-gost/gost releases](https://github.com/go-gost/gost/releases) |

Run this once after cloning:

```bash
./fetch-deps.sh
```

The script downloads platform-tools, extracts `adb`, downloads the pinned gost
release for ARM64 Android, verifies its SHA-256 checksum, and places both files
in this directory.

## Different phone architecture

The default gost asset is `linux_arm64`, which covers almost all modern Android
phones. For a 32-bit ARM phone or an emulator, override the asset:

```bash
GOST_ASSET=gost_3.3.3_linux_armv7.tar.gz ./fetch-deps.sh --force
```

## Using system adb

If `adb` is already installed and in `PATH`, the scripts use it automatically.
`bin/adb` is only a fallback.

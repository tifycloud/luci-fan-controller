# luci-fan-controller

OpenWrt/Kwrt fan control for Xiaomi AX9000 and AX9000 Darkyun routers with an
EMC2301/EMC2305-compatible hwmon device.

The repository contains two independent OpenWrt packages:

- `controller/` — `ax9000-fan-control` 1.0.0-r4, a shell-only, procd-managed,
  fail-safe temperature controller.
- `luci/` — `luci-app-ax9000-fan` 1.0.0-r1, the LuCI status and configuration
  interface.

No router credentials, configuration backups, calibration data, compiled IPK
files, or machine-specific build artifacts are included.

## Safety model

This software controls cooling hardware. It accepts only
`xiaomi,ax9000` and `xiaomi,ax9000-darkyun`. Before automatic control starts,
the controller validates the real I2C client identity, required register
values, a PWM 255 write/readback, and positive fan RPM. Invalid configuration,
missing sensors, write failures, zero RPM, signals, and process exit all use
the full-speed fail-safe path.

Do not force-install mismatched kernel modules. `PKGARCH:=all` describes these
two script/data packages only; their `kmod-*` dependencies must match the exact
firmware kernel ABI and feeds.

## Repository layout

```text
controller/   OpenWrt core package and runtime scripts
luci/         LuCI package, view, menu and rpcd ACL
installer/    optional local IPK install/uninstall helper
scripts/      reproducible SDK builder and IPK inspector
tests/        hardware-fixture and LuCI static tests
docs/         build, implementation and safety notes
```

## Test

```sh
make test
```

The tests run without router hardware by using a temporary sysfs fixture. If
Node.js and ShellCheck are installed, JavaScript and shell checks run too.

## Build IPK packages

The reproducible builder uses Docker and the pinned official OpenWrt 25.12.5
qualcommax/ipq807x SDK:

```sh
make ipk
make inspect
```

Artifacts are written to `dist/`, which is intentionally ignored by Git. The
builder never connects to or installs anything on a router.

For a firmware-native build, copy the two source directories into a matching
OpenWrt/Kwrt tree:

```sh
cp -a controller /path/to/openwrt/package/ax9000-fan-control
cp -a luci /path/to/openwrt/package/luci-app-ax9000-fan
make -C /path/to/openwrt package/ax9000-fan-control/compile V=s
make -C /path/to/openwrt package/luci-app-ax9000-fan/compile V=s
```

Use the target firmware's own SDK, kernel ABI and feeds. See
[`docs/BUILD.md`](docs/BUILD.md) for the complete compatibility boundary.

## Installation

Install the core package first, then the LuCI package:

```sh
opkg install ax9000-fan-control_1.0.0-r4_all.ipk
opkg install luci-app-ax9000-fan_1.0.0-r1_all.ipk
```

Do not use `--force-depends`. Perform the first installation over a wired
maintenance connection and verify temperature, PWM and RPM before leaving the
router unattended.

## License

MIT. See [`LICENSE`](LICENSE).

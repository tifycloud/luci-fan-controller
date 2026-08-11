# AX9000 fan-control core and installer

The `ax9000-fan-control` OpenWrt package is intentionally board-specific. Its
pre-install hook accepts only `xiaomi,ax9000` and `xiaomi,ax9000-darkyun`; an
unknown board fails closed. The package is shell-only (`PKGARCH:=all`) and can
be emitted by either an ipk or apk OpenWrt toolchain. Runtime dependencies are
`i2c-tools`, `kmod-hwmon-emc2305`, `kmod-hwmon-core`, `kmod-thermal`,
`kmod-i2c-core`, and `kmod-regmap-i2c`.

Core release r4 removes procd stdout/stderr capture from the supervised
instance. The service already sends diagnostics through `logger`; leaving
capture disabled avoids target-specific `libsetlbf.so` preload behavior that
can break controller initialization or the full-speed safety write. The named
procd instance and r3 dynamic-controller/readback gates remain unchanged.

`/etc/config/ax9000-fan` contains the safe defaults:

```text
enabled=1, poll_seconds=5, hysteresis_c=3
temp_warm=55, temp_hot=62, temp_max=70
pwm_cool=110, pwm_warm=160, pwm_hot=210, pwm_max=255
zero_rpm_limit=3
```

The validator rejects non-integers, out-of-range values, non-monotonic
temperature/PWM thresholds, threshold gaps smaller than hysteresis, and any
`pwm_max` other than 255. Invalid configuration drives the hardware to full
speed and prevents the control loop from starting.

The procd service first discovers an already-bound `emc2305` hwmon node and
derives its I2C bus from the resolved `/sys/devices/i2c-<bus>/<bus>-002f`
client path. The client name must be `emc2301` or `emc2305`; arbitrary hwmon
links, non-I2C parents, and addresses other than `0x2f` are rejected. Only if
no controller is bound does it use the fixed `i2c-0/0x2f` fallback. Before the
control loop starts, required controller registers are read back exactly,
PWM 255 is written and read back, and RPM must be numeric and positive. A
bound controller whose registers are already correct is not written again.
Missing sensors, failed writes or readback, zero tachometer samples, signal
handling, and process exit all attempt a full-speed write. A controller or
tachometer that is not ready during boot is retried inside the supervised
process; later runtime loss still exits through the fail-safe path so procd can
respawn it. Disabled automatic control keeps a small supervised loop that
continuously verifies PWM 255 instead of stopping fan protection.

LuCI should consume only `/usr/libexec/ax9000-fan-status`. It emits one stable
JSON object with `service_running`, `enabled`, `fan_found`, `rpm`, `fault`,
`pwm`, `max_temp_mC`, `max_temp_source`, `profile`, `thresholds`, and `error`.
Missing numeric values are JSON `null`; the helper returns a non-zero status on
fault while still printing valid JSON.

## Installer

`installer/install-ax9000-fan.sh` requires a supported board and detects the
target architecture plus `apk` or `opkg`. Install from `--package-dir DIR` or
from an explicit `--release-url https://...`; release downloads and explicit
LuCI URLs require HTTPS and SHA-256 verification. The core package is always
installed before an optional `luci-app-ax9000-fan` package. If the LuCI install
fails after a new core install, the core is rolled back. `--dry-run` validates
the plan without changing the target. Remote downloads require curl or GNU
Wget so every redirect can be constrained to HTTPS; systems with only
uclient-fetch must use the verified local-package path.

`--uninstall` first stops the controller, then invokes the installed full-speed
helper and verifies PWM 255 before removing LuCI and core packages. User configuration remains unless
`--purge` is explicitly supplied. No credentials or other secrets are read or
embedded by the scripts.

Run the fixture suite from this directory:

```sh
tests/test-core.sh
```

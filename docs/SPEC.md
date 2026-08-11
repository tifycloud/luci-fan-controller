# AX9000 Fan Controller Plugin Specification

## Objective

Turn the proven Xiaomi AX9000 fan-control workaround into a reusable OpenWrt component with a LuCI interface and a safe installer for later systems.

## Supported systems

- Board identifiers: `xiaomi,ax9000` and `xiaomi,ax9000-darkyun` only.
- OpenWrt-family systems using either APK or OPKG package management.
- The installer must fail closed on unsupported boards, missing checksums, non-HTTPS remote sources, or unavailable dependencies.

## Core package

- Package name: `ax9000-fan-control`.
- Discover an already-bound `emc2301`/`emc2305` hwmon client at its resolved
  `/sys/devices/i2c-<bus>/<bus>-002f` path and derive the live I2C bus. Require
  the client name to be exact and reject non-I2C paths, mismatched parent buses,
  and addresses other than `0x2f`. Only when no controller is bound may the
  service instantiate the fixed I2C bus 0, address `0x2f` fallback.
- Before control starts, read back required controller registers exactly, write
  and read back PWM 255, and require a positive RPM sample. A preconfigured
  bound controller is not redundantly written; any failed write/readback or
  readiness check remains fail-closed at full speed.
- Use procd supervision and reload when `/etc/config/ax9000-fan` changes.
- Default profile:
  - poll every 5 seconds;
  - temperature thresholds 55, 62, and 70 degrees Celsius;
  - PWM levels 110, 160, 210, and 255;
  - 3-degree hysteresis;
  - treat three consecutive zero-RPM samples as a fault.
- Validate all values and reject unsafe or non-monotonic curves.
- On invalid configuration, missing temperature data, fan-control failure, zero RPM, termination, or uninstall, prefer full speed over silence.
- Expose a fixed no-argument JSON status command at `/usr/libexec/ax9000-fan-status`.

## LuCI package

- Package name: `luci-app-ax9000-fan`; menu location `System -> AX9000 Fan`.
- Chinese-first, lightweight, responsive UI with no external assets or large libraries.
- Show service state, RPM, maximum temperature, PWM, controller discovery, and fault state with a five-second refresh.
- Provide grouped configuration for temperature curve, PWM output, polling, hysteresis, and zero-RPM protection.
- Validate ranges and ordering before save; applying configuration must reload the controller through the normal UCI/procd path.
- Use least-privilege rpcd ACL and execute only the fixed status helper. Do not expose arbitrary shell execution or direct PWM actions.

## Installer and removal

- Detect board, architecture, package manager, and matching package artifact.
- Support a local package directory and an explicit HTTPS release URL.
- Require SHA256 verification and provide a no-side-effect `--dry-run` mode.
- Install the core before LuCI and roll back a partial installation when possible.
- Removal must force full speed first. Preserve configuration by default; remove it only with explicit purge.

## Verification

- Shell syntax and ShellCheck where available.
- Mock-sysfs tests for curve selection, hysteresis, missing sensors, zero RPM, invalid configuration, JSON status, and installer safety gates.
- Static LuCI checks for menu, ACL, fields, validation, fixed helper execution, Chinese labels, and absence of dangerous commands.
- Build at least the OpenWrt 25.12 APK artifacts in a Linux/amd64 toolchain, inspect their contents, and document the legacy IPK build path.
- Do not install the development build on the current production router without a separate explicit request.

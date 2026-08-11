# Changelog

## Controller 1.0.0-r4 / LuCI 1.0.0-r1

- Dynamically discovers an already-bound EMC2301/EMC2305 controller on the
  real I2C topology instead of assuming only bus 0.
- Validates controller identity, register readback, PWM 255 readback, and a
  positive RPM before entering automatic control.
- Keeps fail-safe full speed on invalid configuration, missing sensors,
  failed writes, zero RPM, signals, and process exit.
- Uses a named procd instance and avoids target-specific stdout/stderr capture
  preload behavior.
- Provides a read-only LuCI status dashboard and constrained configuration UI.

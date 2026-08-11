# Security policy

This project controls physical cooling hardware. Treat every change to PWM,
sensor discovery, process supervision, and package lifecycle hooks as a safety
change.

- Do not bypass the supported-board check.
- Do not lower or remove the PWM 255 fail-safe path.
- Do not force-install kernel modules from a different firmware build.
- Test installation through a wired maintenance connection with rollback
  access available.

Please report security or hardware-safety issues privately to the repository
maintainer before opening a public issue. Do not include router passwords,
configuration backups, wireless credentials, or calibration data in reports.

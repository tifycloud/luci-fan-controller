#!/bin/sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
COMMON=$ROOT/controller/files/usr/libexec/ax9000-fan-common
STATUS=$ROOT/controller/files/usr/libexec/ax9000-fan-status
VALIDATE=$ROOT/controller/files/usr/libexec/ax9000-fan-validate
DAEMON=$ROOT/controller/files/usr/sbin/ax9000-fan-control
INSTALLER=$ROOT/installer/install-ax9000-fan.sh

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ax9000-fan-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }
assert_eq() {
	description=$1
	expected=$2
	actual=$3
	if [ "$expected" = "$actual" ]; then pass "$description"; else fail "$description (expected '$expected', got '$actual')"; fi
}

SYSFS=$TMP/sys
RUNTIME=$TMP/run
CONFIG=$TMP/ax9000-fan
mkdir -p "$SYSFS/class/hwmon/hwmon0" "$SYSFS/class/thermal/thermal_zone0" "$RUNTIME"
printf '%s\n' emc2305 > "$SYSFS/class/hwmon/hwmon0/name"
printf '%s\n' 110 > "$SYSFS/class/hwmon/hwmon0/pwm1"
printf '%s\n' 1200 > "$SYSFS/class/hwmon/hwmon0/fan1_input"
cat > "$CONFIG" <<'EOF'
config ax9000_fan 'main'
	option enabled '1'
	option poll_seconds '1'
	option hysteresis_c '3'
	option temp_warm '55'
	option temp_hot '62'
	option temp_max '70'
	option pwm_cool '110'
	option pwm_warm '160'
	option pwm_hot '210'
	option pwm_max '255'
	option zero_rpm_limit '3'
EOF
printf '%s\n' 56000 > "$SYSFS/class/thermal/thermal_zone0/temp"

COMMON_ENV="AX9000_COMMON=$COMMON AX9000_SYSFS_ROOT=$SYSFS AX9000_CONFIG_FILE=$CONFIG AX9000_RUNTIME_DIR=$RUNTIME AX9000_PIDFILE=$RUNTIME/pid AX9000_PROFILE_FILE=$RUNTIME/profile AX9000_FAULT_FILE=$RUNTIME/fault AX9000_BOARD=xiaomi,ax9000 AX9000_SKIP_DEVICE_IDENTITY=1"

# shellcheck disable=SC2086
if env $COMMON_ENV sh -c '. "$AX9000_COMMON"; ax9000_load_config'; then
	pass 'default configuration validates'
else
	fail 'default configuration validates'
fi

# shellcheck disable=SC2086
profile=$(env $COMMON_ENV sh -c '. "$AX9000_COMMON"; ax9000_load_config; AX9000_LAST_PROFILE=cool; ax9000_select_profile 55000; printf "%s " "$AX9000_LAST_PROFILE"; ax9000_select_profile 52000; printf "%s " "$AX9000_LAST_PROFILE"; ax9000_select_profile 51000; printf "%s " "$AX9000_LAST_PROFILE"; ax9000_select_profile 62000; printf "%s " "$AX9000_LAST_PROFILE"; ax9000_select_profile 59000; printf "%s " "$AX9000_LAST_PROFILE"; ax9000_select_profile 58000; printf "%s " "$AX9000_LAST_PROFILE"; ax9000_select_profile 70000; printf "%s " "$AX9000_LAST_PROFILE"; ax9000_select_profile 67000; printf "%s " "$AX9000_LAST_PROFILE"; ax9000_select_profile 66000; printf "%s\n" "$AX9000_LAST_PROFILE"')
assert_eq '3 C hysteresis profile transitions' 'warm warm cool hot hot warm max max hot' "$profile"

BAD_CONFIG=$TMP/bad-config
sed "s/option pwm_max '255'/option pwm_max '200'/" "$CONFIG" > "$BAD_CONFIG"
# shellcheck disable=SC2086
if env $COMMON_ENV AX9000_CONFIG_FILE="$BAD_CONFIG" sh -c '. "$AX9000_COMMON"; ax9000_load_config'; then
	fail 'dangerous pwm_max configuration is rejected'
else
	pass 'dangerous pwm_max configuration is rejected'
fi

LEADING_ZERO_CONFIG=$TMP/leading-zero-config
sed "s/option temp_warm '55'/option temp_warm '055'/" "$CONFIG" > "$LEADING_ZERO_CONFIG"
# shellcheck disable=SC2086
if env $COMMON_ENV AX9000_CONFIG_FILE="$LEADING_ZERO_CONFIG" sh -c '. "$AX9000_COMMON"; ax9000_load_config'; then
	fail 'leading-zero numeric configuration is rejected'
else
	pass 'leading-zero numeric configuration is rejected'
fi

EMPTY_CONFIG=$TMP/empty-config
sed "s/option pwm_cool '110'/option pwm_cool ''/" "$CONFIG" > "$EMPTY_CONFIG"
# shellcheck disable=SC2086
if env $COMMON_ENV AX9000_CONFIG_FILE="$EMPTY_CONFIG" sh -c '. "$AX9000_COMMON"; ax9000_load_config'; then
	fail 'explicit empty configuration is rejected'
else
	pass 'explicit empty configuration is rejected'
fi

STATUS_JSON=$TMP/status.json
# shellcheck disable=SC2086
if env $COMMON_ENV sh "$STATUS" > "$STATUS_JSON"; then
	if command -v python3 >/dev/null 2>&1 && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["fan_found"] is True and d["max_temp_mC"] == 56000 and d["profile"] == "warm" and d["fault"] is False' "$STATUS_JSON"; then
		pass 'status endpoint emits stable valid JSON'
	else
		if grep -q '"fan_found":true' "$STATUS_JSON" && grep -q '"max_temp_mC":56000' "$STATUS_JSON"; then pass 'status endpoint emits stable JSON'; else fail 'status endpoint emits stable JSON'; fi
	fi
else
	fail 'status endpoint emits stable valid JSON'
fi

# Regression fixture for the production screenshot: the kernel has already
# bound an emc2305 hwmon node (with readable PWM/RPM), but its device lives on
# a different I2C topology and the legacy hard-coded 0-002f path is absent.
# Identity checking must discover the bound controller instead of reporting
# controller_not_found while the fan is visibly usable.
DYNAMIC_DEVICE=$SYSFS/devices/i2c-3/3-002f
mkdir -p "$DYNAMIC_DEVICE"
printf '%s\n' emc2301 > "$DYNAMIC_DEVICE/name"
ln -s "$DYNAMIC_DEVICE" "$SYSFS/class/hwmon/hwmon0/device"
DYNAMIC_JSON=$TMP/dynamic-controller.json
# shellcheck disable=SC2086
if env $COMMON_ENV AX9000_SKIP_DEVICE_IDENTITY=0 sh "$STATUS" > "$DYNAMIC_JSON" 2>/dev/null && grep -q '"fan_found":true' "$DYNAMIC_JSON" && grep -q '"rpm":1200' "$DYNAMIC_JSON" && grep -q '"pwm":110' "$DYNAMIC_JSON"; then
	pass 'already-bound emc2305 is discovered when fixed 0-002f path is absent'
else
	fail 'already-bound emc2305 is discovered when fixed 0-002f path is absent'
fi

# Identity must be rejected when the resolved hwmon device is not the fixed
# EMC2301/2305 I2C client topology. Exercise the name, parent, and address
# gates independently in isolated sysfs roots so a valid node cannot mask a
# rejected candidate.
identity_reject() {
	identity_label=$1
	identity_relative_device=$2
	identity_name=$3
	identity_root=$TMP/identity-$identity_label
	identity_hwmon=$identity_root/class/hwmon/hwmon0
	identity_device=$identity_root/$identity_relative_device
	mkdir -p "$identity_hwmon" "$identity_device"
	printf '%s\n' emc2305 > "$identity_hwmon/name"
	printf '%s\n' 110 > "$identity_hwmon/pwm1"
	printf '%s\n' 1200 > "$identity_hwmon/fan1_input"
	if [ "$identity_name" != __missing__ ]; then
		printf '%s\n' "$identity_name" > "$identity_device/name"
	fi
	ln -s "$identity_device" "$identity_hwmon/device"
	# shellcheck disable=SC2086
	if env $COMMON_ENV AX9000_SYSFS_ROOT="$identity_root" AX9000_SKIP_DEVICE_IDENTITY=0 sh -c '. "$AX9000_COMMON"; ax9000_find_fan'; then
		fail "identity rejects $identity_label"
	else
		pass "identity rejects $identity_label"
	fi
}

identity_reject wrong-name devices/i2c-3/3-002f emc2300
identity_reject missing-name devices/i2c-3/3-002f __missing__
identity_reject non-i2c-parent devices/platform/3-002f emc2301
identity_reject mismatched-parent-bus devices/i2c-4/3-002f emc2301
identity_reject non-002f-address devices/i2c-3/3-002e emc2301

# The prepare path must likewise avoid writing a duplicate fixed-address
# instance when the kernel has already bound this controller elsewhere. A
# fake i2cset is used only to make any attempted bus choice observable.
NEW_DEVICE=$SYSFS/bus/i2c/devices/i2c-0/new_device
mkdir -p "${NEW_DEVICE%/*}"
: > "$NEW_DEVICE"
FAKE_I2C_BIN=$TMP/fake-i2c-bin
mkdir -p "$FAKE_I2C_BIN"
cat > "$FAKE_I2C_BIN/modprobe" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$FAKE_I2C_BIN/i2cget" <<'EOF'
#!/bin/sh
[ "${AX9000_I2CGET_MODE:-ok}" = error ] && exit 1
case "$5" in
	0x38) cat "$AX9000_I2C_REG38" ;;
	0x2b) cat "$AX9000_I2C_REG2B" ;;
	*) exit 1 ;;
esac
EOF
cat > "$FAKE_I2C_BIN/i2cset" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$AX9000_I2CSET_LOG"
[ "${AX9000_I2CSET_MODE:-ok}" = fail ] && exit 1
if [ "${AX9000_CREATE_FAN:-0}" = 1 ] && [ ! -e "$AX9000_SYSFS_ROOT/class/hwmon/hwmon0/name" ]; then
	mkdir -p "$AX9000_SYSFS_ROOT/class/hwmon/hwmon0"
	printf '%s\n' emc2305 > "$AX9000_SYSFS_ROOT/class/hwmon/hwmon0/name"
	printf '%s\n' 110 > "$AX9000_SYSFS_ROOT/class/hwmon/hwmon0/pwm1"
	printf '%s\n' 1200 > "$AX9000_SYSFS_ROOT/class/hwmon/hwmon0/fan1_input"
	ln -s "$AX9000_SYSFS_ROOT/bus/i2c/devices/0-002f" "$AX9000_SYSFS_ROOT/class/hwmon/hwmon0/device"
fi
case "$5:$6" in
	0x38:0x18) printf '%s\n' 0x18 > "$AX9000_I2C_REG38" ;;
	0x2b:0x01) printf '%s\n' 0x01 > "$AX9000_I2C_REG2B" ;;
	*) exit 1 ;;
esac
exit 0
EOF
chmod +x "$FAKE_I2C_BIN/modprobe" "$FAKE_I2C_BIN/i2cget" "$FAKE_I2C_BIN/i2cset"
I2CSET_LOG=$TMP/i2cset.log
I2C_REG38=$TMP/i2c-reg38
I2C_REG2B=$TMP/i2c-reg2b
printf '%s\n' 0x18 > "$I2C_REG38"
printf '%s\n' 0x01 > "$I2C_REG2B"
: > "$I2CSET_LOG"
# shellcheck disable=SC2086
if PATH="$FAKE_I2C_BIN:$PATH" AX9000_I2CSET_LOG="$I2CSET_LOG" AX9000_I2C_REG38="$I2C_REG38" AX9000_I2C_REG2B="$I2C_REG2B" AX9000_I2CSET_MODE=fail env $COMMON_ENV AX9000_SKIP_DEVICE_IDENTITY=0 AX9000_I2CGET_BIN=i2cget AX9000_I2CSET_BIN=i2cset sh -c '. "$AX9000_COMMON"; ax9000_prepare_controller'; then
	if [ ! -s "$NEW_DEVICE" ] && [ ! -s "$I2CSET_LOG" ]; then
		pass 'prepare path does not instantiate or configure a fixed bus for an existing controller'
	else
		fail 'prepare path does not instantiate or configure a fixed bus for an existing controller'
	fi
else
	fail 'prepare path accepts an existing controller on a non-default bus'
fi

# A mismatched bound controller must never be accepted on a failed or
# unverifiable register write/readback; the already-discovered fan stays at
# the verified full-speed value.
printf '%s\n' 0x00 > "$I2C_REG38"
printf '%s\n' 0x00 > "$I2C_REG2B"
: > "$I2CSET_LOG"
printf '%s\n' 110 > "$SYSFS/class/hwmon/hwmon0/pwm1"
# shellcheck disable=SC2086
if PATH="$FAKE_I2C_BIN:$PATH" AX9000_I2CSET_LOG="$I2CSET_LOG" AX9000_I2C_REG38="$I2C_REG38" AX9000_I2C_REG2B="$I2C_REG2B" AX9000_I2CSET_MODE=fail env $COMMON_ENV AX9000_SKIP_DEVICE_IDENTITY=0 AX9000_I2CGET_BIN=i2cget AX9000_I2CSET_BIN=i2cset AX9000_NO_SLEEP=1 sh -c '. "$AX9000_COMMON"; ax9000_prepare_controller'; then
	fail 'mismatched controller rejects a failed register write'
elif grep -q '^255$' "$SYSFS/class/hwmon/hwmon0/pwm1" && [ -s "$I2CSET_LOG" ]; then
	pass 'mismatched controller rejects a failed register write and holds full speed'
else
	fail 'mismatched controller rejects a failed register write and holds full speed'
fi

# Even successful writes cannot mask an i2cget/readback failure.
: > "$I2CSET_LOG"
printf '%s\n' 0x00 > "$I2C_REG38"
printf '%s\n' 0x00 > "$I2C_REG2B"
printf '%s\n' 110 > "$SYSFS/class/hwmon/hwmon0/pwm1"
# shellcheck disable=SC2086
if PATH="$FAKE_I2C_BIN:$PATH" AX9000_I2CSET_LOG="$I2CSET_LOG" AX9000_I2C_REG38="$I2C_REG38" AX9000_I2C_REG2B="$I2C_REG2B" AX9000_I2CGET_MODE=error AX9000_I2CSET_MODE=ok env $COMMON_ENV AX9000_SKIP_DEVICE_IDENTITY=0 AX9000_I2CGET_BIN=i2cget AX9000_I2CSET_BIN=i2cset AX9000_NO_SLEEP=1 sh -c '. "$AX9000_COMMON"; ax9000_prepare_controller'; then
	fail 'mismatched controller rejects an unverifiable register readback'
elif grep -q '^255$' "$SYSFS/class/hwmon/hwmon0/pwm1"; then
	pass 'mismatched controller rejects an unverifiable register readback and holds full speed'
else
	fail 'mismatched controller rejects an unverifiable register readback and holds full speed'
fi

# A mismatched controller may proceed only after both writes succeed and both
# registers read back the expected values.
: > "$I2CSET_LOG"
printf '%s\n' 0x00 > "$I2C_REG38"
printf '%s\n' 0x00 > "$I2C_REG2B"
printf '%s\n' 110 > "$SYSFS/class/hwmon/hwmon0/pwm1"
# shellcheck disable=SC2086
if PATH="$FAKE_I2C_BIN:$PATH" AX9000_I2CSET_LOG="$I2CSET_LOG" AX9000_I2C_REG38="$I2C_REG38" AX9000_I2C_REG2B="$I2C_REG2B" AX9000_I2CGET_MODE=ok AX9000_I2CSET_MODE=ok env $COMMON_ENV AX9000_SKIP_DEVICE_IDENTITY=0 AX9000_I2CGET_BIN=i2cget AX9000_I2CSET_BIN=i2cset AX9000_NO_SLEEP=1 sh -c '. "$AX9000_COMMON"; ax9000_prepare_controller'; then
	if grep -q '^255$' "$SYSFS/class/hwmon/hwmon0/pwm1" && grep -q '0x38 0x18' "$I2CSET_LOG" && grep -q '0x2b 0x01' "$I2CSET_LOG" && grep -q '^0x18$' "$I2C_REG38" && grep -q '^0x01$' "$I2C_REG2B"; then
		pass 'mismatched controller requires successful writes and exact readback'
	else
		fail 'mismatched controller requires successful writes and exact readback'
	fi
else
	fail 'mismatched controller accepts successful writes and exact readback'
fi

# When no hwmon controller is bound, a pre-existing fixed-address client can
# still be used as the fallback. The fake register writes create its hwmon
# node, then the same write/readback, PWM, and RPM gates must pass. Keeping the
# client directory/name pre-created makes this fixture deterministic without a
# FIFO racing the prepare path after new_device is written.
FALLBACK_SYSFS=$TMP/fallback-sys
FALLBACK_DEVICE=$FALLBACK_SYSFS/bus/i2c/devices/0-002f
FALLBACK_RESOLVED_DEVICE=$FALLBACK_SYSFS/devices/i2c-0/0-002f
FALLBACK_REG38=$TMP/fallback-reg38
FALLBACK_REG2B=$TMP/fallback-reg2b
FALLBACK_LOG=$TMP/fallback-i2cset.log
mkdir -p "$FALLBACK_RESOLVED_DEVICE" "$FALLBACK_SYSFS/bus/i2c/devices"
ln -s "$FALLBACK_RESOLVED_DEVICE" "$FALLBACK_DEVICE"
printf '%s\n' emc2301 > "$FALLBACK_RESOLVED_DEVICE/name"
printf '%s\n' 0x00 > "$FALLBACK_REG38"
printf '%s\n' 0x00 > "$FALLBACK_REG2B"
# shellcheck disable=SC2086
if PATH="$FAKE_I2C_BIN:$PATH" AX9000_I2CSET_LOG="$FALLBACK_LOG" AX9000_I2C_REG38="$FALLBACK_REG38" AX9000_I2C_REG2B="$FALLBACK_REG2B" AX9000_CREATE_FAN=1 env AX9000_SYSFS_ROOT="$FALLBACK_SYSFS" AX9000_COMMON="$COMMON" AX9000_SKIP_DEVICE_IDENTITY=0 AX9000_I2CGET_BIN=i2cget AX9000_I2CSET_BIN=i2cset AX9000_NO_SLEEP=1 sh -c '. "$AX9000_COMMON"; ax9000_prepare_controller'; then
	if grep -q '0x38 0x18' "$FALLBACK_LOG" && grep -q '0x2b 0x01' "$FALLBACK_LOG" && grep -q '^255$' "$FALLBACK_SYSFS/class/hwmon/hwmon0/pwm1" && grep -q '^0x18$' "$FALLBACK_REG38" && grep -q '^0x01$' "$FALLBACK_REG2B"; then
		pass 'absent controller uses fixed fallback with write/readback and full-speed gates'
	else
		fail 'absent controller uses fixed fallback with write/readback and full-speed gates'
	fi
else
	fail 'absent controller fallback preparation succeeds'
fi

# A zero tachometer is never a successful prepare, even when the controller
# registers are already configured; full speed remains asserted.
printf '%s\n' 0x18 > "$I2C_REG38"
printf '%s\n' 0x01 > "$I2C_REG2B"
printf '%s\n' 0 > "$SYSFS/class/hwmon/hwmon0/fan1_input"
printf '%s\n' 110 > "$SYSFS/class/hwmon/hwmon0/pwm1"
# shellcheck disable=SC2086
if PATH="$FAKE_I2C_BIN:$PATH" AX9000_I2CSET_LOG="$I2CSET_LOG" AX9000_I2C_REG38="$I2C_REG38" AX9000_I2C_REG2B="$I2C_REG2B" AX9000_I2CGET_MODE=ok AX9000_I2CSET_MODE=fail env $COMMON_ENV AX9000_SKIP_DEVICE_IDENTITY=0 AX9000_I2CGET_BIN=i2cget AX9000_I2CSET_BIN=i2cset AX9000_NO_SLEEP=1 sh -c '. "$AX9000_COMMON"; ax9000_prepare_controller'; then
	fail 'zero RPM is rejected during controller preparation'
elif grep -q '^255$' "$SYSFS/class/hwmon/hwmon0/pwm1"; then
	pass 'zero RPM is rejected during controller preparation and holds full speed'
else
	fail 'zero RPM is rejected during controller preparation and holds full speed'
fi

printf '%s\n' 1200 > "$SYSFS/class/hwmon/hwmon0/fan1_input"
printf '%s\n' 0x18 > "$I2C_REG38"
printf '%s\n' 0x01 > "$I2C_REG2B"
printf '%s\n' 110 > "$SYSFS/class/hwmon/hwmon0/pwm1"

# Cold but plausible readings must remain valid inputs instead of being
# mistaken for a missing sensor and forcing an unnecessary permanent 100% fan.
printf '%s\n' 5000 > "$SYSFS/class/thermal/thermal_zone0/temp"
COLD_JSON=$TMP/cold.json
# shellcheck disable=SC2086
if env $COMMON_ENV sh "$STATUS" > "$COLD_JSON" && grep -q '"max_temp_mC":5000' "$COLD_JSON"; then
	pass 'temperature below 10 C remains a valid sensor reading'
else
	fail 'temperature below 10 C remains a valid sensor reading'
fi
printf '%s\n' 56000 > "$SYSFS/class/thermal/thermal_zone0/temp"

# Disabled mode is supervised: a failed full-speed write is a visible fault,
# not a successful exit that silently leaves the previous low PWM value.
DISABLED_CONFIG=$TMP/disabled-config
sed "s/option enabled '1'/option enabled '0'/" "$CONFIG" > "$DISABLED_CONFIG"
printf '%s\n' 110 > "$SYSFS/class/hwmon/hwmon0/pwm1"
chmod 444 "$SYSFS/class/hwmon/hwmon0/pwm1"
# shellcheck disable=SC2086
env $COMMON_ENV AX9000_CONFIG_FILE="$DISABLED_CONFIG" AX9000_SKIP_CONTROLLER_INIT=1 AX9000_NO_SLEEP=1 AX9000_TEST_LOOPS=1 sh "$DAEMON" >/dev/null 2>&1
if grep -q '^disabled_fullspeed_error$' "$RUNTIME/fault" && grep -q '^110$' "$SYSFS/class/hwmon/hwmon0/pwm1"; then
	pass 'disabled mode reports an unverified full-speed fail-safe'
else
	fail 'disabled mode reports an unverified full-speed fail-safe'
fi
chmod 644 "$SYSFS/class/hwmon/hwmon0/pwm1"

# A controller/hwmon node that appears after procd starts must be discovered
# without a manual service restart.
mv "$SYSFS/class/hwmon/hwmon0" "$TMP/hwmon0.delayed"
( sleep 1; mv "$TMP/hwmon0.delayed" "$SYSFS/class/hwmon/hwmon0" ) &
delayed_pid=$!
# shellcheck disable=SC2086
env $COMMON_ENV AX9000_SKIP_CONTROLLER_INIT=1 AX9000_TEST_LOOPS=1 sh "$DAEMON" >/dev/null 2>&1; delayed_status=$?
wait "$delayed_pid"
if [ "$delayed_status" -eq 0 ] && [ -d "$SYSFS/class/hwmon/hwmon0" ]; then
	pass 'late hwmon discovery recovers without manual restart'
else
	fail 'late hwmon discovery recovers without manual restart'
fi

mv "$SYSFS/class/hwmon/hwmon0/fan1_input" "$SYSFS/class/hwmon/hwmon0/fan1_input.hidden"
NO_TACH_JSON=$TMP/no-tach.json
# shellcheck disable=SC2086
env $COMMON_ENV sh "$STATUS" > "$NO_TACH_JSON" 2>/dev/null; no_tach_status=$?
if [ "$no_tach_status" -ne 0 ] && grep -q '"fault":true' "$NO_TACH_JSON" && grep -q '"error":"tachometer_unavailable"' "$NO_TACH_JSON"; then
	pass 'missing tachometer is reported as a fault'
else
	fail 'missing tachometer is reported as a fault'
fi
mv "$SYSFS/class/hwmon/hwmon0/fan1_input.hidden" "$SYSFS/class/hwmon/hwmon0/fan1_input"

# Removing every valid temperature source is a fail-safe fault, not a crash
# that silently leaves the previous PWM.
rm -f "$SYSFS/class/thermal/thermal_zone0/temp"
NO_SENSOR_JSON=$TMP/no-sensor.json
# shellcheck disable=SC2086
env $COMMON_ENV sh "$STATUS" > "$NO_SENSOR_JSON" 2>/dev/null; no_sensor_status=$?
if [ "$no_sensor_status" -ne 0 ] && grep -q '"fault":true' "$NO_SENSOR_JSON" && grep -q '"error":"no_sensor"' "$NO_SENSOR_JSON"; then
	pass 'missing temperature sensor is reported as fault'
else
	fail 'missing temperature sensor is reported as fault'
fi

# Preserve the runtime zero-RPM fail-safe coverage: the first tachometer read
# is positive so prepare succeeds, then the running loop sees one zero sample.
printf '%s\n' 56000 > "$SYSFS/class/thermal/thermal_zone0/temp"
ZERO_CONFIG=$TMP/zero-config
sed "s/option zero_rpm_limit '3'/option zero_rpm_limit '1'/" "$CONFIG" > "$ZERO_CONFIG"
RPM_SED_BIN=$TMP/rpm-sed-bin
mkdir -p "$RPM_SED_BIN"
REAL_SED=$(command -v sed)
cat > "$RPM_SED_BIN/sed" <<EOF
#!/bin/sh
case "\${3:-}" in
  */fan1_input)
    count=\$(cat "\${AX9000_RPM_READ_COUNT:-/dev/null}" 2>/dev/null || printf '%s' 0)
    count=\$((count + 1))
    printf '%s\\n' "\$count" > "\${AX9000_RPM_READ_COUNT:-/tmp/ax9000-rpm-count}"
    if [ "\$count" -eq 1 ]; then printf '%s\\n' 1200; else printf '%s\\n' 0; fi
    exit 0
    ;;
esac
exec "$REAL_SED" "\$@"
EOF
chmod +x "$RPM_SED_BIN/sed"
RPM_READ_COUNT=$TMP/rpm-read-count
printf '%s\n' 0 > "$RPM_READ_COUNT"
rm -f "$RUNTIME/fault"
# shellcheck disable=SC2086
PATH="$RPM_SED_BIN:$PATH" env $COMMON_ENV AX9000_CONFIG_FILE="$ZERO_CONFIG" AX9000_SKIP_CONTROLLER_INIT=1 AX9000_NO_SLEEP=1 AX9000_TEST_LOOPS=1 AX9000_RPM_READ_COUNT="$RPM_READ_COUNT" perl -e '$SIG{ALRM}=sub{exit 124}; alarm 10; exec @ARGV' -- sh "$DAEMON" >/dev/null 2>&1; zero_status=$?
if [ "$zero_status" -ne 0 ] && grep -q '^zero_rpm$' "$RUNTIME/fault" && grep -q '^255$' "$SYSFS/class/hwmon/hwmon0/pwm1"; then
	pass 'zero RPM limit triggers full-speed fail-safe'
else
	fail 'zero RPM limit triggers full-speed fail-safe'
fi

if command -v shellcheck >/dev/null 2>&1; then
	# Warnings from the intentionally dynamic common-helper source are allowed;
	# syntax/errors still return non-zero.
	shellcheck -S error "$INSTALLER" "$STATUS" "$VALIDATE" "$DAEMON" >/dev/null 2>&1 || fail 'shellcheck package scripts'
	[ "$failures" -gt 0 ] || pass 'shellcheck package scripts'
fi
for file in "$INSTALLER" "$STATUS" "$VALIDATE" "$DAEMON" "$COMMON"; do
	if ! sh -n "$file"; then fail "sh -n $(basename "$file")"; else pass "sh -n $(basename "$file")"; fi
done

# Installer board, checksum and package-manager gates use a harmless fixture.
PKG_DIR=$TMP/packages
mkdir -p "$PKG_DIR"
CORE_APK=$PKG_DIR/ax9000-fan-control-1.0.0-r4.apk
printf '%s\n' placeholder > "$CORE_APK"
if command -v sha256sum >/dev/null 2>&1; then core_sha=$(sha256sum "$CORE_APK" | awk '{print $1}'); else core_sha=$(openssl dgst -sha256 "$CORE_APK" | sed 's/^.*= *//'); fi
printf '%s  %s\n' "$core_sha" "${CORE_APK##*/}" > "$CORE_APK.sha256"
FAKE_APK=$TMP/apk
cat > "$FAKE_APK" <<'EOF'
#!/bin/sh
case " $* " in
	*' --print-arch '*) printf '%s\n' all ;;
	*' info -e '*) exit 1 ;;
	*) [ -n "${AX9000_FAKE_PM_LOG:-}" ] && printf '%s|%s|%s|%s\n' "${IPKG_INSTROOT:-}" "${AX9000_ALLOW_BOARD_OVERRIDE:-}" "${AX9000_BOARD_OVERRIDE:-}" "$*" >> "$AX9000_FAKE_PM_LOG"; exit 0 ;;
esac
EOF
chmod +x "$FAKE_APK"
if AX9000_APK_BIN="$FAKE_APK" "$INSTALLER" --board xiaomi,ax9000 --arch all --package-manager apk --package-dir "$PKG_DIR" --dry-run > "$TMP/install.out"; then
	if grep -q 'DRY-RUN: no package changes made' "$TMP/install.out"; then pass 'installer dry-run validates local package plan'; else fail 'installer dry-run output'; fi
else
	fail 'installer dry-run validates local package plan'
fi
if AX9000_APK_BIN="$FAKE_APK" "$INSTALLER" --board vendor,unsupported --arch all --package-manager apk --package-dir "$PKG_DIR" --dry-run >/dev/null 2>&1; then
	fail 'installer rejects unsupported board'
else
	pass 'installer rejects unsupported board'
fi

NO_HASH_DIR=$TMP/no-hash-packages
mkdir -p "$NO_HASH_DIR"
cp "$CORE_APK" "$NO_HASH_DIR/${CORE_APK##*/}"
if AX9000_APK_BIN="$FAKE_APK" "$INSTALLER" --board xiaomi,ax9000 --arch all --package-manager apk --package-dir "$NO_HASH_DIR" --dry-run >/dev/null 2>&1; then
	fail 'installer rejects a local package without SHA256'
else
	pass 'installer rejects a local package without SHA256'
fi

PM_LOG=$TMP/pm.log
if AX9000_FAKE_PM_LOG="$PM_LOG" AX9000_APK_BIN="$FAKE_APK" "$INSTALLER" --board xiaomi,ax9000 --allow-board-override --arch all --package-manager apk --package-dir "$PKG_DIR" --sha256 nope >/dev/null 2>&1; then
	fail 'installer rejects an invalid explicit SHA256'
else
	[ ! -s "$PM_LOG" ] && pass 'invalid SHA256 fails before package manager' || fail 'invalid SHA256 reached package manager'
fi

: > "$PM_LOG"
if AX9000_FAKE_PM_LOG="$PM_LOG" AX9000_APK_BIN="$FAKE_APK" "$INSTALLER" --board xiaomi,ax9000 --allow-board-override --arch all --package-manager apk --package-dir "$PKG_DIR" >/dev/null 2>&1 && grep -F '|1|xiaomi,ax9000|add --no-progress --allow-untrusted' "$PM_LOG" >/dev/null 2>&1; then
	pass 'recovery board override reaches the core package preinstall hook'
else
	fail 'recovery board override reaches the core package preinstall hook'
fi

if AX9000_APK_BIN="$FAKE_APK" "$INSTALLER" --board xiaomi,ax9000 --arch all --package-manager apk --package-dir "$PKG_DIR" --luci-package "$TMP/missing-luci.apk" --dry-run >/dev/null 2>&1; then
	fail 'installer rejects an explicitly missing LuCI package'
else
	pass 'installer rejects an explicitly missing LuCI package'
fi

LUCI_APK=$TMP/luci-app-ax9000-fan-1.0.0-r1.apk
printf '%s\n' luci-placeholder > "$LUCI_APK"
if command -v sha256sum >/dev/null 2>&1; then luci_sha=$(sha256sum "$LUCI_APK" | awk '{print $1}'); else luci_sha=$(openssl dgst -sha256 "$LUCI_APK" | sed 's/^.*= *//'); fi
FAKE_BIN=$TMP/fake-bin
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/sh
dest=
while [ "$#" -gt 0 ]; do
	case "$1" in -o) dest=$2; shift 2 ;; *) shift ;; esac
done
[ -n "$dest" ] || exit 1
cp "$AX9000_FAKE_DOWNLOAD_SOURCE" "$dest"
EOF
chmod +x "$FAKE_BIN/curl"
if PATH="$FAKE_BIN:$PATH" AX9000_FAKE_DOWNLOAD_SOURCE="$LUCI_APK" AX9000_APK_BIN="$FAKE_APK" "$INSTALLER" --board xiaomi,ax9000 --arch all --package-manager apk --package-dir "$PKG_DIR" --luci-package 'https://example.invalid/luci-app-ax9000-fan-1.0.0-r1.apk' --luci-sha256 "$luci_sha" --dry-run > "$TMP/https-luci.out" 2>&1 && grep -F 'luci-app-ax9000-fan-1.0.0-r1.apk (SHA256 verified)' "$TMP/https-luci.out" >/dev/null 2>&1; then
	pass 'local core plus HTTPS LuCI preserves and validates package name'
else
	fail 'local core plus HTTPS LuCI preserves and validates package name'
fi

if grep -F -- "--proto-redir '=https'" "$INSTALLER" >/dev/null 2>&1 && grep -F -- '--https-only' "$INSTALLER" >/dev/null 2>&1 && ! grep -F 'uclient-fetch -' "$INSTALLER" >/dev/null 2>&1; then
	pass 'remote downloader refuses HTTPS-to-HTTP downgrade paths'
else
	fail 'remote downloader refuses HTTPS-to-HTTP downgrade paths'
fi

OFFLINE_ROOT=$TMP/offline-root
mkdir -p "$OFFLINE_ROOT/tmp/sysinfo" "$OFFLINE_ROOT/etc"
printf '%s\n' xiaomi,ax9000 > "$OFFLINE_ROOT/tmp/sysinfo/board_name"
printf '%s\n' "DISTRIB_ARCH='all'" > "$OFFLINE_ROOT/etc/openwrt_release"
OFFLINE_LOG=$TMP/offline-pm.log
if AX9000_FAKE_PM_LOG="$OFFLINE_LOG" AX9000_APK_BIN="$FAKE_APK" "$INSTALLER" --root "$OFFLINE_ROOT" --package-manager apk --package-dir "$PKG_DIR" >"$TMP/offline.out" 2>"$TMP/offline.err" && grep -F "$OFFLINE_ROOT|||--root $OFFLINE_ROOT add" "$OFFLINE_LOG" >/dev/null 2>&1; then
	pass 'offline install exports IPKG_INSTROOT to package manager'
else
	[ ! -s "$TMP/offline.err" ] || sed 's/^/# offline: /' "$TMP/offline.err" >&2
	fail 'offline install exports IPKG_INSTROOT to package manager'
fi

if grep -F 'refusing unsafe removal' "$ROOT/controller/Makefile" >/dev/null 2>&1 && grep -F 'refusing incomplete install' "$ROOT/controller/Makefile" >/dev/null 2>&1; then
	pass 'package lifecycle hooks fail closed when safety helpers are missing'
else
	fail 'package lifecycle hooks fail closed when safety helpers are missing'
fi

printf '%s\n' 110 > "$SYSFS/class/hwmon/hwmon0/pwm1"
# shellcheck disable=SC2086
env $COMMON_ENV AX9000_BOARD=vendor,unsupported AX9000_SKIP_CONTROLLER_INIT=1 sh "$DAEMON" >/dev/null 2>&1; unsupported_status=$?
if [ "$unsupported_status" -ne 0 ] && grep -q '^110$' "$SYSFS/class/hwmon/hwmon0/pwm1"; then
	pass 'unsupported board rejection does not touch fan hardware'
else
	fail 'unsupported board rejection does not touch fan hardware'
fi

if [ "$failures" -ne 0 ]; then
	printf '%s\n' "$failures test(s) failed" >&2
	exit 1
fi
printf '%s\n' 'all AX9000 fan core tests passed'

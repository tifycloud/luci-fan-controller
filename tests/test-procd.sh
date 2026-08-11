#!/bin/sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
INIT=$ROOT/controller/files/etc/init.d/ax9000-fan-control

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ax9000-fan-procd-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

# The OpenWrt 25.12 procd.sh implementation has this call site:
#
#   _procd_open_instance() {
#       local name="$1"; shift
#       ...
#   }
#
# On the target's BusyBox ash, invoking procd_open_instance without an
# optional name reaches shift with no positional parameters and reports the
# exact error below. Keep the fixture's diagnostic byte-for-byte compatible so
# this test remains red on the shipped init script and green after the caller
# supplies an explicit instance name.
PROCD=$TMP/procd.sh
cat > "$PROCD" <<'EOF'
PROCD_ERROR=0

procd_add_reload_trigger() {
	printf 'reload_trigger\t%s\n' "$*" >> "$PROCD_LOG"
}

procd_open_instance() {
	if [ "$#" -eq 0 ]; then
		printf '%s\n' '/lib/functions/procd.sh: line 144: shift: shift count out of range' >&2
		PROCD_ERROR=1
		return 2
	fi
	name=$1
	shift
	printf 'open_instance\t%s\n' "$name" >> "$PROCD_LOG"
}

procd_set_param() {
	# OpenWrt procd implements stdout/stderr capture with libsetlbf.so. The
	# fixture records that equivalent preload request so the test stays red if
	# the init script reintroduces either capture parameter.
	case "$1" in
	stdout|stderr)
		LD_PRELOAD=/lib/libsetlbf.so
		export LD_PRELOAD
		printf '%s\n' "$LD_PRELOAD" > "$PROCD_PRELOAD"
		;;
	esac
	printf 'set_param\t%s\t%s\n' "$1" "$*" >> "$PROCD_LOG"
}

procd_close_instance() {
	return 0
}
EOF

# Keep the service path isolated from real sysfs, UCI, logging, and hardware.
COMMON=$TMP/common.sh
cat > "$COMMON" <<'EOF'
AX9000_PIDFILE=${AX9000_PIDFILE:-/tmp/ax9000-fan-control.pid}
AX9000_CONFIG_ERROR=
ax9000_board_name() { printf '%s\n' 'xiaomi,ax9000'; }
ax9000_supported_board() { [ "$1" = 'xiaomi,ax9000' ]; }
ax9000_write_fault() { :; }
ax9000_log() { :; }
ax9000_load_config() { return 0; }
ax9000_prepare_controller() { return 0; }
ax9000_fan_full_speed() { return 0; }
ax9000_find_fan() { return 1; }
EOF

LOG=$TMP/procd.log
: > "$LOG"

# Source the actual init script against the fixture procd/common helpers. The
# explicit exit check turns the fixture's simulated BusyBox shift diagnostic
# into a deterministic red/green signal rather than relying on shell options.
run_service() {
	PROCD_LOG=$LOG PROCD_PRELOAD=$TMP/procd.preload PROCD=$PROCD INIT=$INIT COMMON=$COMMON PIDFILE=$TMP/pid sh -c '
		. "$PROCD"
		AX9000_COMMON=$COMMON
		AX9000_PIDFILE=$PIDFILE
		export AX9000_COMMON AX9000_PIDFILE
		. "$INIT"
	service_triggers
	start_service
	[ "${LD_PRELOAD:-}" != '/lib/libsetlbf.so' ]
	[ "$PROCD_ERROR" -eq 0 ]
'
}

if ! output=$(run_service 2>&1); then
	fail "init service can invoke procd without shift failure (got: $output)"
fi

if grep -F '/lib/functions/procd.sh: line 144: shift: shift count out of range' <<EOF >/dev/null
$output
EOF
then
	fail 'init service does not emit the procd shift diagnostic'
fi

TAB=$(printf '\t')
grep -F "reload_trigger${TAB}ax9000-fan" "$LOG" >/dev/null 2>&1 || fail 'UCI reload trigger is registered'
grep -F "open_instance${TAB}fan_control" "$LOG" >/dev/null 2>&1 || fail 'a stable named procd instance is opened'
grep -F "set_param${TAB}command${TAB}command /usr/sbin/ax9000-fan-control" "$LOG" >/dev/null 2>&1 || fail 'daemon command is passed as a procd array'
grep -F "set_param${TAB}pidfile${TAB}pidfile " "$LOG" >/dev/null 2>&1 || fail 'pidfile is passed to procd'
grep -F "set_param${TAB}respawn${TAB}respawn 3600 5 5" "$LOG" >/dev/null 2>&1 || fail 'respawn policy is passed to procd'
[ ! -s "$TMP/procd.preload" ] || fail 'supervised environment does not inject libsetlbf.so'
if grep -E 'procd_set_param[[:space:]]+(stdout|stderr)([[:space:]]|$)|libsetlbf' "$INIT" >/dev/null 2>&1; then
	fail 'init script omits stdout/stderr capture parameters'
fi

pass 'AX9000 init script avoids libsetlbf stdout/stderr capture and remains procd-compatible'

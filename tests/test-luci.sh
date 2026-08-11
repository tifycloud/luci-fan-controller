#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
PKG="$ROOT/luci"
VIEW="$PKG/root/www/luci-static/resources/view/ax9000-fan/overview.js"
CSS="$PKG/root/www/luci-static/resources/view/ax9000-fan/overview.css"
MENU="$PKG/root/usr/share/luci/menu.d/luci-app-ax9000-fan.json"
ACL="$PKG/root/usr/share/rpcd/acl.d/luci-app-ax9000-fan.json"
DEVICE_README="$PKG/root/usr/share/ax9000-fan/README"

failures=0

fail() {
	printf '%s\n' "FAIL: $*" >&2
	failures=$((failures + 1))
}

contains() {
	file=$1
	needle=$2
	if ! grep -F -- "$needle" "$file" >/dev/null 2>&1; then
		fail "$file does not contain: $needle"
	fi
}

not_contains() {
	file=$1
	needle=$2
	if grep -F -- "$needle" "$file" >/dev/null 2>&1; then
		fail "$file must not contain: $needle"
	fi
}

for file in "$PKG/Makefile" "$VIEW" "$CSS" "$MENU" "$ACL" "$PKG/README.md" "$PKG/root/usr/share/ax9000-fan/README"; do
	[ -f "$file" ] || fail "missing file: $file"
done

contains "$MENU" '"admin/system/ax9000-fan"'
contains "$MENU" '"title": "AX9000 风扇"'
contains "$MENU" '"path": "ax9000-fan/overview"'
contains "$MENU" '"luci-app-ax9000-fan"'

contains "$ACL" '"luci-app-ax9000-fan"'
contains "$ACL" '"ax9000-fan"'
contains "$ACL" '"file": ["exec"]'
contains "$ACL" '"/usr/libexec/ax9000-fan-status": ["exec"]'
not_contains "$ACL" '"/etc/init.d/'
not_contains "$ACL" '"/bin/sh'

for module in "'require view';" "'require form';" "'require fs';" "'require poll';" "'require uci';"; do
	contains "$VIEW" "$module"
done
contains "$VIEW" "var STATUS_PATH = '/usr/libexec/ax9000-fan-status';"
contains "$VIEW" 'fs.exec(STATUS_PATH, [])'
contains "$VIEW" 'parseStatusResult(result)'
contains "$VIEW" 'transport_error'
contains "$VIEW" 'isCanonicalUnsignedInteger(value)'
contains "$VIEW" '不带前导零的整数'
contains "$VIEW" 'poll.add(this.pollFn, STATUS_POLL_SECONDS)'
contains "$VIEW" 'uci.load('

for field in enabled poll_seconds hysteresis_c temp_warm temp_hot temp_max pwm_cool pwm_warm pwm_hot pwm_max zero_rpm_limit; do
	contains "$VIEW" "'$field'"
done
contains "$VIEW" '温度曲线'
contains "$VIEW" '风扇输出'
contains "$VIEW" '保护'
contains "$VIEW" 'service_running'
contains "$VIEW" 'fan_found'
contains "$VIEW" 'max_temp_mC'
contains "$VIEW" '最高温度'
contains "$VIEW" 'mC < -20000 || mC > 200000'
not_contains "$VIEW" 'mC < 0)'
contains "$VIEW" 'PWM 输出'
contains "$VIEW" '保存并应用'
contains "$VIEW" '重载控制器'
contains "$VIEW" '没有立即停转'
contains "$VIEW" "range(1, 3600)"
contains "$VIEW" "range(1, 20)"
contains "$VIEW" "range(30, 100)"
contains "$VIEW" "range(31, 110)"
contains "$VIEW" "range(32, 120)"
contains "$VIEW" "range(255, 255)"
contains "$PKG/Makefile" '+ax9000-fan-control'
contains "$DEVICE_README" '30–100'
contains "$DEVICE_README" '31–110'
contains "$DEVICE_README" '32–120'
contains "$DEVICE_README" '1–3600'
contains "$DEVICE_README" '1–20'
contains "$DEVICE_README" '1–60'

if [ "$(grep -c "form.Value, 'pwm_max'" "$VIEW")" -ne 1 ]; then
	fail 'view must define exactly one pwm_max input'
fi

# The only command execution in the view must be the fixed status helper.
if grep -n 'fs\.exec' "$VIEW" | grep -v 'fs.exec(STATUS_PATH, \[\])' >/dev/null 2>&1; then
	fail "view contains an fs.exec call other than the fixed status helper"
fi
not_contains "$VIEW" '/etc/init.d/'
not_contains "$VIEW" 'start-stop-daemon'
not_contains "$VIEW" 'uci.set.*pwm'

contains "$CSS" '@media (max-width: 560px)'
contains "$CSS" '@media (prefers-reduced-motion: reduce)'
contains "$CSS" ':focus-visible'
not_contains "$CSS" 'url(http'

if [ "$failures" -ne 0 ]; then
	printf '%s\n' "$failures static LuCI checks failed." >&2
	exit 1
fi

printf '%s\n' 'All static LuCI checks passed.'

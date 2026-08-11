#!/bin/sh
# Fail-closed installer for the AX9000 fan core and LuCI packages.
set -eu

SCRIPT_NAME=${0##*/}
TARGET_ROOT=${AX9000_TARGET_ROOT:-/}
ARCH_OVERRIDE=${AX9000_ARCH:-}
PM_OVERRIDE=${AX9000_PACKAGE_MANAGER:-}
APK_BIN=${AX9000_APK_BIN:-apk}
OPKG_BIN=${AX9000_OPKG_BIN:-opkg}

PACKAGE_DIR=
RELEASE_URL=
SHA256_SPEC=
LUCI_SPEC=
LUCI_SHA256_SPEC=
BOARD_OVERRIDE=
ALLOW_BOARD_OVERRIDE=0
DRY_RUN=0
UNINSTALL=0
PURGE=0
TMP_DIR=
PM=
ARCH=
RESOLVED_FILE=
RESOLVED_HASH=

usage() {
	cat <<'EOF'
Usage: install-ax9000-fan.sh [options]

Install (default):
  --package-dir DIR       Use one core and optional LuCI .apk/.ipk from DIR.
  --release-url URL       Download the core package over HTTPS.
  --sha256 HASH|FILE|URL  Core SHA256; local .sha256/SHA256SUMS also accepted.
  --luci-package PATH|URL Optional luci-app-ax9000-fan package.
  --luci-sha256 HASH|FILE|URL  LuCI SHA256; required for an HTTPS LuCI URL.

Common:
  --package-manager apk|opkg  Select an available package manager.
  --arch ARCH             Override detected OpenWrt architecture.
  --root DIR              Operate on an offline target root using a host PM.
  --dry-run               Validate packages, hashes and plan; change nothing.
  --uninstall             Stop the service, force full speed, remove packages.
  --purge                 With --uninstall, also remove UCI configuration.
  -h, --help              Show this help.

Recovery-only board override:
  --board BOARD --allow-board-override

Exactly one install source is required. Every package must have a verified
SHA256. APK installation uses --allow-untrusted only after that verification.
EOF
}

die() {
	printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 1
}

note() {
	printf '%s\n' "$*"
}

target_path() {
	path=$1
	if [ "$TARGET_ROOT" = / ]; then
		printf '/%s\n' "${path#/}"
	else
		printf '%s/%s\n' "${TARGET_ROOT%/}" "${path#/}"
	fi
}

cleanup() {
	[ -n "${TMP_DIR:-}" ] || return 0
	case "$TMP_DIR" in
		*/ax9000-fan.*) [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR" ;;
		*) printf '%s: refusing unexpected temporary path cleanup: %s\n' "$SCRIPT_NAME" "$TMP_DIR" >&2 ;;
	esac
}
trap cleanup EXIT HUP INT TERM

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--package-dir) [ "$#" -ge 2 ] || die '--package-dir needs a directory'; PACKAGE_DIR=$2; shift 2 ;;
			--package-dir=*) PACKAGE_DIR=${1#*=}; shift ;;
			--release-url) [ "$#" -ge 2 ] || die '--release-url needs an HTTPS URL'; RELEASE_URL=$2; shift 2 ;;
			--release-url=*) RELEASE_URL=${1#*=}; shift ;;
			--sha256) [ "$#" -ge 2 ] || die '--sha256 needs a hash, file, or HTTPS URL'; SHA256_SPEC=$2; shift 2 ;;
			--sha256=*) SHA256_SPEC=${1#*=}; shift ;;
			--luci-package) [ "$#" -ge 2 ] || die '--luci-package needs a path or HTTPS URL'; LUCI_SPEC=$2; shift 2 ;;
			--luci-package=*) LUCI_SPEC=${1#*=}; shift ;;
			--luci-sha256) [ "$#" -ge 2 ] || die '--luci-sha256 needs a hash, file, or HTTPS URL'; LUCI_SHA256_SPEC=$2; shift 2 ;;
			--luci-sha256=*) LUCI_SHA256_SPEC=${1#*=}; shift ;;
			--package-manager) [ "$#" -ge 2 ] || die '--package-manager needs apk or opkg'; PM_OVERRIDE=$2; shift 2 ;;
			--package-manager=*) PM_OVERRIDE=${1#*=}; shift ;;
			--board) [ "$#" -ge 2 ] || die '--board needs a board name'; BOARD_OVERRIDE=$2; shift 2 ;;
			--board=*) BOARD_OVERRIDE=${1#*=}; shift ;;
			--allow-board-override) ALLOW_BOARD_OVERRIDE=1; shift ;;
			--arch) [ "$#" -ge 2 ] || die '--arch needs an architecture'; ARCH_OVERRIDE=$2; shift 2 ;;
			--arch=*) ARCH_OVERRIDE=${1#*=}; shift ;;
			--root) [ "$#" -ge 2 ] || die '--root needs a directory'; TARGET_ROOT=$2; shift 2 ;;
			--root=*) TARGET_ROOT=${1#*=}; shift ;;
			--dry-run) DRY_RUN=1; shift ;;
			--uninstall) UNINSTALL=1; shift ;;
			--purge) PURGE=1; shift ;;
			-h|--help) usage; exit 0 ;;
			*) die "unknown option: $1" ;;
		esac
	done
}

validate_options() {
	case "$TARGET_ROOT" in /*) ;; *) die '--root must be an absolute path' ;; esac
	[ "$TARGET_ROOT" = / ] || [ -d "$TARGET_ROOT" ] || die "target root does not exist: $TARGET_ROOT"
	[ "$PURGE" -eq 0 ] || [ "$UNINSTALL" -eq 1 ] || die '--purge requires --uninstall'
	if [ -n "$BOARD_OVERRIDE" ] && [ "$ALLOW_BOARD_OVERRIDE" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
		die '--board on a live operation also requires --allow-board-override'
	fi
	if [ "$UNINSTALL" -eq 1 ]; then
		[ -z "$PACKAGE_DIR$RELEASE_URL$SHA256_SPEC$LUCI_SPEC$LUCI_SHA256_SPEC" ] || die '--uninstall cannot be combined with package source or checksum options'
	fi
}

read_board() {
	if [ -n "$BOARD_OVERRIDE" ]; then
		printf '%s\n' "$BOARD_OVERRIDE"
		return 0
	fi
	board_file=$(target_path /tmp/sysinfo/board_name)
	if [ -r "$board_file" ]; then
		sed -n '1p' "$board_file"
		return 0
	fi
	if [ "$TARGET_ROOT" = / ] && command -v ubus >/dev/null 2>&1; then
		ubus call system board 2>/dev/null | sed -n 's/.*"board_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p'
		return 0
	fi
	return 1
}

supported_board() {
	case "$1" in xiaomi,ax9000|xiaomi,ax9000-darkyun) return 0 ;; *) return 1 ;; esac
}

detect_pm() {
	case "$PM_OVERRIDE" in
		apk|opkg) PM=$PM_OVERRIDE ;;
		'')
			if command -v "$APK_BIN" >/dev/null 2>&1; then PM=apk
			elif command -v "$OPKG_BIN" >/dev/null 2>&1; then PM=opkg
			else die 'neither host apk nor opkg is available'
			fi
			;;
		*) die '--package-manager must be apk or opkg' ;;
	esac
	case "$PM" in
		apk) command -v "$APK_BIN" >/dev/null 2>&1 || die "apk command not found: $APK_BIN" ;;
		opkg) command -v "$OPKG_BIN" >/dev/null 2>&1 || die "opkg command not found: $OPKG_BIN" ;;
	esac
}

read_arch() {
	if [ -n "$ARCH_OVERRIDE" ]; then
		printf '%s\n' "$ARCH_OVERRIDE"
		return 0
	fi
	release_file=$(target_path /etc/openwrt_release)
	if [ -r "$release_file" ]; then
		arch=$(sed -n 's/^DISTRIB_ARCH=//p' "$release_file" | sed -n '1p' | tr -d "\"'")
		[ -n "$arch" ] && { printf '%s\n' "$arch"; return 0; }
	fi
	if [ "$TARGET_ROOT" = / ] && [ "$PM" = apk ]; then
		arch=$("$APK_BIN" --print-arch 2>/dev/null | sed -n '1p')
		[ -n "$arch" ] && { printf '%s\n' "$arch"; return 0; }
	fi
	if [ "$TARGET_ROOT" = / ] && [ "$PM" = opkg ]; then
		arch=$("$OPKG_BIN" print-architecture 2>/dev/null | awk '$1 == "arch" && $2 != "all" { value=$2 } END { if (value) print value }')
		[ -n "$arch" ] && { printf '%s\n' "$arch"; return 0; }
	fi
	return 1
}

is_https_url() {
	case "$1" in https://*) return 0 ;; *) return 1 ;; esac
}

download_file() {
	url=$1
	dest=$2
	is_https_url "$url" || die "refusing non-HTTPS URL: $url"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "$url" -o "$dest" || die "download failed: $url"
	elif command -v wget >/dev/null 2>&1 && wget --version 2>/dev/null | sed -n '1p' | grep -F 'GNU Wget' >/dev/null 2>&1; then
		wget -q --https-only --max-redirect=10 -O "$dest" "$url" || die "download failed: $url"
	else
		die 'curl or GNU Wget is required for HTTPS-only redirect enforcement; use verified local packages when unavailable'
	fi
	[ -s "$dest" ] || die "download produced an empty file: $url"
}

sha256_file() {
	file=$1
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$file" | awk '{print tolower($1)}'; return 0; fi
	if command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$file" | sed 's/^.*= *//' | tr 'A-F' 'a-f'; return 0; fi
	return 1
}

read_hash_file() {
	file=$1
	target_name=$2
	RESOLVED_HASH=$(awk -v wanted="$target_name" '
		length($1) == 64 && tolower($1) !~ /[^0-9a-f]/ {
			name=$2
			sub(/^\*/, "", name)
			sub(/^\.\//, "", name)
			if (NF == 1 || name == wanted) { print tolower($1); exit }
		}
	' "$file" 2>/dev/null || true)
	[ -n "$RESOLVED_HASH" ]
}

resolve_hash_spec() {
	spec=$1
	target_name=$2
	label=$3
	RESOLVED_HASH=
	case "$spec" in
		https://*)
			hash_file="$TMP_DIR/${label}.sha256"
			download_file "$spec" "$hash_file"
			read_hash_file "$hash_file" "$target_name" || die "$label checksum file has no matching SHA256"
			;;
		*)
			case "$spec" in
				????????????????????????????????????????????????????????????????)
					case "$spec" in *[!0-9a-fA-F]*) die "invalid $label SHA256" ;; esac
					RESOLVED_HASH=$(printf '%s' "$spec" | tr 'A-F' 'a-f')
					;;
				*) [ -r "$spec" ] || die "$label checksum file not found: $spec"; read_hash_file "$spec" "$target_name" || die "$label checksum file has no matching SHA256" ;;
			esac
			;;
	esac
}

find_sidecar_hash() {
	file=$1
	target_name=${file##*/}
	for sidecar in "$file.sha256" "${file%.*}.sha256" "${file%/*}/SHA256SUMS"; do
		[ -r "$sidecar" ] || continue
		if read_hash_file "$sidecar" "$target_name"; then return 0; fi
	done
	return 1
}

verify_hash() {
	file=$1
	expected=$2
	label=$3
	actual=$(sha256_file "$file" 2>/dev/null) || die "cannot calculate SHA256 for $label"
	[ "$actual" = "$expected" ] || die "SHA256 mismatch for $label"
}

find_unique_package() {
	directory=$1
	name=$2
	extension=$3
	count=0
	RESOLVED_FILE=
	for candidate in "$directory"/"$name"*.$extension; do
		[ -f "$candidate" ] || continue
		RESOLVED_FILE=$candidate
		count=$((count + 1))
	done
	[ "$count" -eq 1 ] || return 1
}

validate_package_name() {
	file=$1
	name=$2
	base=${file##*/}
	case "$PM:$name:$base" in
		apk:ax9000-fan-control:ax9000-fan-control-*.apk|apk:luci-app-ax9000-fan:luci-app-ax9000-fan-*.apk) return 0 ;;
		opkg:ax9000-fan-control:ax9000-fan-control_*_all.ipk|opkg:luci-app-ax9000-fan:luci-app-ax9000-fan_*_all.ipk) return 0 ;;
		*) die "unexpected $name artifact name for $PM: $base" ;;
	esac
}

resolve_package_spec() {
	spec=$1
	dest=$2
	RESOLVED_FILE=
	case "$spec" in
		https://*) download_file "$spec" "$dest"; RESOLVED_FILE=$dest ;;
		http://*) die "refusing non-HTTPS package URL: $spec" ;;
		*) [ -f "$spec" ] || die "package not found: $spec"; RESOLVED_FILE=$spec ;;
	esac
}

pm_install() {
	file=$1
	if [ "$DRY_RUN" -eq 1 ]; then note "DRY-RUN: install $file with $PM"; return 0; fi
	if [ -n "$BOARD_OVERRIDE" ] && [ "$ALLOW_BOARD_OVERRIDE" -eq 1 ]; then
		# The core package repeats the board gate in preinst. Pass the recovery
		# override only after this installer has required the explicit consent flag
		# and checked the value against the exact supported-board allow-list.
		export AX9000_ALLOW_BOARD_OVERRIDE=1
		export AX9000_BOARD_OVERRIDE=$board
	fi
	case "$PM:$TARGET_ROOT" in
		apk:/) "$APK_BIN" add --no-progress --allow-untrusted "$file" ;;
		apk:*) IPKG_INSTROOT="$TARGET_ROOT" "$APK_BIN" --root "$TARGET_ROOT" add --no-progress --allow-untrusted "$file" ;;
		opkg:/) "$OPKG_BIN" install "$file" ;;
		opkg:*) IPKG_INSTROOT="$TARGET_ROOT" "$OPKG_BIN" -o "$TARGET_ROOT" install "$file" ;;
	esac
}

pm_remove() {
	package=$1
	if [ "$DRY_RUN" -eq 1 ]; then note "DRY-RUN: remove $package with $PM"; return 0; fi
	case "$PM:$TARGET_ROOT" in
		apk:/) "$APK_BIN" del "$package" ;;
		apk:*) IPKG_INSTROOT="$TARGET_ROOT" "$APK_BIN" --root "$TARGET_ROOT" del "$package" ;;
		opkg:/) "$OPKG_BIN" remove "$package" ;;
		opkg:*) IPKG_INSTROOT="$TARGET_ROOT" "$OPKG_BIN" -o "$TARGET_ROOT" remove "$package" ;;
	esac
}

pm_is_installed() {
	package=$1
	case "$PM:$TARGET_ROOT" in
		apk:/) "$APK_BIN" info -e "$package" >/dev/null 2>&1 ;;
		apk:*) "$APK_BIN" --root "$TARGET_ROOT" info -e "$package" >/dev/null 2>&1 ;;
		opkg:/) "$OPKG_BIN" status "$package" 2>/dev/null | grep -q 'Status: install' ;;
		opkg:*) "$OPKG_BIN" -o "$TARGET_ROOT" status "$package" 2>/dev/null | grep -q 'Status: install' ;;
	esac
}

force_full_speed_before_uninstall() {
	if [ "$TARGET_ROOT" != / ]; then note 'offline root: no live fan hardware is touched'; return 0; fi
	if [ "$DRY_RUN" -eq 1 ]; then note 'DRY-RUN: stop service, force PWM 255, verify full speed'; return 0; fi
	init_script=$(target_path /etc/init.d/ax9000-fan-control)
	force_script=$(target_path /usr/libexec/ax9000-fan-force-fullspeed)
	[ -x "$init_script" ] || die 'fan init script is missing; refusing live uninstall'
	[ -x "$force_script" ] || die 'full-speed helper is missing; refusing live uninstall'
	"$init_script" stop || die 'unable to stop the fan service safely'
	"$force_script" || die 'unable to set and verify full fan speed'
}

uninstall_flow() {
	if pm_is_installed ax9000-fan-control; then force_full_speed_before_uninstall; fi
	if pm_is_installed luci-app-ax9000-fan; then pm_remove luci-app-ax9000-fan || die 'LuCI package removal failed'; fi
	if pm_is_installed ax9000-fan-control; then pm_remove ax9000-fan-control || die 'core package removal failed'; fi
	if [ "$PURGE" -eq 1 ]; then
		config_file=$(target_path /etc/config/ax9000-fan)
		if [ "$DRY_RUN" -eq 1 ]; then note "DRY-RUN: remove $config_file"; else rm -f "$config_file" || die 'unable to purge UCI configuration'; fi
	fi
	note 'AX9000 fan packages removed; configuration was preserved unless --purge was supplied.'
}

prepare_local_core() {
	case "$PM" in apk) ext=apk ;; opkg) ext=ipk ;; esac
	find_unique_package "$PACKAGE_DIR" ax9000-fan-control "$ext" || die "package directory must contain exactly one ax9000-fan-control .$ext"
	core=$RESOLVED_FILE
	validate_package_name "$core" ax9000-fan-control
	if [ -n "$SHA256_SPEC" ]; then resolve_hash_spec "$SHA256_SPEC" "${core##*/}" core
	elif ! find_sidecar_hash "$core"; then die 'local core package requires a matching .sha256 or SHA256SUMS entry'
	fi
	core_hash=$RESOLVED_HASH
	verify_hash "$core" "$core_hash" core
}

prepare_local_luci() {
	case "$PM" in apk) ext=apk ;; opkg) ext=ipk ;; esac
	if [ -n "$LUCI_SPEC" ]; then
		case "$LUCI_SPEC" in
			https://*)
				luci_name=${LUCI_SPEC##*/}
				luci_name=${luci_name%%\?*}
				[ -n "$luci_name" ] || die 'HTTPS LuCI package URL has no filename'
				resolve_package_spec "$LUCI_SPEC" "$TMP_DIR/$luci_name"
				;;
			*) resolve_package_spec "$LUCI_SPEC" "$TMP_DIR/luci.$ext" ;;
		esac
		luci=$RESOLVED_FILE
	else
		count=0
		RESOLVED_FILE=
		for candidate in "$PACKAGE_DIR"/luci-app-ax9000-fan*.$ext; do
			[ -f "$candidate" ] || continue
			RESOLVED_FILE=$candidate
			count=$((count + 1))
		done
		[ "$count" -le 1 ] || die "package directory contains multiple luci-app-ax9000-fan .$ext files"
		[ "$count" -eq 1 ] || return 0
		luci=$RESOLVED_FILE
	fi
	validate_package_name "$luci" luci-app-ax9000-fan
	if is_https_url "$LUCI_SPEC"; then
		[ -n "$LUCI_SHA256_SPEC" ] || die 'HTTPS LuCI package requires --luci-sha256'
		resolve_hash_spec "$LUCI_SHA256_SPEC" "${luci##*/}" luci
	elif [ -n "$LUCI_SHA256_SPEC" ]; then resolve_hash_spec "$LUCI_SHA256_SPEC" "${luci##*/}" luci
	elif ! find_sidecar_hash "$luci"; then die 'local LuCI package requires a matching .sha256 or SHA256SUMS entry'
	fi
	luci_hash=$RESOLVED_HASH
	verify_hash "$luci" "$luci_hash" luci
}

prepare_remote_packages() {
	is_https_url "$RELEASE_URL" || die '--release-url must use HTTPS'
	case "$PM" in apk) ext=apk ;; opkg) ext=ipk ;; esac
	release_name=${RELEASE_URL##*/}
	release_name=${release_name%%\?*}
	core="$TMP_DIR/$release_name"
	download_file "$RELEASE_URL" "$core"
	validate_package_name "$core" ax9000-fan-control
	if [ -n "$SHA256_SPEC" ]; then resolve_hash_spec "$SHA256_SPEC" "$release_name" core
	else
		download_file "${RELEASE_URL}.sha256" "$TMP_DIR/core.sha256"
		read_hash_file "$TMP_DIR/core.sha256" "$release_name" || die 'remote core checksum has no matching SHA256'
	fi
	core_hash=$RESOLVED_HASH
	verify_hash "$core" "$core_hash" core
	if [ -n "$LUCI_SPEC" ]; then
		is_https_url "$LUCI_SPEC" || die 'remote LuCI package must use HTTPS'
		[ -n "$LUCI_SHA256_SPEC" ] || die 'HTTPS LuCI package requires --luci-sha256'
		luci_name=${LUCI_SPEC##*/}
		luci_name=${luci_name%%\?*}
		luci="$TMP_DIR/$luci_name"
		download_file "$LUCI_SPEC" "$luci"
		validate_package_name "$luci" luci-app-ax9000-fan
		resolve_hash_spec "$LUCI_SHA256_SPEC" "$luci_name" luci
		luci_hash=$RESOLVED_HASH
		verify_hash "$luci" "$luci_hash" luci
	fi
}

install_flow() {
	[ -n "$PACKAGE_DIR" ] || [ -n "$RELEASE_URL" ] || die 'specify --package-dir or --release-url'
	[ -z "$PACKAGE_DIR" ] || [ -z "$RELEASE_URL" ] || die 'choose only one package source'
	TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ax9000-fan.XXXXXX") || die 'unable to create a private temporary directory'
	chmod 700 "$TMP_DIR" 2>/dev/null || true
	core=
	luci=
	if [ -n "$PACKAGE_DIR" ]; then
		[ -d "$PACKAGE_DIR" ] || die "package directory not found: $PACKAGE_DIR"
		prepare_local_core
		prepare_local_luci
	else
		prepare_remote_packages
	fi
	note "board=$board arch=$ARCH package-manager=$PM"
	note "core=$core (SHA256 verified)"
	[ -z "$luci" ] || note "luci=$luci (SHA256 verified)"
	if [ "$DRY_RUN" -eq 1 ]; then
		note "DRY-RUN: install $core with $PM"
		[ -z "$luci" ] || note "DRY-RUN: install $luci with $PM"
		note 'DRY-RUN: no package changes made'
		return 0
	fi
	core_already=0
	pm_is_installed ax9000-fan-control && core_already=1 || true
	if ! pm_install "$core"; then
		if [ "$core_already" -eq 0 ] && pm_is_installed ax9000-fan-control; then pm_remove ax9000-fan-control || true; fi
		die 'core package installation failed; rollback attempted when needed'
	fi
	if [ -n "$luci" ] && ! pm_install "$luci"; then
		if [ "$core_already" -eq 0 ]; then pm_remove ax9000-fan-control || true; fi
		die 'LuCI package installation failed; core rollback attempted'
	fi
	note 'AX9000 fan core and optional LuCI package installed successfully.'
}

parse_args "$@"
validate_options
board=$(read_board) || die 'unable to determine board; refusing to continue'
supported_board "$board" || die "unsupported board '$board'; only xiaomi,ax9000 and xiaomi,ax9000-darkyun are allowed"
detect_pm
ARCH=$(read_arch) || die 'unable to determine target architecture; use --arch explicitly'
case "$ARCH" in ''|*[!A-Za-z0-9_.+-]*) die "invalid architecture value: $ARCH" ;; esac

if [ "$UNINSTALL" -eq 1 ]; then uninstall_flow; else install_flow; fi

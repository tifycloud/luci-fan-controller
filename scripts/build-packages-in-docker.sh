#!/bin/sh
# Build the AX9000 fan packages with the official OpenWrt 25.12.5 SDK.
#
# The SDK and the build tree live in a Docker named volume.  Only the source
# package directories are read from the host, which avoids relying on a
# case-sensitive host bind mount for the actual OpenWrt build.
set -eu

SCRIPT_DIR=$(dirname -- "$0")
CDPATH=
SCRIPT_DIR=$(cd -- "$SCRIPT_DIR" && pwd -P)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
DIST_DIR=${DIST_DIR:-"$PROJECT_DIR/dist"}

SDK_BASENAME=openwrt-sdk-25.12.5-qualcommax-ipq807x_gcc-14.3.0_musl.Linux-x86_64
SDK_URL=https://downloads.openwrt.org/releases/25.12.5/targets/qualcommax/ipq807x/${SDK_BASENAME}.tar.zst
SDK_SHA256=7aabdda8607c372cb0fd526f0eede2f680ae7d95a4758a38bbb49381e5c97621
DOCKER_PLATFORM=linux/amd64
DOCKER_IMAGE_TAG=ubuntu:24.04
DOCKER_IMAGE_DIGEST=sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea
DOCKER_IMAGE=ubuntu@${DOCKER_IMAGE_DIGEST}
VOLUME_NAME=${OPENWRT_SDK_VOLUME:-ax9000-fan-sdk-25125}
RUN_NAME=ax9000-fan-build-$$
DOCKER_IMAGE_ID=
DOCKER_IMAGE_REPO_DIGEST=$DOCKER_IMAGE_DIGEST
RUN_IMAGE_ID=
RUN_REPO_DIGEST=

die() {
	printf '%s\n' "build-packages-in-docker: $*" >&2
	exit 1
}

info() {
	printf '%s\n' "build-packages-in-docker: $*"
}

command -v docker >/dev/null 2>&1 || die "Docker is required"
docker info >/dev/null 2>&1 || die "Docker daemon is not reachable"

[ -d "$PROJECT_DIR/controller" ] || die "missing controller package directory"
[ -f "$PROJECT_DIR/controller/Makefile" ] || die "missing controller package Makefile"
[ -d "$PROJECT_DIR/luci" ] || die "missing LuCI package directory"
[ -f "$PROJECT_DIR/luci/Makefile" ] || die "missing LuCI package Makefile"

[ ! -L "$DIST_DIR" ] || die "dist directory must not be a symlink"

mkdir -p "$DIST_DIR"

# Do not follow or replace symlinks at any artifact path. This catches broken
# symlinks as well as links to files outside the repository.
for existing in \
	"$DIST_DIR/BUILD-INFO" "$DIST_DIR/BUILD-DEPENDENCIES" "$DIST_DIR/SHA256SUMS" \
	"$DIST_DIR"/ax9000-fan-control_*.ipk \
	"$DIST_DIR"/luci-app-ax9000-fan_*.ipk \
	"$DIST_DIR"/ax9000-fan-control_*.ipk.sha256 \
	"$DIST_DIR"/luci-app-ax9000-fan_*.ipk.sha256 \
	"$DIST_DIR"/ax9000-fan-control-*.apk \
	"$DIST_DIR"/luci-app-ax9000-fan-*.apk \
	"$DIST_DIR"/ax9000-fan-control-*.apk.sha256 \
	"$DIST_DIR"/luci-app-ax9000-fan-*.apk.sha256; do
	[ -e "$existing" ] || [ -L "$existing" ] || continue
	[ ! -L "$existing" ] || die "dist artifact is a symlink: $existing"
done
for stale in "$DIST_DIR"/.ax9000-fan-dist.*; do
	[ -e "$stale" ] || [ -L "$stale" ] || continue
	die "dist contains stale temporary staging path: $stale"
done

# Never overwrite an unrecognised dist directory.  A successful build writes
# this marker, so rerunning the script can replace only its own artifacts.
if [ -e "$DIST_DIR/BUILD-INFO" ]; then
	grep -F -x 'generated-by=ax9000-fan-build-packages-in-docker' "$DIST_DIR/BUILD-INFO" >/dev/null 2>&1 \
		|| die "dist/BUILD-INFO is not owned by this builder; remove or move it manually"
else
	set -- "$DIST_DIR"/ax9000-fan-control_*.ipk "$DIST_DIR"/luci-app-ax9000-fan_*.ipk \
		"$DIST_DIR"/ax9000-fan-control-*.apk "$DIST_DIR"/luci-app-ax9000-fan-*.apk "$DIST_DIR"/SHA256SUMS \
		"$DIST_DIR"/BUILD-DEPENDENCIES \
		"$DIST_DIR"/ax9000-fan-control_*.ipk.sha256 "$DIST_DIR"/luci-app-ax9000-fan_*.ipk.sha256 \
		"$DIST_DIR"/ax9000-fan-control-*.apk.sha256 "$DIST_DIR"/luci-app-ax9000-fan-*.apk.sha256
	for existing in "$@"; do
		[ -e "$existing" ] || continue
		die "dist contains artifacts without BUILD-INFO: $existing"
	done
fi

if docker inspect "$RUN_NAME" >/dev/null 2>&1; then
	die "temporary container already exists: $RUN_NAME"
fi

docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1 || docker volume create "$VOLUME_NAME" >/dev/null

STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ax9000-fan-build.XXXXXX")
DIST_TMP=
cleanup() {
	rc=$?
	rm -rf "$STAGE_DIR"
	if [ -n "$DIST_TMP" ]; then
		rm -rf "$DIST_TMP"
	fi
	docker rm -f "$RUN_NAME" >/dev/null 2>&1 || true
	exit "$rc"
}
trap cleanup EXIT HUP INT TERM

info "building with $SDK_BASENAME on $DOCKER_PLATFORM (volume: $VOLUME_NAME)"

# Capture the local image ID when available. The immutable digest reference is
# always recorded; the actual image ID is verified after docker run starts.
DOCKER_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$DOCKER_IMAGE" 2>/dev/null || printf '%s' '')

# The container intentionally receives the source tree read-only.  All SDK
# extraction, feed checkout, compilation and artifact assembly happen in the
# named volume and therefore use Linux filesystem semantics.
docker run --interactive --platform "$DOCKER_PLATFORM" --name "$RUN_NAME" \
	--volume "$VOLUME_NAME:/work" \
	--volume "$PROJECT_DIR:/input:ro" \
	--env SDK_URL="$SDK_URL" \
	--env SDK_SHA256="$SDK_SHA256" \
	--env SDK_BASENAME="$SDK_BASENAME" \
	--env DOCKER_PLATFORM="$DOCKER_PLATFORM" \
	--env DOCKER_IMAGE="$DOCKER_IMAGE" \
	--env DOCKER_IMAGE_TAG="$DOCKER_IMAGE_TAG" \
	--env DOCKER_IMAGE_DIGEST="$DOCKER_IMAGE_DIGEST" \
	--env DOCKER_IMAGE_ID="$DOCKER_IMAGE_ID" \
	--env DOCKER_IMAGE_REPO_DIGEST="$DOCKER_IMAGE_REPO_DIGEST" \
	--env OPENWRT_BUILD_JOBS="${OPENWRT_BUILD_JOBS:-1}" \
	"$DOCKER_IMAGE" sh -eu <<'CONTAINER_SCRIPT'
set -eu

die() {
	printf '%s\n' "container build: $*" >&2
	exit 1
}

info() {
	printf '%s\n' "container build: $*"
}

[ "$(uname -m)" = x86_64 ] || die "Docker did not provide linux/amd64 (uname: $(uname -m))"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
	bc bison build-essential bzip2 ca-certificates curl file flex g++ gawk gettext \
	git libelf-dev libncurses-dev libssl-dev make python3 python3-dev python3-setuptools \
	python3-venv rsync swig tar unzip wget xz-utils zstd
WGET_VERSION=$(wget --version 2>/dev/null | sed -n '1p')
printf '%s\n' "$WGET_VERSION" | grep -F 'GNU Wget' >/dev/null 2>&1 \
	|| die "GNU Wget is unavailable after dependency installation"
info "verified $WGET_VERSION"
if apt-cache policy python3-distutils 2>/dev/null | awk '$1 == "Candidate:" && $2 != "(none)" { found = 1 } END { exit !found }'; then
	apt-get install -y --no-install-recommends python3-distutils
fi
rm -rf /var/lib/apt/lists/*

WORK=/work
INPUT=/input
CACHE="$WORK/cache"
SDK_TARBALL="$CACHE/$SDK_BASENAME.tar.zst"
SDK_DIR="$WORK/sdk"
SDK_EXTRACT="$WORK/.sdk-extract"
SOURCE_DIR="$WORK/source"
OUTPUT_DIR="$WORK/output"
BUILD_DEPENDENCIES="$WORK/BUILD-DEPENDENCIES"
mkdir -p "$CACHE" "$WORK"
LC_ALL=C dpkg-query -W -f='${binary:Package}\t${Version}\n' | LC_ALL=C sort > "$BUILD_DEPENDENCIES"
[ -s "$BUILD_DEPENDENCIES" ] || die 'build dependency manifest is empty'
LOCK_DIR="$WORK/.ax9000-fan-build.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
	die "SDK volume is already being used by another build"
fi
trap 'rm -rf "$LOCK_DIR"' EXIT HUP INT TERM

if [ -f "$INPUT/.cache/$SDK_BASENAME.tar.zst" ]; then
	if [ ! -f "$SDK_TARBALL" ]; then
		info "copying SDK from host cache"
		cp -f "$INPUT/.cache/$SDK_BASENAME.tar.zst" "$SDK_TARBALL"
	fi
fi

if [ ! -f "$SDK_TARBALL" ]; then
	info "downloading official SDK"
	curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 30 --output "$SDK_TARBALL.tmp" "$SDK_URL"
	mv -f "$SDK_TARBALL.tmp" "$SDK_TARBALL"
fi

printf '%s  %s\n' "$SDK_SHA256" "$SDK_TARBALL" | sha256sum -c - >/dev/null \
	|| die "SDK SHA-256 mismatch"

if [ -e "$SDK_DIR" ]; then
	[ -f "$SDK_DIR/.companywrt-sdk-info" ] || die "SDK volume state is incomplete; remove volume $VOLUME_NAME manually"
	grep -F -x "sdk_sha256=$SDK_SHA256" "$SDK_DIR/.companywrt-sdk-info" >/dev/null 2>&1 \
		|| die "SDK volume contains a different SDK; remove volume $VOLUME_NAME manually"
else
	info "extracting official SDK"
	rm -rf "$SDK_EXTRACT"
	mkdir -p "$SDK_EXTRACT"
	tar --zstd --extract --file "$SDK_TARBALL" --directory "$SDK_EXTRACT"
	[ -d "$SDK_EXTRACT/$SDK_BASENAME" ] || die "SDK archive has an unexpected top-level directory"
	mv "$SDK_EXTRACT/$SDK_BASENAME" "$SDK_DIR"
	rmdir "$SDK_EXTRACT" 2>/dev/null || true
	{
		printf '%s\n' 'generated-by=ax9000-fan-build-packages-in-docker'
		printf 'sdk_url=%s\n' "$SDK_URL"
		printf 'sdk_sha256=%s\n' "$SDK_SHA256"
		printf 'sdk_basename=%s\n' "$SDK_BASENAME"
	} > "$SDK_DIR/.companywrt-sdk-info"
fi

cd "$SDK_DIR"

# A previous successful build leaves the deliberate xz no-LTO workaround in
# the feed checkout. Restore that one known patch before feed attestation so a
# rerun still proves the repository itself is pinned and clean; the exact
# patch is reapplied after the dependency audit below.
XZ_MAKEFILE="$SDK_DIR/feeds/packages/utils/xz/Makefile"
XZ_MAKEFILE_ORIGINAL_SHA=65c1864343e3075cbc59d60dce1855f0c2b0aabda672ceb9c3889eccc5b2ae81
XZ_MAKEFILE_PATCHED_SHA=db8116e9ebc2c5fb9a410e49e7be83e949470848026f087a3d5e22f652543406
if [ -f "$XZ_MAKEFILE" ]; then
	XZ_MAKEFILE_CURRENT_SHA=$(sha256sum "$XZ_MAKEFILE" | awk '{print $1}')
	case "$XZ_MAKEFILE_CURRENT_SHA" in
		"$XZ_MAKEFILE_ORIGINAL_SHA")
			;;
		"$XZ_MAKEFILE_PATCHED_SHA")
			[ "$(grep -c '^PKG_BUILD_FLAGS:=no-lto$' "$XZ_MAKEFILE")" -eq 1 ] \
				|| die 'known xz workaround SHA has an unexpected declaration'
			sed -i 's/^PKG_BUILD_FLAGS:=no-lto$/PKG_BUILD_FLAGS:=lto/' "$XZ_MAKEFILE"
			[ "$(sha256sum "$XZ_MAKEFILE" | awk '{print $1}')" = "$XZ_MAKEFILE_ORIGINAL_SHA" ] \
				|| die 'failed to restore the pinned xz Makefile before feed attestation'
			;;
		*) die "unexpected existing xz Makefile SHA: $XZ_MAKEFILE_CURRENT_SHA" ;;
	esac
fi

# The official SDK ships these exact feed pins. Refuse to build if a future
# SDK silently changes a feed revision or adds an unreviewed feed, then update
# all feeds from those pins.
cat > "$WORK/feeds.expected" <<'FEEDS'
src-git --root=package base https://git.openwrt.org/openwrt/openwrt.git^f0a60eee2fe051741c643ea6118718aae1ef17fb
src-git packages https://git.openwrt.org/feed/packages.git^5caa62e0bc9f7fb9b0c12a23267bceb7724214dd
src-git luci https://git.openwrt.org/project/luci.git^128a7812f4be233c5dd7f7466f534fd888785caf
src-git routing https://git.openwrt.org/feed/routing.git^3d7d0dc7fa43d3eb09498417407e95a6552e5312
src-git telephony https://git.openwrt.org/feed/telephony.git^2618106d5846a4a542fdf5809f0d3ed228ce439b
src-git video https://github.com/openwrt/video.git^094bf58da6682f895255a35a84349a79dab4bf95
FEEDS
sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' -e '/^$/d' feeds.conf.default \
	> "$WORK/feeds.actual"
diff -u "$WORK/feeds.expected" "$WORK/feeds.actual" >/dev/null 2>&1 \
	|| die 'feeds.conf.default contains an unexpected feed declaration'

info "updating fixed OpenWrt feeds"
./scripts/feeds update -a
./scripts/feeds install -a

FEED_REVISIONS='base_root:f0a60eee2fe051741c643ea6118718aae1ef17fb packages:5caa62e0bc9f7fb9b0c12a23267bceb7724214dd luci:128a7812f4be233c5dd7f7466f534fd888785caf routing:3d7d0dc7fa43d3eb09498417407e95a6552e5312 telephony:2618106d5846a4a542fdf5809f0d3ed228ce439b video:094bf58da6682f895255a35a84349a79dab4bf95'
for feed_revision in $FEED_REVISIONS; do
	feed=${feed_revision%%:*}
	expected_revision=${feed_revision#*:}
	[ -d "feeds/$feed" ] || die "fixed feed repository is missing: $feed"
	actual_revision=$(git -C "feeds/$feed" rev-parse HEAD 2>/dev/null) \
		|| die "cannot read fixed feed HEAD: $feed"
	[ "$actual_revision" = "$expected_revision" ] \
		|| die "fixed feed HEAD mismatch for $feed: $actual_revision"
	feed_status=$(git -C "feeds/$feed" status --porcelain --untracked-files=all 2>/dev/null) \
		|| die "cannot read fixed feed status: $feed"
	[ -z "$feed_status" ] \
		|| die "fixed feed has uncommitted or untracked files: $feed"
done

rm -rf package/ax9000-fan-control package/luci-app-ax9000-fan
mkdir -p package
cp -a "$INPUT/controller" package/ax9000-fan-control
cp -a "$INPUT/luci" package/luci-app-ax9000-fan

[ -f package/ax9000-fan-control/Makefile ] || die "core package copy failed"
[ -f package/luci-app-ax9000-fan/Makefile ] || die "LuCI package copy failed"

# Require the exact official SDK Kconfig source and leave it unchanged. The
# target/profile defaults are part of the official SDK contract; package
# compilation below is scoped by each local package's dependency closure.
CONFIG_BUILD_FILE="$SDK_DIR/Config-build.in"
CONFIG_BUILD_ORIGINAL_SHA=c8da54cc4a6c735b794c8a15d71b0acf647a90d48569a5a2a16ff3b02cdef9c0
[ -f "$CONFIG_BUILD_FILE" ] || die 'SDK Config-build.in is missing'
CONFIG_BUILD_CURRENT_SHA=$(sha256sum "$CONFIG_BUILD_FILE" | awk '{print $1}')
[ "$CONFIG_BUILD_CURRENT_SHA" = "$CONFIG_BUILD_ORIGINAL_SHA" ] \
	|| die "unexpected SDK Config-build.in SHA: $CONFIG_BUILD_CURRENT_SHA"

# Keep the SDK's target/toolchain defaults and select the AX9000 profile. The
# first defconfig materializes the pinned package metadata and dependency map;
# package selections are pruned immediately afterwards, without a second
# defconfig, so the large default profile cannot pull every kernel module into
# a local package build.
cat > .config <<'CONFIG'
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq807x=y
CONFIG_TARGET_MULTI_PROFILE=n
CONFIG_TARGET_ALL_PROFILES=n
CONFIG_TARGET_PER_DEVICE_ROOTFS=n
CONFIG_TARGET_DEVICE_qualcommax_ipq807x_DEVICE_xiaomi_ax9000=y
CONFIG_BUILDBOT=n
CONFIG_ALL=n
CONFIG_ALL_KMODS=n
CONFIG_ALL_NONSHARED=n
CONFIG_USE_APK=n
CONFIG_PACKAGE_ax9000-fan-control=y
CONFIG_PACKAGE_luci-app-ax9000-fan=y
CONFIG
make defconfig
# OpenWrt 25.12's hidden USE_APK symbol has an unconditional default=y in the
# SDK Kconfig. Defconfig therefore restores APK even when the input asks for
# IPK. Prune that one hidden default after defconfig (alongside the runtime
# package closure below) and never invoke defconfig again before compilation.
sed -i '/^CONFIG_USE_APK=/d; /^# CONFIG_USE_APK is not set$/d' .config
printf '%s\n' '# CONFIG_USE_APK is not set' >> .config
assert_ipk_mode() {
	[ "$(grep -F -x '# CONFIG_USE_APK is not set' .config | wc -l | tr -d ' ')" -eq 1 ] \
		|| die 'SDK IPK mode prune produced an unexpected USE_APK state'
	if grep -E '^CONFIG_USE_APK=' .config >/dev/null 2>&1; then
		die 'SDK IPK mode prune left CONFIG_USE_APK enabled'
	fi
}
assert_ipk_mode
grep -F -x 'CONFIG_PACKAGE_ax9000-fan-control=y' .config >/dev/null || die 'core package was not selected'
grep -F -x 'CONFIG_PACKAGE_luci-app-ax9000-fan=y' .config >/dev/null || die 'LuCI package was not selected'

# Resolve the runtime dependency closure from the pinned SDK metadata. This
# evaluates Kconfig conditionals (for example USE_MUSL and
# PACKAGE_kmod-thermal) instead of blindly splitting a colon expression.
cat > "$WORK/runtime-roots.list" <<'RUNTIME_ROOTS'
ax9000-fan-control
luci-app-ax9000-fan
RUNTIME_ROOTS
cat > "$WORK/runtime-packages.expected" <<'RUNTIME_EXPECTED'
ax9000-fan-control
cgi-io
i2c-tools
kmod-hwmon-core
kmod-hwmon-emc2305
kmod-i2c-core
kmod-regmap-core
kmod-regmap-i2c
kmod-thermal
libblobmsg-json
libc
libgcc
libi2c
libiwinfo
libiwinfo-data
libjson-c
liblucihttp
liblucihttp-ucode
libnl-tiny
libubox
libubus
libuci
libucode
luci-app-ax9000-fan
luci-base
luci-lib-uqr
luci-mod-admin-full
luci-mod-network
luci-mod-status
luci-mod-system
rpcd
rpcd-mod-file
rpcd-mod-iwinfo
rpcd-mod-luci
rpcd-mod-ucode
ucode
ucode-mod-fs
ucode-mod-html
ucode-mod-log
ucode-mod-math
ucode-mod-ubus
ucode-mod-uci
RUNTIME_EXPECTED
python3 - "$SDK_DIR/tmp/.packageinfo" "$SDK_DIR/.config" "$WORK/runtime-roots.list" "$WORK/runtime-packages.list" "$WORK/runtime-selected-config.list" <<'PY'
import collections
import os
import re
import sys

packageinfo, config_path, roots_path, output_path, selected_config_path = sys.argv[1:]

packages = {}
current = None
with open(packageinfo, encoding="utf-8", errors="replace") as stream:
    for raw in stream:
        line = raw.rstrip("\n")
        if line.startswith("Package: "):
            name = line[len("Package: "):].strip()
            current = {"name": name, "depends": ""}
            packages.setdefault(name, []).append(current)
        elif current is not None and line.startswith("Depends: "):
            current["depends"] = line[len("Depends: "):].strip()

config = {}
with open(config_path, encoding="utf-8", errors="replace") as stream:
    for raw in stream:
        line = raw.rstrip("\n")
        match = re.match(r"CONFIG_([^=]+)=(.*)$", line)
        if match:
            config[match.group(1)] = match.group(2).strip() in ("y", "m", "1")
            continue
        match = re.match(r"# CONFIG_([^ ]+) is not set$", line)
        if match:
            config[match.group(1)] = False


class ConditionParser:
    token_re = re.compile(r"&&|\|\||!|\(|\)|[A-Za-z0-9_.-]+")

    def __init__(self, expression):
        self.expression = expression.lstrip("@")
        self.tokens = []
        position = 0
        while position < len(self.expression):
            if self.expression[position].isspace():
                position += 1
                continue
            match = self.token_re.match(self.expression, position)
            if match is None:
                raise ValueError("unsupported Kconfig condition: %s" % expression)
            self.tokens.append(match.group(0))
            position = match.end()
        self.position = 0

    def parse(self):
        value = self.parse_or()
        if self.position != len(self.tokens):
            raise ValueError("trailing Kconfig condition: %s" % self.expression)
        return value

    def parse_or(self):
        value = self.parse_and()
        while self.position < len(self.tokens) and self.tokens[self.position] == "||":
            self.position += 1
            right = self.parse_and()
            value = value or right
        return value

    def parse_and(self):
        value = self.parse_not()
        while self.position < len(self.tokens) and self.tokens[self.position] == "&&":
            self.position += 1
            right = self.parse_not()
            value = value and right
        return value

    def parse_not(self):
        if self.position < len(self.tokens) and self.tokens[self.position] == "!":
            self.position += 1
            return not self.parse_not()
        if self.position < len(self.tokens) and self.tokens[self.position] == "(":
            self.position += 1
            value = self.parse_or()
            if self.position >= len(self.tokens) or self.tokens[self.position] != ")":
                raise ValueError("unclosed Kconfig condition: %s" % self.expression)
            self.position += 1
            return value
        if self.position >= len(self.tokens):
            raise ValueError("empty Kconfig condition: %s" % self.expression)
        symbol = self.tokens[self.position]
        self.position += 1
        return config.get(symbol, False)


def condition_enabled(expression):
    return ConditionParser(expression).parse()


def dependencies(name):
    result = []
    entries = packages[name]
    dependency_text = {entry["depends"] for entry in entries}
    if len(dependency_text) != 1:
        raise SystemExit("ambiguous duplicate package metadata: %s" % name)
    for token in entries[0]["depends"].split():
        token = token.rstrip(",")
        if not token or token.startswith("@"):
            continue
        if token.startswith("+"):
            token = token[1:]
        if ":" in token:
            condition, target = token.split(":", 1)
            if not condition_enabled(condition):
                continue
            token = target
        if token and not token.startswith("@"):
            result.append(token)
    return result


with open(roots_path, encoding="utf-8") as stream:
    roots = [line.strip() for line in stream if line.strip()]
if sorted(roots) != ["ax9000-fan-control", "luci-app-ax9000-fan"]:
    raise SystemExit("runtime roots changed unexpectedly")

seen = []
queue = collections.deque(roots)
while queue:
    name = queue.popleft()
    if name in seen:
        continue
    if name not in packages:
        raise SystemExit("runtime dependency has no pinned metadata: %s" % name)
    seen.append(name)
    for dependency in dependencies(name):
        if dependency not in packages:
            raise SystemExit("runtime dependency has no pinned metadata: %s -> %s" % (name, dependency))
        if dependency not in seen:
            queue.append(dependency)

runtime = sorted(seen)
if len(runtime) != 42:
    raise SystemExit("unexpected runtime closure cardinality: %d" % len(runtime))
with open(output_path, "w", encoding="utf-8") as stream:
    stream.write("\n".join(runtime) + "\n")

# Prune every package symbol selected by the SDK defaults. Preserve the y/m
# state chosen by defconfig for the exact runtime closure; hidden entries
# absent from the rendered config are explicitly selected as y.
lines = []
selected = set()
with open(config_path, encoding="utf-8", errors="replace") as stream:
    for raw in stream:
        line = raw.rstrip("\n")
        match = re.match(r"CONFIG_PACKAGE_([^=]+)=(.*)$", line)
        if match:
            name, value = match.groups()
            if name in runtime:
                if value not in ("y", "m"):
                    value = "y"
                lines.append("CONFIG_PACKAGE_%s=%s" % (name, value))
                selected.add(name)
            else:
                lines.append("# CONFIG_PACKAGE_%s is not set" % name)
            continue
        match = re.match(r"# CONFIG_PACKAGE_([^ ]+) is not set$", line)
        if match and match.group(1) in runtime:
            name = match.group(1)
            lines.append("CONFIG_PACKAGE_%s=y" % name)
            selected.add(name)
            continue
        lines.append(line)

missing = sorted(set(runtime) - selected)
if missing:
    lines.append("")
    lines.extend("CONFIG_PACKAGE_%s=y" % name for name in missing)
with open(config_path + ".tmp", "w", encoding="utf-8") as stream:
    stream.write("\n".join(lines) + "\n")
os.replace(config_path + ".tmp", config_path)
with open(selected_config_path, "w", encoding="utf-8") as stream:
    stream.write("\n".join(sorted(selected | set(missing))) + "\n")
PY
diff -u "$WORK/runtime-packages.expected" "$WORK/runtime-packages.list" >/dev/null 2>&1 \
	|| die 'pinned runtime dependency closure changed unexpectedly'
diff -u "$WORK/runtime-packages.list" "$WORK/runtime-selected-config.list" >/dev/null 2>&1 \
	|| die 'runtime prune did not select the exact closure'

audit_package_config() {
	config_file=$1
	selected_file=$2
	[ -f "$config_file" ] || die "SDK config output is missing: $config_file"
	sed -n 's/^CONFIG_PACKAGE_\([^=]*\)=\(y\|m\)$/\1/p' "$config_file" | sort -u > "$selected_file"
	[ -s "$selected_file" ] || die "selected no packages: $config_file"
}
SELECTED_PACKAGES="$WORK/selected-package-symbols.list"
audit_package_config .config "$SELECTED_PACKAGES"
diff -u "$WORK/runtime-packages.list" "$SELECTED_PACKAGES" >/dev/null 2>&1 \
	|| die 'selected package symbols are outside the runtime closure'
grep '^kmod-' "$WORK/runtime-packages.list" > "$WORK/runtime-kmods.list"
grep '^kmod-' "$SELECTED_PACKAGES" > "$WORK/selected-kmods.list"
diff -u "$WORK/runtime-kmods.list" "$WORK/selected-kmods.list" >/dev/null 2>&1 \
	|| die 'selected kernel modules are outside the runtime closure'

# The SDK-generated dependency map is the authoritative compile closure for
# this package pair.  Verify it contains exactly the small, expected closure
# and retain the normalized lists for post-build auditing/BUILD-INFO.
[ -s tmp/.packagedeps ] || die 'SDK did not generate tmp/.packagedeps'
CORE_DEPS="$WORK/core-packagedeps.list"
LUCI_DEPS="$WORK/luci-packagedeps.list"
sed -n 's#^$(curdir)/ax9000-fan-control/compile += ##p' tmp/.packagedeps \
	| tr ' ' '\n' | sed '/^$/d' | sort > "$CORE_DEPS"
sed -n 's#^$(curdir)/luci-app-ax9000-fan/compile += ##p' tmp/.packagedeps \
	| tr ' ' '\n' | sed '/^$/d' | sort > "$LUCI_DEPS"
[ -s "$CORE_DEPS" ] && [ -s "$LUCI_DEPS" ] || die 'local package dependency closure is missing'
printf '%s\n' \
	'$(curdir)/feeds/base/linux/compile' \
	'$(curdir)/feeds/base/toolchain/compile' \
	'$(curdir)/feeds/packages/i2c-tools/compile' | sort > "$WORK/core-packagedeps.expected"
printf '%s\n' \
	'$(curdir)/ax9000-fan-control/compile' \
	'$(curdir)/feeds/base/rpcd/compile' \
	'$(curdir)/feeds/base/toolchain/compile' \
	'$(curdir)/feeds/luci/luci-base/compile' \
	'$(curdir)/feeds/luci/luci-mod-admin-full/compile' | sort > "$WORK/luci-packagedeps.expected"
diff -u "$WORK/core-packagedeps.expected" "$CORE_DEPS" >/dev/null 2>&1 \
	|| die 'core package dependency closure changed unexpectedly'
diff -u "$WORK/luci-packagedeps.expected" "$LUCI_DEPS" >/dev/null 2>&1 \
	|| die 'LuCI package dependency closure changed unexpectedly'

# OpenWrt's pinned xz feed enables LTO explicitly. GCC 14.3.0 can hit an LTO
# ICE under Docker linux/amd64 emulation, so apply one exact, auditable feed
# patch. Refuse every other source revision and make the operation idempotent.
[ -f "$XZ_MAKEFILE" ] || die 'pinned xz Makefile is missing'
XZ_MAKEFILE_CURRENT_SHA=$(sha256sum "$XZ_MAKEFILE" | awk '{print $1}')
case "$XZ_MAKEFILE_CURRENT_SHA" in
	"$XZ_MAKEFILE_ORIGINAL_SHA")
		[ "$(grep -c '^PKG_BUILD_FLAGS:=lto$' "$XZ_MAKEFILE")" -eq 1 ] \
			|| die 'pinned xz Makefile has an unexpected LTO declaration'
		sed -i 's/^PKG_BUILD_FLAGS:=lto$/PKG_BUILD_FLAGS:=no-lto/' "$XZ_MAKEFILE"
		;;
	"$XZ_MAKEFILE_PATCHED_SHA")
		;;
	*) die "unexpected pinned xz Makefile SHA: $XZ_MAKEFILE_CURRENT_SHA" ;;
esac
XZ_MAKEFILE_CURRENT_SHA=$(sha256sum "$XZ_MAKEFILE" | awk '{print $1}')
[ "$XZ_MAKEFILE_CURRENT_SHA" = "$XZ_MAKEFILE_PATCHED_SHA" ] \
	|| die "xz Makefile patch SHA mismatch: $XZ_MAKEFILE_CURRENT_SHA"
[ "$(grep -c '^PKG_BUILD_FLAGS:=no-lto$' "$XZ_MAKEFILE")" -eq 1 ] \
	|| die 'xz Makefile no-LTO patch is not exact'

# OPENWRT_BUILD=1 selects the SDK's direct package branch and therefore skips
# include/toplevel.mk, which normally exports these host tuple variables. Keep
# the direct clean/compile calls semantically identical to the official
# toplevel invocation, and fail closed if Docker is not the pinned amd64 Linux
# environment used by this builder.
GNU_HOST_NAME=$(./scripts/config.guess)
HOST_OS=$(uname -s)
HOST_ARCH=$(uname -m)
[ "$GNU_HOST_NAME" = 'x86_64-pc-linux-gnu' ] \
	|| die "unexpected GNU_HOST_NAME: $GNU_HOST_NAME"
[ "$HOST_OS" = 'Linux' ] || die "unexpected HOST_OS: $HOST_OS"
[ "$HOST_ARCH" = 'x86_64' ] || die "unexpected HOST_ARCH: $HOST_ARCH"
export GNU_HOST_NAME HOST_OS HOST_ARCH

# The direct package branch also skips include/version.mk.  Reuse the pinned
# SDK values rather than deriving timestamps or revisions from the host, and
# export them for both clean and compile invocations.
VERSION_FILE="$SDK_DIR/include/version.mk"
[ -f "$VERSION_FILE" ] || die 'SDK include/version.mk is missing'
[ "$(grep -c '^REVISION:=' "$VERSION_FILE")" -eq 1 ] \
	|| die 'SDK include/version.mk has an unexpected REVISION declaration'
[ "$(grep -c '^SOURCE_DATE_EPOCH:=' "$VERSION_FILE")" -eq 1 ] \
	|| die 'SDK include/version.mk has an unexpected SOURCE_DATE_EPOCH declaration'
REVISION=$(sed -n 's/^REVISION:=//p' "$VERSION_FILE")
SOURCE_DATE_EPOCH=$(sed -n 's/^SOURCE_DATE_EPOCH:=//p' "$VERSION_FILE")
[ "$REVISION" = 'r33051-f5dae5ece4' ] \
	|| die "unexpected SDK REVISION: $REVISION"
[ "$SOURCE_DATE_EPOCH" = '1782737960' ] \
	|| die "unexpected SDK SOURCE_DATE_EPOCH: $SOURCE_DATE_EPOCH"
export REVISION SOURCE_DATE_EPOCH

find bin/packages -type f \( -name 'ax9000-fan-control_*.ipk' -o -name 'luci-app-ax9000-fan_*.ipk' \) -delete 2>/dev/null || true
# OPENWRT_BUILD=1 intentionally bypasses the SDK toplevel.mk.  In that mode
# verbose.mk's default SUBMAKE function is expanded inline after time.pl and
# is not valid shell syntax; V=s selects the official direct-submake form.
CLEAN_MAKEFLAGS='V=s'
[ "$CLEAN_MAKEFLAGS" = 'V=s' ] || die 'clean must run with the reproducible V=s make mode'
OPENWRT_BUILD=1 make package/ax9000-fan-control/clean package/luci-app-ax9000-fan/clean "$CLEAN_MAKEFLAGS"
assert_ipk_mode
audit_package_config .config "$SELECTED_PACKAGES"
diff -u "$WORK/runtime-packages.list" "$SELECTED_PACKAGES" >/dev/null 2>&1 \
	|| die 'clean target changed selected package symbols'
grep '^kmod-' "$SELECTED_PACKAGES" > "$WORK/selected-kmods.list"
diff -u "$WORK/runtime-kmods.list" "$WORK/selected-kmods.list" >/dev/null 2>&1 \
	|| die 'clean target changed selected kernel modules'
BUILD_JOBS=${OPENWRT_BUILD_JOBS:-1}
case "$BUILD_JOBS" in
	''|*[!0-9]*) die 'OPENWRT_BUILD_JOBS must be a positive integer' ;;
esac
[ "$BUILD_JOBS" -ge 1 ] || die 'OPENWRT_BUILD_JOBS must be at least 1'
[ "$BUILD_JOBS" -eq 1 ] || die 'OPENWRT_BUILD_JOBS must be exactly 1 for reproducible SDK builds'
COMPILE_LOG="$WORK/package-compile.log"
info "compiling the two local IPK packages with -j$BUILD_JOBS (V=s)"
assert_ipk_mode
if ! OPENWRT_BUILD=1 make package/ax9000-fan-control/compile package/luci-app-ax9000-fan/compile \
	-j"$BUILD_JOBS" V=s > "$COMPILE_LOG" 2>&1; then
	tail -n 160 "$COMPILE_LOG" >&2 || true
	die "local package compile failed; full V=s log is $COMPILE_LOG"
fi

mkdir -p "$OUTPUT_DIR"
if [ -e "$OUTPUT_DIR/BUILD-INFO" ]; then
	grep -F -x 'generated-by=ax9000-fan-build-packages-in-docker' "$OUTPUT_DIR/BUILD-INFO" >/dev/null 2>&1 \
		|| die 'output directory contains unrecognised BUILD-INFO'
else
	[ "$(find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print | wc -l)" -eq 0 ] \
		|| die 'output directory contains unrecognised stale files'
fi
find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -exec rm -f -- {} +

find bin/packages -type f -name 'ax9000-fan-control_*.ipk' -print > "$WORK/core-ipks.list"
find bin/packages -type f -name 'luci-app-ax9000-fan_*.ipk' -print > "$WORK/luci-ipks.list"
[ "$(wc -l < "$WORK/core-ipks.list")" -eq 1 ] || die 'expected exactly one core IPK'
[ "$(wc -l < "$WORK/luci-ipks.list")" -eq 1 ] || die 'expected exactly one LuCI IPK'
CORE_IPK=$(sed -n '1p' "$WORK/core-ipks.list")
LUCI_IPK=$(sed -n '1p' "$WORK/luci-ipks.list")
cp -f "$CORE_IPK" "$OUTPUT_DIR/"
cp -f "$LUCI_IPK" "$OUTPUT_DIR/"

set -- "$OUTPUT_DIR"/*.ipk
[ "$#" -eq 2 ] || die 'output contains an unexpected number of IPKs'
case "$(basename "$1")" in
	ax9000-fan-control_*.ipk|luci-app-ax9000-fan_*.ipk) ;;
	*) die 'first output IPK name is unexpected' ;;
esac
case "$(basename "$2")" in
	ax9000-fan-control_*.ipk|luci-app-ax9000-fan_*.ipk) ;;
	*) die 'second output IPK name is unexpected' ;;
esac

CORE_OUT=$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name 'ax9000-fan-control_*.ipk' -print)
LUCI_OUT=$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name 'luci-app-ax9000-fan_*.ipk' -print)
[ -n "$CORE_OUT" ] && [ -n "$LUCI_OUT" ] || die 'output IPK cardinality check failed'
[ "$(basename "$CORE_OUT")" = 'ax9000-fan-control_1.0.0-r4_all.ipk' ] \
	|| die "core IPK filename/version is unexpected: $(basename "$CORE_OUT")"
[ "$(basename "$LUCI_OUT")" = 'luci-app-ax9000-fan_1.0.0-r1_all.ipk' ] \
	|| die "LuCI IPK filename/version is unexpected: $(basename "$LUCI_OUT")"

# OpenWrt's legacy opkg package is a gzip-compressed tar produced by the
# official scripts/ipkg-build (debian-binary, control.tar.gz, data.tar.gz).
# Validate the outer and inner member names before extraction, then inspect the
# control metadata and exact installed files. This intentionally does not use
# the APK v3 tooling.
IPK_TAR="$SDK_DIR/staging_dir/host/bin/tar"
[ -x "$IPK_TAR" ] || IPK_TAR=$(command -v tar || true)
[ -n "$IPK_TAR" ] || die 'tar is required for IPK verification'
assert_safe_tar_listing() {
	listing=$1
	if awk '$0 ~ /^\// || $0 ~ /(^|\/)\.\.($|\/)/ { bad = 1 } END { exit bad }' "$listing"; then
		:
	else
		die "IPK archive contains an unsafe path: $listing"
	fi
}
assert_tar_member_types() {
	archive=$1
	label=$2
	types="$WORK/${label}.types"
	"$IPK_TAR" -tvzf "$archive" > "$types" \
		|| die "cannot inspect IPK member types: $archive"
	# GNU tar prints the file type in the first column. Only directories and
	# regular files are accepted; symlinks, hardlinks, devices and FIFOs are
	# never valid in these two package archives.
	if awk 'substr($1, 1, 1) != "d" && substr($1, 1, 1) != "-" { bad = 1 } END { exit bad }' "$types"; then
		:
	else
		die "IPK archive contains a symlink or non-regular member: $archive"
	fi
}
assert_exact_archive_members() {
	archive=$1
	label=$2
	expected=$3
	listing="$WORK/${label}.list"
	"$IPK_TAR" -tzf "$archive" > "$listing" \
		|| die "cannot list IPK archive: $archive"
	assert_safe_tar_listing "$listing"
	printf '%s\n' "$expected" | LC_ALL=C sort > "$WORK/${label}.expected"
	# GNU tar may emit an equivalent member with or without the leading ./.
	# Canonicalize that representation while retaining exact names, types and
	# modes as separate gates below.
	sed -e 's#^\./##' -e 's#^\.$##' -e 's#^#./#' "$listing" \
		| LC_ALL=C sort > "$WORK/${label}.sorted"
	diff -u "$WORK/${label}.expected" "$WORK/${label}.sorted" >/dev/null 2>&1 \
		|| die "IPK $label members are not exact: $archive"
	assert_tar_member_types "$archive" "$label"
}
assert_ipk_outer() {
	package=$1
	label=$2
	assert_exact_archive_members "$package" "${label}.outer" './control.tar.gz
./data.tar.gz
./debian-binary'
}
assert_control_field() {
	control=$1
	field=$2
	expected=$3
	count=$(grep -c "^${field}:" "$control" 2>/dev/null || true)
	[ "$count" -eq 1 ] \
		|| die "IPK control $field occurs $count times in $control (expected exactly once)"
	actual=$(sed -n "s/^${field}:[[:space:]]*//p" "$control" | sed -n '1p')
	[ "$actual" = "$expected" ] \
		|| die "IPK control $field mismatch in $control: $actual"
}
assert_control_dep() {
	depends=$1
	dependency=$2
	printf '%s\n' "$depends" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
		| awk -v expected="$dependency" '$1 == expected { found = 1 } END { exit !found }' \
		|| die "IPK control is missing dependency $dependency"
}
assert_file_mode() {
	path=$1
	expected=$2
	[ -f "$path" ] || die "IPK is missing regular file: $path"
	[ ! -L "$path" ] || die "IPK contains an unexpected symlink: $path"
	actual=$(stat -c '%a' "$path" 2>/dev/null || true)
	[ "$actual" = "$expected" ] || die "IPK file mode mismatch for $path: $actual (expected $expected)"
}
assert_ipk_package() {
	package=$1
	package_label=$2
	expected_name=$3
	expected_version=$4
	# Keep the package label separate from the helper's global `label` variable.
	# assert_ipk_outer() calls assert_exact_archive_members(), both of which
	# assign that variable in POSIX sh; using it below would otherwise turn
	# `core` into `core.outer` and lose the extracted data directory.
	assert_ipk_outer "$package" "$package_label"
	archive_dir="$WORK/${package_label}.archive"
	control_dir="$WORK/${package_label}.control"
	data_dir="$WORK/${package_label}.extract"
	rm -rf "$archive_dir" "$control_dir" "$data_dir"
	mkdir -p "$archive_dir" "$control_dir" "$data_dir"
	"$IPK_TAR" -xzf "$package" -C "$archive_dir" \
		|| die "cannot extract IPK outer archive: $package"
	[ "$(sed -n '1p' "$archive_dir/debian-binary")" = '2.0' ] \
		|| die "IPK debian-binary is not 2.0: $package"
	[ "$(wc -c < "$archive_dir/debian-binary" | tr -d ' ')" -eq 4 ] \
		|| die "IPK debian-binary has unexpected trailing data: $package"
		case "$expected_name" in
		ax9000-fan-control)
			control_members='./
./conffiles
./control
./postinst
./postinst-pkg
./preinst
./prerm
./prerm-pkg'
			data_members='./
./etc/
./etc/config/
./etc/config/ax9000-fan
./etc/init.d/
./etc/init.d/ax9000-fan-control
./usr/
./usr/libexec/
./usr/libexec/ax9000-fan-common
./usr/libexec/ax9000-fan-force-fullspeed
./usr/libexec/ax9000-fan-status
./usr/libexec/ax9000-fan-validate
./usr/sbin/
./usr/sbin/ax9000-fan-control'
			;;
		luci-app-ax9000-fan)
			control_members='./
./control
./postinst
./prerm'
			data_members='./
./usr/
./usr/share/
./usr/share/ax9000-fan/
./usr/share/ax9000-fan/README
./usr/share/luci/
./usr/share/luci/menu.d/
./usr/share/luci/menu.d/luci-app-ax9000-fan.json
./usr/share/rpcd/
./usr/share/rpcd/acl.d/
./usr/share/rpcd/acl.d/luci-app-ax9000-fan.json
./www/
./www/luci-static/
./www/luci-static/resources/
./www/luci-static/resources/view/
./www/luci-static/resources/view/ax9000-fan/
./www/luci-static/resources/view/ax9000-fan/overview.css
./www/luci-static/resources/view/ax9000-fan/overview.js'
			;;
		*) die "unexpected IPK control package name: $expected_name" ;;
	esac
	assert_exact_archive_members "$archive_dir/control.tar.gz" "${package_label}.control" "$control_members"
	assert_exact_archive_members "$archive_dir/data.tar.gz" "${package_label}.data" "$data_members"
	"$IPK_TAR" -xzf "$archive_dir/control.tar.gz" -C "$control_dir" \
		|| die "cannot extract IPK control archive: $package"
	"$IPK_TAR" -xzf "$archive_dir/data.tar.gz" -C "$data_dir" \
		|| die "cannot extract IPK data archive: $package"
	control="$control_dir/control"
	[ -f "$control" ] && [ ! -L "$control" ] \
		|| die "IPK control file is missing or symlinked: $package"
	assert_control_field "$control" Package "$expected_name"
	assert_control_field "$control" Version "$expected_version"
	assert_control_field "$control" Architecture all
	assert_file_mode "$control" 644
	case "$expected_name" in
		ax9000-fan-control)
			assert_file_mode "$control_dir/conffiles" 644
			[ "$(sed -n '1p' "$control_dir/conffiles")" = '/etc/config/ax9000-fan' ] \
				|| die "IPK conffiles does not name the protected UCI file: $package"
			for lifecycle in preinst postinst prerm postinst-pkg prerm-pkg; do
				assert_file_mode "$control_dir/$lifecycle" 755
				grep -F 'IPKG_INSTROOT' "$control_dir/$lifecycle" >/dev/null \
					|| die "IPK $lifecycle lacks IPKG_INSTROOT guard: $package"
			done
			grep -F 'default_postinst' "$control_dir/postinst" >/dev/null \
				|| die 'IPK generic postinst lacks the OpenWrt default_postinst wrapper'
			grep -F 'default_prerm' "$control_dir/prerm" >/dev/null \
				|| die 'IPK generic prerm lacks the OpenWrt default_prerm wrapper'
			grep -F 'xiaomi,ax9000' "$control_dir/preinst" >/dev/null \
				|| die "IPK preinst lacks AX9000 board allowlist: $package"
			grep -F '/etc/init.d/ax9000-fan-control enable' "$control_dir/postinst-pkg" >/dev/null \
				|| die "IPK postinst lacks service enable step: $package"
			grep -F '/etc/init.d/ax9000-fan-control restart' "$control_dir/postinst-pkg" >/dev/null \
				|| die "IPK postinst lacks service restart step: $package"
			grep -F '/usr/libexec/ax9000-fan-force-fullspeed' "$control_dir/prerm-pkg" >/dev/null \
				|| die "IPK prerm lacks full-speed safety step: $package"
			;;
		luci-app-ax9000-fan)
			for lifecycle in postinst prerm; do
				assert_file_mode "$control_dir/$lifecycle" 755
				grep -F 'IPKG_INSTROOT' "$control_dir/$lifecycle" >/dev/null \
					|| die "IPK $lifecycle lacks IPKG_INSTROOT guard: $package"
			 done
			grep -F 'default_postinst' "$control_dir/postinst" >/dev/null \
				|| die 'LuCI IPK generic postinst lacks the OpenWrt default_postinst wrapper'
			grep -F 'default_prerm' "$control_dir/prerm" >/dev/null \
				|| die 'LuCI IPK generic prerm lacks the OpenWrt default_prerm wrapper'
			;;
	esac
	depends_count=$(grep -c '^Depends:' "$control" 2>/dev/null || true)
	[ "$depends_count" -eq 1 ] \
		|| die "IPK control Depends occurs $depends_count times in $control (expected exactly once)"
	depends=$(sed -n 's/^Depends:[[:space:]]*//p' "$control" | sed -n '1p')
	[ -n "$depends" ] || die "IPK control Depends is empty: $package"
	case "$expected_name" in
		ax9000-fan-control)
			for dependency in libc i2c-tools kmod-hwmon-emc2305 kmod-hwmon-core kmod-thermal \
				kmod-i2c-core kmod-regmap-i2c; do
				assert_control_dep "$depends" "$dependency"
			done
			;;
		luci-app-ax9000-fan)
			for dependency in ax9000-fan-control luci-base luci-mod-admin-full rpcd; do
				assert_control_dep "$depends" "$dependency"
			done
			;;
		*) die "unexpected IPK control package name: $expected_name" ;;
	esac
}
assert_ipk_package "$CORE_OUT" core ax9000-fan-control 1.0.0-r4
assert_ipk_package "$LUCI_OUT" luci luci-app-ax9000-fan 1.0.0-r1
rm -rf "$WORK/core-extract" "$WORK/luci-extract"
cp -a "$WORK/core.extract" "$WORK/core-extract"
cp -a "$WORK/luci.extract" "$WORK/luci-extract"
for path in \
	"$WORK/core-extract/etc/init.d/ax9000-fan-control" \
	"$WORK/core-extract/usr/sbin/ax9000-fan-control" \
	"$WORK/core-extract/usr/libexec/ax9000-fan-common" \
	"$WORK/core-extract/usr/libexec/ax9000-fan-force-fullspeed" \
	"$WORK/core-extract/usr/libexec/ax9000-fan-status" \
	"$WORK/core-extract/usr/libexec/ax9000-fan-validate"; do
	assert_file_mode "$path" 755
done
assert_file_mode "$WORK/core-extract/etc/config/ax9000-fan" 600
for path in \
	"$WORK/luci-extract/www/luci-static/resources/view/ax9000-fan/overview.js" \
	"$WORK/luci-extract/www/luci-static/resources/view/ax9000-fan/overview.css" \
	"$WORK/luci-extract/usr/share/luci/menu.d/luci-app-ax9000-fan.json" \
	"$WORK/luci-extract/usr/share/rpcd/acl.d/luci-app-ax9000-fan.json" \
	"$WORK/luci-extract/usr/share/ax9000-fan/README"; do
	assert_file_mode "$path" 644
done
grep -F 'mC < -20000 || mC > 200000' \
	"$WORK/luci-extract/www/luci-static/resources/view/ax9000-fan/overview.js" >/dev/null \
	|| die 'LuCI IPK overview.js lacks the signed mC range guard'

CORE_NAME=$(basename "$CORE_OUT")
LUCI_NAME=$(basename "$LUCI_OUT")
cp -p "$BUILD_DEPENDENCIES" "$OUTPUT_DIR/BUILD-DEPENDENCIES"
[ -s "$OUTPUT_DIR/BUILD-DEPENDENCIES" ] || die 'build dependency manifest was not copied'
BUILD_DEPENDENCIES_SHA=$(sha256sum "$OUTPUT_DIR/BUILD-DEPENDENCIES" | awk '{print $1}')
{
	printf '%s\n' 'generated-by=ax9000-fan-build-packages-in-docker'
	printf 'sdk_url=%s\n' "$SDK_URL"
	printf 'sdk_sha256=%s\n' "$SDK_SHA256"
	printf 'sdk_basename=%s\n' "$SDK_BASENAME"
	printf 'target=qualcommax/ipq807x\n'
	printf 'docker_platform=%s\n' "$DOCKER_PLATFORM"
	printf 'docker_image=%s\n' "$DOCKER_IMAGE"
	printf 'docker_image_tag=%s\n' "$DOCKER_IMAGE_TAG"
	printf 'docker_image_digest=%s\n' "$DOCKER_IMAGE_DIGEST"
	printf 'docker_image_id=%s\n' "$DOCKER_IMAGE_ID"
	printf 'docker_image_repo_digest=%s\n' "$DOCKER_IMAGE_REPO_DIGEST"
	printf 'build_environment_note=%s\n' 'Ubuntu apt dependencies are installed at build time; immutable image digest and runtime image ID are recorded'
	printf 'build_dependencies_file=%s\n' 'BUILD-DEPENDENCIES'
	printf 'build_dependencies_sha256=%s\n' "$BUILD_DEPENDENCIES_SHA"
	printf 'build_jobs=%s\n' "$BUILD_JOBS"
	printf 'openwrt_build=1\n'
	printf 'gnu_host_name=%s\n' "$GNU_HOST_NAME"
	printf 'host_os=%s\n' "$HOST_OS"
	printf 'host_arch=%s\n' "$HOST_ARCH"
	printf 'revision=%s\n' "$REVISION"
	printf 'source_date_epoch=%s\n' "$SOURCE_DATE_EPOCH"
	printf 'xz_makefile_original_sha=%s\n' "$XZ_MAKEFILE_ORIGINAL_SHA"
	printf 'xz_makefile_patched_sha=%s\n' "$XZ_MAKEFILE_PATCHED_SHA"
	printf 'lto_workaround=%s\n' 'exact pinned xz Makefile PKG_BUILD_FLAGS lto-to-no-lto patch (GCC-14 LTO ICE under linux/amd64 emulation)'
	printf 'package_format=ipk\n'
	printf 'feeds=base:f0a60eee2fe051741c643ea6118718aae1ef17fb,packages:5caa62e0bc9f7fb9b0c12a23267bceb7724214dd,luci:128a7812f4be233c5dd7f7466f534fd888785caf,routing:3d7d0dc7fa43d3eb09498417407e95a6552e5312,telephony:2618106d5846a4a542fdf5809f0d3ed228ce439b,video:094bf58da6682f895255a35a84349a79dab4bf95\n'
	printf 'feeds_attested=1\n'
	printf 'core_ipk=%s\n' "$CORE_NAME"
	printf 'luci_ipk=%s\n' "$LUCI_NAME"
	printf 'runtime_packages=%s\n' "$(tr '\n' ',' < "$WORK/runtime-packages.list" | sed 's/,$//')"
	printf 'runtime_package_count=%s\n' "$(wc -l < "$WORK/runtime-packages.list" | tr -d ' ')"
	printf 'runtime_kmods=%s\n' "$(tr '\n' ',' < "$WORK/runtime-kmods.list" | sed 's/,$//')"
	printf 'runtime_kmod_count=%s\n' "$(wc -l < "$WORK/runtime-kmods.list" | tr -d ' ')"
	printf 'selected_packages=%s\n' "$(tr '\n' ',' < "$WORK/selected-package-symbols.list" | sed 's/,$//')"
	printf 'selected_package_count=%s\n' "$(wc -l < "$WORK/selected-package-symbols.list" | tr -d ' ')"
	printf 'core_compile_deps=%s\n' "$(tr '\n' ',' < "$CORE_DEPS" | sed 's/,$//')"
	printf 'luci_compile_deps=%s\n' "$(tr '\n' ',' < "$LUCI_DEPS" | sed 's/,$//')"
	printf 'built_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUTPUT_DIR/BUILD-INFO"

(cd "$OUTPUT_DIR" && sha256sum -- *.ipk > SHA256SUMS)
for ipk in "$OUTPUT_DIR"/*.ipk; do
	sha256sum "$ipk" | awk '{print $1}' > "$ipk.sha256"
done

set -- "$OUTPUT_DIR"/*.ipk
[ "$#" -eq 2 ] || die 'final artifact uniqueness check failed'
[ -s "$OUTPUT_DIR/SHA256SUMS" ] || die 'SHA256SUMS was not generated'
[ -s "$OUTPUT_DIR/$CORE_NAME.sha256" ] && [ -s "$OUTPUT_DIR/$LUCI_NAME.sha256" ] \
	|| die 'per-package SHA-256 sidecars were not generated'

info "IPK artifacts are ready in $OUTPUT_DIR"
CONTAINER_SCRIPT

# Capture the identity actually used by the immutable image reference and
# refuse to produce artifacts unless both values are observable.
RUN_IMAGE_ID=$(docker inspect --format '{{.Image}}' "$RUN_NAME" 2>/dev/null || printf '%s' '')
RUN_REPO_DIGEST=$(docker image inspect --format '{{index .RepoDigests 0}}' "$DOCKER_IMAGE" 2>/dev/null || printf '%s' '')
[ -n "$RUN_IMAGE_ID" ] || die 'docker did not expose the runtime image ID'
[ -n "$RUN_REPO_DIGEST" ] || die 'docker did not expose the runtime image RepoDigest'
case "$RUN_REPO_DIGEST" in
	*"$DOCKER_IMAGE_DIGEST") ;;
	*) die "runtime image RepoDigest does not match pinned digest: $RUN_REPO_DIGEST" ;;
esac

docker cp "$RUN_NAME:/work/output/." "$STAGE_DIR/"

for artifact in "$STAGE_DIR"/*; do
	[ -e "$artifact" ] || [ -L "$artifact" ] || die "builder returned no staged artifacts"
	[ ! -L "$artifact" ] || die "builder returned a symlinked artifact: $artifact"
	[ -f "$artifact" ] || die "builder returned a non-file artifact: $artifact"
done
for forbidden in "$STAGE_DIR"/ax9000-fan-control-*.apk "$STAGE_DIR"/luci-app-ax9000-fan-*.apk; do
	[ -e "$forbidden" ] || [ -L "$forbidden" ] || continue
	die "builder returned a forbidden APK artifact: $forbidden"
done

awk -v image_id="$RUN_IMAGE_ID" -v repo_digest="$RUN_REPO_DIGEST" '
	BEGIN { image_done = 0; digest_done = 0 }
	/^docker_image_id=/ { print "docker_image_id=" image_id; image_done = 1; next }
	/^docker_image_repo_digest=/ { print "docker_image_repo_digest=" repo_digest; digest_done = 1; next }
	{ print }
	END {
		if (!image_done) print "docker_image_id=" image_id
		if (!digest_done) print "docker_image_repo_digest=" repo_digest
	}
' "$STAGE_DIR/BUILD-INFO" > "$STAGE_DIR/BUILD-INFO.tmp"
mv "$STAGE_DIR/BUILD-INFO.tmp" "$STAGE_DIR/BUILD-INFO"

set -- "$STAGE_DIR"/*.ipk
[ "$#" -eq 2 ] || die "builder returned an unexpected number of IPKs"
[ -f "$STAGE_DIR/SHA256SUMS" ] || die "builder did not return SHA256SUMS"
[ -f "$STAGE_DIR/BUILD-INFO" ] || die "builder did not return BUILD-INFO"
[ -f "$STAGE_DIR/BUILD-DEPENDENCIES" ] || die "builder did not return BUILD-DEPENDENCIES"
grep -F -x 'generated-by=ax9000-fan-build-packages-in-docker' "$STAGE_DIR/BUILD-INFO" >/dev/null 2>&1 \
	|| die "builder returned an unrecognised BUILD-INFO"
grep -F -x "docker_image_digest=$DOCKER_IMAGE_DIGEST" "$STAGE_DIR/BUILD-INFO" >/dev/null 2>&1 \
	|| die 'BUILD-INFO does not record the pinned Docker image digest'
grep -F -x "docker_image_repo_digest=$RUN_REPO_DIGEST" "$STAGE_DIR/BUILD-INFO" >/dev/null 2>&1 \
	|| die 'BUILD-INFO does not record the observed Docker image RepoDigest'
grep -E -x 'docker_image_id=sha256:[0-9a-f]{64}' "$STAGE_DIR/BUILD-INFO" >/dev/null 2>&1 \
	|| die 'BUILD-INFO does not record the runtime Docker image ID'
if command -v sha256sum >/dev/null 2>&1; then
	BUILD_DEPENDENCIES_SHA=$(sha256sum "$STAGE_DIR/BUILD-DEPENDENCIES" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
	BUILD_DEPENDENCIES_SHA=$(shasum -a 256 "$STAGE_DIR/BUILD-DEPENDENCIES" | awk '{print $1}')
else
	die "sha256sum or shasum is required on the host"
fi
grep -F -x "build_dependencies_sha256=$BUILD_DEPENDENCIES_SHA" "$STAGE_DIR/BUILD-INFO" >/dev/null 2>&1 \
	|| die 'BUILD-INFO build dependency manifest hash mismatch'

if command -v sha256sum >/dev/null 2>&1; then
	(cd "$STAGE_DIR" && sha256sum -c SHA256SUMS)
elif command -v shasum >/dev/null 2>&1; then
	(cd "$STAGE_DIR" && shasum -a 256 -c SHA256SUMS)
else
	die "sha256sum or shasum is required on the host"
fi

for ipk in "$STAGE_DIR"/*.ipk; do
	[ -s "$ipk" ] || die "empty IPK: $ipk"
	[ -s "$ipk.sha256" ] || die "missing sidecar: $ipk.sha256"
done

# Build the replacement set in a temporary directory inside dist, validate it,
# then replace only this builder's regular files. Unrelated files are preserved.
DIST_TMP=$(mktemp -d "$DIST_DIR/.ax9000-fan-dist.XXXXXX")
for artifact in "$STAGE_DIR"/*; do
	cp -p "$artifact" "$DIST_TMP/"
done
for artifact in "$DIST_TMP"/*; do
	[ ! -L "$artifact" ] || die "staged dist artifact is a symlink: $artifact"
	[ -f "$artifact" ] || die "staged dist artifact is not a file: $artifact"
done
if command -v sha256sum >/dev/null 2>&1; then
	(cd "$DIST_TMP" && sha256sum -c SHA256SUMS)
elif command -v shasum >/dev/null 2>&1; then
	(cd "$DIST_TMP" && shasum -a 256 -c SHA256SUMS)
else
	die "sha256sum or shasum is required on the host"
fi

for old in \
	"$DIST_DIR/BUILD-INFO" "$DIST_DIR/BUILD-DEPENDENCIES" "$DIST_DIR/SHA256SUMS" \
	"$DIST_DIR"/ax9000-fan-control_*.ipk \
	"$DIST_DIR"/luci-app-ax9000-fan_*.ipk \
	"$DIST_DIR"/ax9000-fan-control_*.ipk.sha256 \
	"$DIST_DIR"/luci-app-ax9000-fan_*.ipk.sha256 \
	"$DIST_DIR"/ax9000-fan-control-*.apk \
	"$DIST_DIR"/luci-app-ax9000-fan-*.apk \
	"$DIST_DIR"/ax9000-fan-control-*.apk.sha256 \
	"$DIST_DIR"/luci-app-ax9000-fan-*.apk.sha256; do
	[ -e "$old" ] || [ -L "$old" ] || continue
	[ ! -L "$old" ] || die "refusing to replace symlinked dist artifact: $old"
	[ -f "$old" ] || die "dist artifact is not a regular file: $old"
	rm -f "$old"
done
for artifact in "$DIST_TMP"/*; do
	[ ! -L "$artifact" ] || die "refusing to move symlinked dist artifact: $artifact"
	mv "$artifact" "$DIST_DIR/"
done
rmdir "$DIST_TMP"
DIST_TMP=

set -- "$DIST_DIR"/*.ipk
[ "$#" -eq 2 ] || die "dist contains an unexpected number of IPKs after copy"
for artifact in "$DIST_DIR"/*.ipk; do
	[ ! -L "$artifact" ] || die "dist IPK is a symlink after replacement: $artifact"
	[ -f "$artifact" ] || die "dist IPK is not a regular file: $artifact"
done
for forbidden in "$DIST_DIR"/ax9000-fan-control-*.apk "$DIST_DIR"/luci-app-ax9000-fan-*.apk; do
	[ -e "$forbidden" ] || [ -L "$forbidden" ] || continue
	die "dist contains a forbidden APK artifact: $forbidden"
done
if command -v sha256sum >/dev/null 2>&1; then
	(cd "$DIST_DIR" && sha256sum -c SHA256SUMS)
elif command -v shasum >/dev/null 2>&1; then
	(cd "$DIST_DIR" && shasum -a 256 -c SHA256SUMS)
else
	die "sha256sum or shasum is required on the host"
fi

info "completed: $DIST_DIR"

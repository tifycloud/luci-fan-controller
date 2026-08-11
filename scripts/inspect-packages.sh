#!/bin/sh
# Inspect the two production IPK artifacts emitted by the OpenWrt builder.
#
# OpenWrt 25.12 can build APK packages too, but this project deliberately
# ships the legacy opkg/IPK format for the current router. An IPK is a
# gzip-compressed tar containing exactly debian-binary, control.tar.gz, and
# data.tar.gz. This checker intentionally does not use apk-tools.
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
PROJECT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
DIST=${1:-dist}
SOURCE_ROOT=${2:-$PROJECT_DIR}
[ -d "$DIST" ] || { printf '%s\n' "missing dist directory: $DIST" >&2; exit 1; }
[ ! -L "$DIST" ] || { printf '%s\n' "dist directory must not be a symlink: $DIST" >&2; exit 1; }
[ -d "$SOURCE_ROOT" ] || { printf '%s\n' "missing source package root: $SOURCE_ROOT" >&2; exit 1; }
[ ! -L "$SOURCE_ROOT" ] || { printf '%s\n' "source package root must not be a symlink: $SOURCE_ROOT" >&2; exit 1; }

die() {
  printf 'IPK inspection failed: %s\n' "$*" >&2
  exit 1
}

command -v tar >/dev/null 2>&1 || die 'tar is required'
command -v sort >/dev/null 2>&1 || die 'sort is required'
command -v awk >/dev/null 2>&1 || die 'awk is required'
command -v cmp >/dev/null 2>&1 || die 'cmp is required'
command -v find >/dev/null 2>&1 || die 'find is required'

TMP=${TMPDIR:-/tmp}/ax9000-fan-inspect.$$
(umask 077 && mkdir "$TMP") || die "cannot create temporary directory: $TMP"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

assert_regular() {
  path=$1
  label=$2
  [ -f "$path" ] || die "$label is missing or not a regular file: $path"
  [ ! -L "$path" ] || die "$label is a symlink: $path"
  [ -s "$path" ] || die "$label is empty: $path"
}

# There must be exactly the two packages this project owns. In particular,
# stale APKs or a third-party IPK in dist must not be silently ignored.
set -- "$DIST"/*.ipk
[ "$#" -eq 2 ] || die "expected exactly two IPK files in $DIST"
for file in "$@"; do
  assert_regular "$file" 'IPK'
done
set -- "$DIST"/*.apk
for file in "$@"; do
  [ -e "$file" ] || [ -L "$file" ] || continue
  die "APK artifacts are not accepted; remove $file"
done
set -- "$DIST"/ax9000-fan-control_*.ipk
[ "$#" -eq 1 ] || die 'expected exactly one ax9000-fan-control IPK'
CORE=$1
set -- "$DIST"/luci-app-ax9000-fan_*.ipk
[ "$#" -eq 1 ] || die 'expected exactly one luci-app-ax9000-fan IPK'
LUCI=$1

case "$(basename "$CORE")" in
  ax9000-fan-control_1.0.0-r4_all.ipk) ;;
  *) die "unexpected core IPK filename: $(basename "$CORE")" ;;
esac
case "$(basename "$LUCI")" in
  luci-app-ax9000-fan_1.0.0-r1_all.ipk) ;;
  *) die "unexpected LuCI IPK filename: $(basename "$LUCI")" ;;
esac

# Require the provenance marker so an old APK-oriented dist directory cannot
# pass merely because it happens to contain two IPKs.
assert_regular "$DIST/BUILD-INFO" 'BUILD-INFO'
grep -F -x 'package_format=ipk' "$DIST/BUILD-INFO" >/dev/null 2>&1 \
  || die 'BUILD-INFO does not attest package_format=ipk'

assert_sha256_file() {
  file=$1
  label=$2
  assert_regular "$file" "$label"
  awk 'NR == 1 && length($0) == 64 && $0 !~ /[^0-9a-f]/ { ok = 1 }
    END { exit !(NR == 1 && ok) }' "$file" \
    || die "$label is not exactly one lowercase SHA-256 digest: $file"
}

sha256_file() {
  file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{ print $1 }'
  else
    die 'sha256sum or shasum is required'
  fi
}

# A post-build validation staging may carry a source manifest. When present,
# require BUILD-INFO to bind it to the exact bytes that were compared above;
# the ordinary builder output remains valid when no manifest is supplied.
if [ -e "$DIST/SOURCE-MANIFEST" ] || [ -L "$DIST/SOURCE-MANIFEST" ]; then
  assert_regular "$DIST/SOURCE-MANIFEST" 'SOURCE-MANIFEST'
  SOURCE_MANIFEST_SHA=$(sha256_file "$DIST/SOURCE-MANIFEST")
  grep -F -x "source_manifest_sha256=$SOURCE_MANIFEST_SHA" "$DIST/BUILD-INFO" >/dev/null 2>&1 \
    || die 'BUILD-INFO source_manifest_sha256 does not match SOURCE-MANIFEST'
fi

# SHA256SUMS must enumerate exactly the two IPKs, and each sidecar must agree
# with its corresponding package. Names are checked independently so a valid
# digest cannot be redirected to an unexpected file.
assert_regular "$DIST/SHA256SUMS" 'SHA256SUMS'
CORE_NAME=$(basename "$CORE")
LUCI_NAME=$(basename "$LUCI")
awk -v core="$CORE_NAME" -v luci="$LUCI_NAME" '
  NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ || ($2 != core && $2 != luci) { bad = 1 }
  $2 == core { core_count++ }
  $2 == luci { luci_count++ }
  END { exit !(NR == 2 && !bad && core_count == 1 && luci_count == 1) }
' "$DIST/SHA256SUMS" || die 'SHA256SUMS must contain exactly one line for each IPK'
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$DIST" && sha256sum -c SHA256SUMS) || die 'SHA256SUMS verification failed'
elif command -v shasum >/dev/null 2>&1; then
  (cd "$DIST" && shasum -a 256 -c SHA256SUMS) || die 'SHA256SUMS verification failed'
else
  die 'sha256sum or shasum is required'
fi
for package_file in "$CORE" "$LUCI"; do
  sidecar=$package_file.sha256
  assert_sha256_file "$sidecar" 'IPK SHA-256 sidecar'
  [ "$(cat "$sidecar")" = "$(sha256_file "$package_file")" ] \
    || die "SHA-256 sidecar mismatch: $package_file"
done

assert_safe_listing() {
  listing=$1
  awk '
    $0 ~ /^\// || $0 ~ /(^|\/)\.\.($|\/)/ || $0 ~ /[[:space:]]+$/ { bad = 1 }
    END { exit bad }
  ' "$listing" || die "archive contains an unsafe path: $listing"
  # Duplicate members make extraction order-dependent and are not emitted by
  # the official ipkg-build flow.
  if sort "$listing" | uniq -d | grep . >/dev/null 2>&1; then
    die "archive contains duplicate members: $listing"
  fi
}

assert_exact_members() {
  listing=$1
  shift
  expected=$TMP/expected.$$
  sorted=$TMP/sorted.$$
  for member in "$@"; do
    printf '%s\n' "$member"
  done | LC_ALL=C sort > "$expected"
  LC_ALL=C sort "$listing" > "$sorted"
  cmp -s "$expected" "$sorted" || die "archive members are not exact: $listing"
}

assert_plain_members() {
  inner_archive=$1
  tar -tvzf "$inner_archive" | awk '
    substr($0, 1, 1) != "d" && substr($0, 1, 1) != "-" { bad = 1 }
    END { exit bad }
  ' || die "archive contains a symlink or special member: $inner_archive"
}

file_mode() {
  path=$1
  if stat -c '%a' "$path" >/dev/null 2>&1; then
    stat -c '%a' "$path"
  elif stat -f '%Lp' "$path" >/dev/null 2>&1; then
    stat -f '%Lp' "$path"
  else
    die 'stat with a portable mode formatter is required'
  fi
}

assert_mode() {
  path=$1
  expected=$2
  label=$3
  assert_regular "$path" "$label"
  actual=$(file_mode "$path")
  [ "$actual" = "$expected" ] || die "$label has mode $actual, expected $expected: $path"
}

control_field() {
  control=$1
  field=$2
  awk -v wanted="$field" '
    index($0, wanted ":") == 1 {
      count++
      value = substr($0, length(wanted) + 2)
      sub(/^[[:space:]]*/, "", value)
    }
    END {
      if (count != 1) exit 2
      print value
    }
  ' "$control" || die "control metadata must contain exactly one $field field: $control"
}

assert_unique_control_fields() {
  control=$1
  awk '
    /^[[:alnum:]][[:alnum:]-]*:[[:space:]]*/ {
      field = $0
      sub(/:.*/, "", field)
      if (++seen[field] != 1) { bad = 1 }
      continuation = 1
      next
    }
    /^[[:space:]]/ {
      if (!continuation) { bad = 1 }
      next
    }
    { bad = 1 }
    END { exit bad }
  ' "$control" || die "control metadata has duplicate or malformed fields: $control"
}

assert_dependency() {
  depends=$1
  dependency=$2
  printf '%s\n' "$depends" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | awk -v expected="$dependency" '$1 == expected { found = 1 } END { exit !found }' \
    || die "control metadata is missing dependency $dependency"
}

assert_contents() {
  expected=$1
  actual=$2
  label=$3
  cmp -s "$expected" "$actual" || die "$label content does not match the canonical source: $actual"
}

write_generic_postinst() {
  output=$1
  cat > "$output" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
EOF
}

write_generic_prerm() {
  output=$1
  cat > "$output" <<'EOF'
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
EOF
}

extract_lifecycle_source() {
  source_makefile=$1
  source_package_name=$2
  source_hook_name=$3
  source_output=$4
  awk -v wanted="define Package/$source_package_name/$source_hook_name" '
    $0 == wanted { found = 1; next }
    found && $0 == "endef" { exit }
    found {
      gsub(/\$\$/, "$")
      print
    }
    END { if (!found) exit 2 }
  ' "$source_makefile" > "$source_output" || die "missing lifecycle definition $source_hook_name in $source_makefile"
}

assert_lifecycle_scripts() {
  control_dir=$1
  script_label=$2
  expected_name=$3
  case "$expected_name" in
    ax9000-fan-control) source_package=$SOURCE_ROOT/controller ;;
    luci-app-ax9000-fan) source_package=$SOURCE_ROOT/luci ;;
    *) die "unknown source package: $expected_name" ;;
  esac
  makefile=$source_package/Makefile
  [ -f "$makefile" ] || die "source package Makefile is missing: $makefile"
  case "$expected_name" in
    ax9000-fan-control)
      lifecycle_list='preinst postinst prerm postinst-pkg prerm-pkg'
      ;;
    luci-app-ax9000-fan)
      lifecycle_list='postinst prerm'
      ;;
    *) die "unexpected package name for lifecycle checks: $expected_name" ;;
  esac
  for lifecycle in $lifecycle_list; do
    lifecycle_expected=$TMP/$script_label.lifecycle.$lifecycle.expected
    case "$lifecycle" in
      postinst)
        write_generic_postinst "$lifecycle_expected"
        ;;
      prerm)
        write_generic_prerm "$lifecycle_expected"
        ;;
      preinst|postinst-pkg|prerm-pkg)
        source_hook=$lifecycle
        case "$lifecycle" in
          postinst-pkg) source_hook=postinst ;;
          prerm-pkg) source_hook=prerm ;;
        esac
        extract_lifecycle_source "$makefile" "$expected_name" "$source_hook" "$lifecycle_expected"
        ;;
      *) die "unexpected lifecycle script: $lifecycle" ;;
    esac
    assert_mode "$control_dir/$lifecycle" 755 "control lifecycle script $lifecycle"
    assert_contents "$lifecycle_expected" "$control_dir/$lifecycle" "control lifecycle script $lifecycle"
    case "$lifecycle" in
      postinst)
        grep -F 'IPKG_INSTROOT' "$control_dir/$lifecycle" >/dev/null 2>&1 \
          || die 'generic postinst lacks IPKG_INSTROOT guard'
        grep -F 'default_postinst' "$control_dir/$lifecycle" >/dev/null 2>&1 \
          || die 'generic postinst lacks default_postinst wrapper'
        ;;
      prerm)
        grep -F 'IPKG_INSTROOT' "$control_dir/$lifecycle" >/dev/null 2>&1 \
          || die 'generic prerm lacks IPKG_INSTROOT guard'
        grep -F 'default_prerm' "$control_dir/$lifecycle" >/dev/null 2>&1 \
          || die 'generic prerm lacks default_prerm wrapper'
        ;;
    esac
  done
  if [ "$expected_name" = ax9000-fan-control ]; then
    conffiles_expected=$TMP/$script_label.conffiles.expected
    printf '%s\n' '/etc/config/ax9000-fan' > "$conffiles_expected"
    assert_mode "$control_dir/conffiles" 644 'control conffiles'
    assert_contents "$conffiles_expected" "$control_dir/conffiles" 'control conffiles'
  fi
}

assert_data_matches_source() {
  data_dir=$1
  label=$2
  expected_name=$3
  case "$expected_name" in
    ax9000-fan-control)
      source_base=$SOURCE_ROOT/controller/files
      expected_files='etc/config/ax9000-fan
etc/init.d/ax9000-fan-control
usr/sbin/ax9000-fan-control
usr/libexec/ax9000-fan-common
usr/libexec/ax9000-fan-force-fullspeed
usr/libexec/ax9000-fan-status
usr/libexec/ax9000-fan-validate'
      ;;
    luci-app-ax9000-fan)
      source_base=$SOURCE_ROOT/luci/root
      expected_files='usr/share/ax9000-fan/README
usr/share/luci/menu.d/luci-app-ax9000-fan.json
usr/share/rpcd/acl.d/luci-app-ax9000-fan.json
www/luci-static/resources/view/ax9000-fan/overview.css
www/luci-static/resources/view/ax9000-fan/overview.js'
      ;;
    *) die "unexpected package name for source comparison: $expected_name" ;;
  esac
  [ -d "$source_base" ] || die "source payload root is missing: $source_base"
  [ ! -L "$source_base" ] || die "source payload root is a symlink: $source_base"
  source_special=$TMP/$label.source.special
  find "$source_base" \( -type l -o -type b -o -type c -o -type p -o -type s \) -print > "$source_special"
  if [ -s "$source_special" ]; then
    die "source payload contains a symlink or special file: $source_base"
  fi
  source_list=$TMP/$label.source.files
  data_list=$TMP/$label.data.files
  expected_list=$TMP/$label.expected.files
  (cd "$source_base" && find . -type f -print | sed 's#^\./##') | LC_ALL=C sort > "$source_list"
  (cd "$data_dir" && find . -type f -print | sed 's#^\./##') | LC_ALL=C sort > "$data_list"
  printf '%s\n' "$expected_files" | LC_ALL=C sort > "$expected_list"
  cmp -s "$source_list" "$expected_list" || die "source payload file set is not canonical: $source_base"
  cmp -s "$data_list" "$expected_list" || die "packaged data file set is not canonical: $data_dir"
  source_count=$(wc -l < "$source_list" | tr -d '[:space:]')
  data_count=$(wc -l < "$data_list" | tr -d '[:space:]')
  [ "$source_count" = "$data_count" ] || die "source/data file cardinality differs for $expected_name"
  while IFS= read -r data_path; do
    assert_regular "$source_base/$data_path" "source data file $data_path"
    assert_regular "$data_dir/$data_path" "packaged data file $data_path"
    cmp -s "$source_base/$data_path" "$data_dir/$data_path" \
      || die "packaged data differs from current source: $data_path"
  done < "$data_list"
}

assert_ipk() {
  package=$1
  package_label=$2
  expected_name=$3
  expected_version=$4
  outer=$TMP/$package_label.outer.list
  archive=$TMP/$package_label.archive
  control_dir=$TMP/$package_label.control
  data_dir=$TMP/$package_label.data
  mkdir -p "$archive" "$control_dir" "$data_dir"
  tar -tzf "$package" > "$outer" || die "cannot read IPK gzip-tar: $package"
  assert_safe_listing "$outer"
  assert_exact_members "$outer" './control.tar.gz' './data.tar.gz' './debian-binary'
  assert_plain_members "$package"
  tar -xzf "$package" -C "$archive" || die "cannot extract IPK outer archive: $package"
  assert_mode "$archive/debian-binary" 644 'debian-binary'
  assert_mode "$archive/control.tar.gz" 644 'control.tar.gz'
  assert_mode "$archive/data.tar.gz" 644 'data.tar.gz'
  [ "$(wc -c < "$archive/debian-binary" | tr -d ' ')" = 4 ] \
    || die "debian-binary has trailing data: $package"
  [ "$(cat "$archive/debian-binary")" = '2.0' ] \
    || die "debian-binary is not version 2.0: $package"

  control_listing=$TMP/$package_label.control.list
  data_listing=$TMP/$package_label.data.list
  tar -tzf "$archive/control.tar.gz" > "$control_listing" \
    || die "cannot read control.tar.gz: $package"
  tar -tzf "$archive/data.tar.gz" > "$data_listing" \
    || die "cannot read data.tar.gz: $package"
  assert_safe_listing "$control_listing"
  assert_safe_listing "$data_listing"
  assert_plain_members "$archive/control.tar.gz"
  assert_plain_members "$archive/data.tar.gz"
  case "$expected_name" in
    ax9000-fan-control)
      assert_exact_members "$control_listing" './' './conffiles' './control' './postinst' \
        './postinst-pkg' './preinst' './prerm' './prerm-pkg'
      assert_exact_members "$data_listing" './' './etc/' './etc/config/' \
        './etc/config/ax9000-fan' './etc/init.d/' './etc/init.d/ax9000-fan-control' \
        './usr/' './usr/libexec/' './usr/libexec/ax9000-fan-common' \
        './usr/libexec/ax9000-fan-force-fullspeed' './usr/libexec/ax9000-fan-status' \
        './usr/libexec/ax9000-fan-validate' './usr/sbin/' './usr/sbin/ax9000-fan-control'
      ;;
    luci-app-ax9000-fan)
      assert_exact_members "$control_listing" './' './control' './postinst' './prerm'
      assert_exact_members "$data_listing" './' './usr/' './usr/share/' \
        './usr/share/ax9000-fan/' './usr/share/ax9000-fan/README' \
        './usr/share/luci/' './usr/share/luci/menu.d/' \
        './usr/share/luci/menu.d/luci-app-ax9000-fan.json' './usr/share/rpcd/' \
        './usr/share/rpcd/acl.d/' './usr/share/rpcd/acl.d/luci-app-ax9000-fan.json' \
        './www/' './www/luci-static/' './www/luci-static/resources/' \
        './www/luci-static/resources/view/' './www/luci-static/resources/view/ax9000-fan/' \
        './www/luci-static/resources/view/ax9000-fan/overview.css' \
        './www/luci-static/resources/view/ax9000-fan/overview.js'
      ;;
    *) die "unexpected package name: $expected_name" ;
  esac
  tar -xzf "$archive/control.tar.gz" -C "$control_dir" \
    || die "cannot extract control.tar.gz: $package"
  tar -xzf "$archive/data.tar.gz" -C "$data_dir" \
    || die "cannot extract data.tar.gz: $package"

  control=$control_dir/control
  assert_mode "$control" 644 'control metadata'
  if grep "$(printf '\r')" "$control" >/dev/null 2>&1; then
    die 'control metadata contains CR characters'
  fi
  assert_unique_control_fields "$control"
  [ "$(control_field "$control" Package)" = "$expected_name" ] \
    || die "control Package does not match expected name: $package"
  [ "$(control_field "$control" Version)" = "$expected_version" ] \
    || die "control Version does not match expected version: $package"
  [ "$(control_field "$control" Architecture)" = all ] \
    || die "control Architecture must be all: $package"
  depends=$(control_field "$control" Depends)
  [ -n "$depends" ] || die "control Depends is empty: $package"
  case "$expected_name" in
    ax9000-fan-control)
      for dependency in libc i2c-tools kmod-hwmon-emc2305 kmod-hwmon-core kmod-thermal \
        kmod-i2c-core kmod-regmap-i2c; do
        assert_dependency "$depends" "$dependency"
      done
      ;;
    luci-app-ax9000-fan)
      for dependency in ax9000-fan-control luci-base luci-mod-admin-full rpcd; do
        assert_dependency "$depends" "$dependency"
      done
      ;;
    *) die "unexpected package name: $expected_name" ;;
  esac

  case "$expected_name" in
    ax9000-fan-control)
      for path in \
        etc/init.d/ax9000-fan-control \
        usr/sbin/ax9000-fan-control \
        usr/libexec/ax9000-fan-common \
        usr/libexec/ax9000-fan-force-fullspeed \
        usr/libexec/ax9000-fan-status \
        usr/libexec/ax9000-fan-validate; do
        assert_mode "$data_dir/$path" 755 "core data file $path"
      done
      assert_mode "$data_dir/etc/config/ax9000-fan" 600 'core UCI config'
      grep -F 'procd_open_instance fan_control' "$data_dir/etc/init.d/ax9000-fan-control" \
        >/dev/null 2>&1 || die 'core init script lacks the named fan_control procd instance'
      ;;
    luci-app-ax9000-fan)
      for path in \
        www/luci-static/resources/view/ax9000-fan/overview.js \
        www/luci-static/resources/view/ax9000-fan/overview.css \
        usr/share/luci/menu.d/luci-app-ax9000-fan.json \
        usr/share/rpcd/acl.d/luci-app-ax9000-fan.json \
        usr/share/ax9000-fan/README; do
        assert_mode "$data_dir/$path" 644 "LuCI data file $path"
      done
      grep -F 'mC < -20000 || mC > 200000' \
        "$data_dir/www/luci-static/resources/view/ax9000-fan/overview.js" >/dev/null \
        || die 'LuCI overview.js lacks the signed mC range guard'
      ;;
  esac
  assert_lifecycle_scripts "$control_dir" "$package_label" "$expected_name"
  assert_data_matches_source "$data_dir" "$package_label" "$expected_name"
}

assert_ipk "$CORE" core ax9000-fan-control 1.0.0-r4
assert_ipk "$LUCI" luci luci-app-ax9000-fan 1.0.0-r1

printf '%s\n' 'IPK structure, control/data contents, checksums, and artifact cardinality passed.'

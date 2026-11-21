#!/bin/sh
# Sanity-check one built uptime-kuma ipk: structure, control fields, payload,
# sqlite3 addon identity, trim state and unpacked size.
#
# Usage: ./verify.sh <path-to.ipk>
set -eu

ipk=${1:?usage: verify.sh <path-to.ipk>}
[ -f "$ipk" ] || { echo "no such file: $ipk" >&2; exit 1; }

abs_ipk=$(cd "$(dirname "$ipk")" && pwd)/$(basename "$ipk")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

fail() { echo "FAIL: $*" >&2; exit 1; }

# The device opkg (1bf042dd, 2021-06-13) only reads gzip-tar ipks: an `ar`
# outer container is rejected as "Malformed" (small packages) or crashes it
# with SIGSEGV (large ones). Fail here rather than on the device.
[ "$(head -c 7 "$abs_ipk")" != '!<arch>' ] || fail 'ar outer container: rebuild with opkg-build -c'
tar xzf "$abs_ipk"
[ -f debian-binary ] || fail 'debian-binary missing'
[ -f control.tar.gz ] || fail 'control.tar.gz missing'
[ -f data.tar.gz ] || fail 'data.tar.gz missing'

mkdir ctl
tar xzf control.tar.gz -C ctl
grep -qx 'Package: uptime-kuma' ctl/control || fail 'Package field wrong'
grep -qx 'Version: 2.5.12' ctl/control || fail 'Version field wrong'
grep -qx 'Architecture: aarch64_cortex-a53' ctl/control || fail 'Architecture field wrong'
grep -qx 'Depends: node20, libgcc1' ctl/control || fail 'Depends field wrong'
grep -qx '/etc/config/uptime-kuma' ctl/conffiles || fail 'CONTROL/conffiles entry missing'
if grep -q '^Conffiles:' ctl/control; then fail 'Conffiles must not live in control (opkg 0.4 rejects it)'; fi

tar tzf data.tar.gz > filelist.txt
need() { grep -qx "./$1" filelist.txt || fail "$1 missing"; }
need opt/uptime-kuma/server/server.js
need opt/uptime-kuma/package.json
need opt/uptime-kuma/dist/index.html
need opt/uptime-kuma/src/util.js
need opt/uptime-kuma/extra/rdap-dns.json
need opt/uptime-kuma/db/knex_init_db.js
# The first-run SQLite template: server/database.js copies it into DATA_DIR.
need opt/uptime-kuma/db/kuma.db
need opt/uptime-kuma/lib/libstdc++.so.6
need opt/uptime-kuma/node_modules/express/package.json
need opt/uptime-kuma/node_modules/@louislam/sqlite3/lib/binding/napi-v6-linux-arm64/node_sqlite3.node
need etc/init.d/uptime-kuma
need etc/config/uptime-kuma

if grep -q '^\./opt/uptime-kuma/server/test/' filelist.txt; then
	fail 'server test data still shipped'
fi
if grep -q '^\./opt/uptime-kuma/node_modules/@louislam/sqlite3/build-tmp' filelist.txt; then
	fail 'sqlite3 source-build residue still shipped'
fi
if grep -q '^\./opt/uptime-kuma/.*\.md$' filelist.txt; then
	fail '*.md trim round 1 not applied'
fi
if grep -q '^\./opt/uptime-kuma/.*\.map$' filelist.txt; then
	fail '*.map trim round 2 not applied'
fi

mkdir root
tar xzf data.tar.gz -C root

[ "$(head -c 15 root/opt/uptime-kuma/db/kuma.db)" = 'SQLite format 3' ] \
	|| fail 'db/kuma.db is not a SQLite template'

[ "$(stat -c %a root/etc/init.d/uptime-kuma)" = 755 ] || fail 'init script mode is not 0755'
[ "$(stat -c %a root/etc/config/uptime-kuma)" = 644 ] || fail 'uci config mode is not 0644'
sh -n root/etc/init.d/uptime-kuma || fail 'init script fails sh -n'
grep -q 'cd $APP_DIR && exec $PROG server/server.js' root/etc/init.d/uptime-kuma \
	|| fail 'init does not cd into APP_DIR before exec'
if grep -q 'procd_set_param cwd' root/etc/init.d/uptime-kuma; then
	fail 'procd 21.02 has no cwd parameter'
fi

grep -q '^	option enabled' root/etc/config/uptime-kuma || fail 'uci enabled option missing'
grep -q "option listen '0.0.0.0'" root/etc/config/uptime-kuma || fail 'uci listen default wrong'
grep -q "option port '3001'" root/etc/config/uptime-kuma || fail 'uci port default wrong'
grep -q "option data_dir '/opt/uptime-kuma/data'" root/etc/config/uptime-kuma || fail 'uci data_dir default wrong'
grep -q "option tz 'UTC'" root/etc/config/uptime-kuma || fail 'uci tz default wrong'

grep -q 'checkUpdate disabled: non-git install' \
	root/opt/uptime-kuma/server/check-version.js || fail 'update checker not disabled'
grep -q 'data.checkUpdate = false; // OpenWrt: non-git install' \
	root/opt/uptime-kuma/server/server.js || fail 'update controls not disabled'

binding=root/opt/uptime-kuma/node_modules/@louislam/sqlite3/lib/binding/napi-v6-linux-arm64/node_sqlite3.node
echo "d14ab9d2a8611fc086c2c14ad9704592db499cab84b1dddb31df89240f6f493c  $binding" \
	| sha256sum -c - >/dev/null || fail 'sqlite3 addon is not the pinned musl prebuild'
echo "fd9f4683f979345e58253b3d21e82c1f9af27996269c07404ed74fa2b0566d06  root/opt/uptime-kuma/lib/libstdc++.so.6" \
	| sha256sum -c - >/dev/null || fail 'bundled libstdc++.so.6 is not the pinned Alpine 3.12 build'

# The binding directory name has no "-musl"; decide by the ELF itself.
needed=$(readelf -d "$binding" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
echo "$needed" | grep -qx 'libc.musl-aarch64.so.1' || fail 'sqlite3 addon is not linked against musl'
echo "$needed" | grep -qx 'libgcc_s.so.1' || fail 'sqlite3 addon does not need libgcc_s.so.1'
echo "$needed" | grep -qx 'libstdc++.so.6' || fail 'sqlite3 addon does not need libstdc++.so.6'
if echo "$needed" | grep -qx 'libc.so.6'; then
	fail 'sqlite3 addon links glibc (libc.so.6)'
fi
needed_libstdcxx=$(readelf -d root/opt/uptime-kuma/lib/libstdc++.so.6 | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
echo "$needed_libstdcxx" | grep -qx 'libc.musl-aarch64.so.1' || fail 'bundled libstdc++ is not a musl build'
echo "$needed_libstdcxx" | grep -qx 'libgcc_s.so.1' || fail 'bundled libstdc++ does not need libgcc_s.so.1'

kb=$(du -sk root | cut -f1)
bytes=$(du -sb root | cut -f1)
case "$kb" in
	''|*[!0-9]*) fail 'could not measure unpacked size' ;;
esac
if [ "$kb" -lt 184320 ] || [ "$kb" -gt 225280 ]; then
	fail "unpacked size outside 180-220 MiB window: $kb KiB"
fi
printf 'unpacked: %s KiB (du -sk), %s bytes (du -sb)\n' "$kb" "$bytes"

echo "ipk:      $abs_ipk"
echo "ipk size: $(wc -c < "$abs_ipk") bytes"
echo "sha256:   $(sha256sum "$abs_ipk" | cut -d' ' -f1)"
echo "control:"
sed 's/^/  /' ctl/control
echo "OK"

#!/bin/sh
# Structural checks for luci-app-uptime-kuma.
#
#   ./verify.sh <path-to.ipk>
#
# Everything here is offline and needs no device: the package is plain text,
# so the acceptance criteria from the issue are all static. Rendering, procd
# and the firewall rule are Stage 3 concerns and are deliberately not faked.
set -eu

ipk=${1:?usage: verify.sh <path-to.ipk>}
[ -f "$ipk" ] || { echo "no such file: $ipk" >&2; exit 1; }

pkgdir=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { printf '  ok  %s\n' "$*"; }

VIEW=$pkgdir/htdocs/luci-static/resources/view/uptime-kuma/overview.js
MENU=$pkgdir/root/usr/share/luci/menu.d/luci-app-uptime-kuma.json
ACL=$pkgdir/root/usr/share/rpcd/acl.d/luci-app-uptime-kuma.json
DEFAULTS=$pkgdir/root/etc/uci-defaults/90_luci-app-uptime-kuma
BACKUP=$pkgdir/root/usr/libexec/luci-app-uptime-kuma/backup
PO=$pkgdir/po/zh-cn/luci-app-uptime-kuma.zh-cn.po
LMO=$pkgdir/root/usr/lib/lua/luci/i18n/luci-app-uptime-kuma.zh-cn.lmo

echo "source checks"

# 1. menu.d and acl.d must be valid JSON. The shipped files are the ones
#    parsed here - no separate fixture that could drift.
for f in "$MENU" "$ACL"; do
	node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$f" \
		|| fail "invalid JSON: $f"
	ok "JSON parses: ${f#$pkgdir/}"
done

# 2. The view script must be syntactically valid. LuCI class files are plain
#    scripts whose body runs inside a wrapper function, so a top-level
#    `return view.extend(...)` is legal and `node --check` accepts it as is.
node --check "$VIEW" || fail "syntax error: $VIEW"
ok "node --check: overview.js"

# 3. Every `require`d module must exist in the 21.02 LuCI tree. `view`, `poll`
#    and `baseclass` are preloaded builtins (the classes table in luci.js);
#    the rest are class files under htdocs/luci-static/resources/.
for mod in $(grep -o "^'require [a-z.]*'" "$VIEW" | cut -d" " -f2 | tr -d "'"); do
	case "$mod" in
		view|poll|dom|request|session|baseclass|ui|uci|rpc|fs|form)
			ok "require $mod (21.02 builtin/class)"
			;;
		*)
			fail "unexpected require: $mod"
			;;
	esac
done

# 4. Shell payload must parse under the device's busybox ash.
for f in "$DEFAULTS" "$BACKUP" "$pkgdir/files/postinst" "$pkgdir/files/prerm"; do
	sh -n "$f" || fail "syntax error: $f"
	ok "sh -n: ${f#$pkgdir/}"
done

# 4b. UCI addressing. /etc/config/uptime-kuma has exactly one section:
#     `config uptime-kuma 'main'`. Any `@service[N]` reference reads empty and
#     silently falls back to the default, so the firewall port and the backup
#     directory would disagree with what the page shows.
if grep -n '@service\[' "$DEFAULTS" "$BACKUP" "$pkgdir/files/postinst" "$pkgdir/files/prerm"; then
	fail "scripts must address uptime-kuma.main.<option>, not @service[N]"
fi
ok "uci addressing: uptime-kuma.main"

# 5. No hardcoded Chinese outside po/: the view is English source, the
#    translation lives in the catalog. Catch CJK ranges (U+3000-9FFF,
#    U+FF00-FFEF) anywhere in the shipped text payload.
for f in "$VIEW" "$MENU" "$ACL" "$DEFAULTS" "$BACKUP"; do
	if python3 -c 'import sys; d=open(sys.argv[1],encoding="utf-8").read(); sys.exit(0 if any(0x3000<=ord(c)<=0x9fff or 0xff00<=ord(c)<=0xffef for c in d) else 1)' "$f"; then
		fail "hardcoded CJK text in ${f#$pkgdir/}"
	fi
done
ok "no hardcoded CJK in payload"

# 6. Every msgid used by the view must exist in the .po, and the compiled
#    .lmo must match the .po (catches a stale catalog).
python3 "$pkgdir/tools/po2lmo.py" --check "$PO" "$LMO" "$VIEW" \
	|| fail "translation catalog out of sync"

echo "ipk checks"

abs_ipk=$(cd "$(dirname "$ipk")" && pwd)/$(basename "$ipk")
cd "$tmp"

# Classic ipk files are ar archives, some newer tools emit a plain gzipped
# tar. Unpack either without requiring binutils: the checks below only need
# the two members, and `ar` is not part of the base system on every build
# host. (python3 is already a hard requirement for the i18n check above.)
python3 - "$abs_ipk" <<'EOF' || fail 'cannot unpack the ipk'
import sys, tarfile, gzip
path = sys.argv[1]
blob = open(path, 'rb').read()

# The device opkg (1bf042dd, 2021-06-13) only reads gzip-tar ipks: an `ar`
# outer container is rejected as "Malformed". Fail here rather than on the
# device.
if blob.startswith(b'!<arch>\n'):
    sys.exit('ar outer container: rebuild with opkg-build -c')
if blob[:2] != b'\x1f\x8b':
    sys.exit('not a gzip-tar ipk: %r' % blob[:7])
with tarfile.open(path, 'r:gz') as t:
    try:
        t.extractall('.', filter='data')
    except TypeError:  # python < 3.12
        t.extractall('.')
EOF

[ -f control.tar.gz ] || fail 'control.tar.gz missing'
[ -f data.tar.gz ] || fail 'data.tar.gz missing'

mkdir ctl root
tar xzf control.tar.gz -C ctl
tar xzf data.tar.gz -C root

grep -qx 'Package: luci-app-uptime-kuma' ctl/control || fail 'wrong Package field'
grep -qx 'Architecture: all' ctl/control || fail 'Architecture must be all'
grep -q '^Depends: .*luci-base' ctl/control || fail 'Depends must include luci-base'
# rpcd-mod-file is deliberately not a dependency: this vendor firmware ships no
# opkg feed and does not install it, so a package dependency would make the
# install impossible. The page needs the `file exec` ubus call at runtime; on a
# device where that is absent the official rpcd-mod-file ipk is installed
# alongside this one (see README, "rpcd-mod-file").
if grep -q '^Depends: .*rpcd-mod-file' ctl/control; then fail 'rpcd-mod-file must not be a hard dependency'; fi
ok 'control fields'

[ -x ctl/postinst ] || fail 'postinst is not executable'
[ -x ctl/prerm ] || fail 'prerm is not executable'
ok 'postinst/prerm present'

# The ACL must actually carry what the view does: service list + file exec on
# logread for reading, uci set/apply and exec on the init script and the
# backup helper for writing. A missing scope shows up as a silent 403 on the
# device, not as a load error, so it is asserted here.
node -e '
var acl = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))["luci-app-uptime-kuma"];
var fail = function(m) { console.error("FAIL: acl " + m); process.exit(1); };
if (!acl) fail("group missing");
if (acl.read.ubus.service.indexOf("list") < 0) fail("service list not granted");
if (acl.read.ubus.file.indexOf("exec") < 0) fail("file exec not granted for read");
if (acl.read.file["/sbin/logread"].indexOf("exec") < 0) fail("logread exec not granted");
if (acl.read.uci.indexOf("uptime-kuma") < 0) fail("uci read not granted");
if (acl.write.uci.indexOf("uptime-kuma") < 0) fail("uci write not granted");
if (acl.write.ubus.uci.indexOf("apply") < 0) fail("uci apply not granted");
if (acl.write.file["/etc/init.d/uptime-kuma"].indexOf("exec") < 0) fail("init script exec not granted");
if (acl.write.file["/usr/libexec/luci-app-uptime-kuma/backup"].indexOf("exec") < 0) fail("backup helper exec not granted");
' "$ACL" || fail 'ACL does not match the view'
ok 'ACL scopes'

# The firewall hook must stay LAN-only: an ACCEPT rule without a `src lan`
# restriction, or one that mentions wan, would expose the panel to the uplink.
for needle in "src='lan'" "proto='tcp'" "target='ACCEPT'"; do
	grep -q "$needle" "$DEFAULTS" || fail "uci-defaults lacks $needle"
done
if grep -q "src='wan'" "$DEFAULTS"; then
	fail "uci-defaults opens the WAN zone"
fi
ok 'uci-defaults is LAN-only'

# The backup helper must refuse /tmp and never take a path from the request.
grep -q '/tmp' "$BACKUP" || fail 'backup helper does not guard against /tmp'
grep -q 'uci -q get uptime-kuma' "$BACKUP" || fail 'backup helper does not read data_dir from uci'
ok 'backup helper guards'

for f in \
	./www/luci-static/resources/view/uptime-kuma/overview.js \
	./usr/share/luci/menu.d/luci-app-uptime-kuma.json \
	./usr/share/rpcd/acl.d/luci-app-uptime-kuma.json \
	./usr/lib/lua/luci/i18n/luci-app-uptime-kuma.zh-cn.lmo \
	./usr/libexec/luci-app-uptime-kuma/backup \
	./etc/uci-defaults/90_luci-app-uptime-kuma
do
	[ -f "root/${f#./}" ] || fail "payload missing $f"
done
ok 'payload complete'

[ -x root/usr/libexec/luci-app-uptime-kuma/backup ] || fail 'backup helper not executable'
[ -x root/etc/uci-defaults/90_luci-app-uptime-kuma ] || fail 'uci-defaults not executable'
[ ! -d root/htdocs ] || fail 'htdocs/ leaked into the package (must install as /www)'
ok 'payload modes and paths'

bytes=$(wc -c < "$abs_ipk")
files=$(tar tzf data.tar.gz | grep -c -v '/$')
printf 'ipk:      %s\n' "$abs_ipk"
printf 'ipk size: %s bytes\n' "$bytes"
printf 'files:    %s\n' "$files"
printf 'sha256:   %s\n' "$(sha256sum "$abs_ipk" | cut -d' ' -f1)"

[ "$bytes" -lt 1048576 ] || fail "package exceeds the 1 MB budget: $bytes bytes"
echo OK

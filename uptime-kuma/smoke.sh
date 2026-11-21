#!/bin/sh
# Boot the packaged app in Alpine 3.12 (musl 1.1.24, the device's libc) with
# the node20 package, then check:
#   - /api/entry-page returns {"type":"setup-database"}
#   - @louislam/sqlite3 dlopens and can create/read a table
#   - stable RSS
#
# Bind mounts are not usable in this runtime, so the trees are copied into the
# container with docker cp.  Everything happens inside a throwaway container.
#
# Usage: ./smoke.sh [path/to/uptime-kuma.ipk] [path/to/node20.ipk]
set -eu

here=$(cd "$(dirname "$0")" && pwd)
feed=$(cd "$here/.." && pwd)
kuma_ipk=${1:-$feed/dist/uptime-kuma_2.5.12_aarch64_cortex-a53.ipk}
node_ipk=${2:-$feed/dist/node20_20.20.2_aarch64_cortex-a53.ipk}
[ -f "$kuma_ipk" ] || { echo "no such ipk: $kuma_ipk" >&2; exit 1; }
[ -f "$node_ipk" ] || { echo "no such ipk: $node_ipk" >&2; exit 1; }

work=${SMOKE_WORK:-$feed/build/smoke-uptime-kuma}
ctr=uptime-kuma-smoke
mkdir -p "$work"
rm -rf "$work/kuma-root" "$work/node-root"
mkdir -p "$work/kuma-root" "$work/node-root"

unpack_ipk() {
	src=$1; dst=$2
	( cd "$dst" && ar x "$src" && tar xzf data.tar.gz )
}

unpack_ipk "$(cd "$(dirname "$kuma_ipk")" && pwd)/$(basename "$kuma_ipk")" "$work/kuma-root"
unpack_ipk "$(cd "$(dirname "$node_ipk")" && pwd)/$(basename "$node_ipk")" "$work/node-root"

cleanup() { docker rm -f "$ctr" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
docker rm -f "$ctr" >/dev/null 2>&1 || true
docker create --name "$ctr" --platform linux/arm64 alpine:3.12 sh -c 'sleep 3600' >/dev/null
docker start "$ctr" >/dev/null

docker exec "$ctr" apk add --no-cache libgcc >/dev/null
docker exec "$ctr" mkdir -p /opt/uptime-kuma /opt/node20
docker cp "$work/kuma-root/opt/uptime-kuma/." "$ctr:/opt/uptime-kuma/"
docker cp "$work/node-root/opt/node20/." "$ctr:/opt/node20/"

echo "libc: $(docker exec "$ctr" sh -c 'ls /lib/ld-musl-aarch64.so.1 && /opt/node20/bin/node -v')"

echo "sqlite3 addon test:"
docker exec "$ctr" sh -c 'cd /opt/uptime-kuma && \
	LD_LIBRARY_PATH=/opt/uptime-kuma/lib /opt/node20/bin/node -e "
	const s = require(\"./node_modules/@louislam/sqlite3\");
	const db = new s.Database(\":memory:\");
	db.serialize(() => {
		db.run(\"create table t(a int)\");
		db.run(\"insert into t values (42)\");
		db.get(\"select a from t\", (e, r) => {
			if (e || !r || r.a !== 42) { console.error(\"FAIL\", e, r); process.exit(1); }
			console.log(\"sqlite3 ok, a=\" + r.a);
			db.close();
		});
	});"'

docker exec -d "$ctr" sh -c 'cd /opt/uptime-kuma && \
	NODE_ENV=production UPTIME_KUMA_HOST=0.0.0.0 UPTIME_KUMA_PORT=3001 \
	DATA_DIR=/opt/uptime-kuma/data TZ=UTC LD_LIBRARY_PATH=/opt/uptime-kuma/lib \
	/opt/node20/bin/node server/server.js > /tmp/uptime-kuma.log 2>&1'

entry=''
i=0
while [ "$i" -lt 90 ]; do
	entry=$(docker exec "$ctr" wget -qO- http://127.0.0.1:3001/api/entry-page 2>/dev/null || true)
	[ -n "$entry" ] && break
	i=$((i + 1))
	sleep 1
done
if [ "$entry" != '{"type":"setup-database"}' ]; then
	docker exec "$ctr" sh -c 'tail -30 /tmp/uptime-kuma.log' >&2 || true
	echo "FAIL: /api/entry-page -> '$entry'" >&2
	exit 1
fi
echo "entry-page: $entry"

sleep 5
rss=$(docker exec "$ctr" sh -c '
	for p in /proc/[0-9]*; do
		c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null)
		case "$c" in
			*/opt/node20/bin/node\ server/server.js*)
				awk "/^VmRSS:/ {print \$2}" "$p/status"; break ;;
		esac
	done')
echo "RSS: ${rss:-unknown} kB"
if [ -z "$rss" ]; then
	echo "FAIL: cannot read server RSS" >&2
	exit 1
fi

echo "SMOKE OK"

#!/bin/sh
# Sanity-check one built ipk: unpack it, assert the expected payload, and
# report the numbers the issue asks for (unpacked size + sha256).
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

ar x "$abs_ipk"
[ -f debian-binary ] || fail 'debian-binary missing (not an ar ipk?)'
[ -f control.tar.gz ] || fail 'control.tar.gz missing'
[ -f data.tar.gz ] || fail 'data.tar.gz missing'

mkdir ctl
tar xzf control.tar.gz -C ctl
grep -qx 'Architecture: aarch64_cortex-a53' ctl/control || fail 'Architecture field wrong'
grep -qx 'Depends: libgcc1' ctl/control || fail 'Depends field wrong'

tar tzf data.tar.gz > filelist.txt
grep -qx './opt/node20/bin/node' filelist.txt || fail 'opt/node20/bin/node missing'
grep -qx './opt/node20/LICENSE' filelist.txt || fail 'opt/node20/LICENSE missing'
if grep -q '^\./opt/node20/include/' filelist.txt; then fail 'include/ still present'; fi
if grep -q '^\./opt/node20/lib/node_modules/npm/' filelist.txt; then fail 'npm/ still present'; fi
if grep -q '^\./opt/node20/lib/node_modules/corepack/' filelist.txt; then fail 'corepack/ still present'; fi
if grep -qx './opt/node20/bin/npm' filelist.txt; then fail 'dangling bin/npm link still present'; fi

mkdir root
tar xzf data.tar.gz -C root

bytes=$(du -sb root | cut -f1)
human=$(du -sh root | cut -f1)
case "$bytes" in
	''|*[!0-9]*) fail 'could not measure unpacked size' ;;
esac
if [ "$bytes" -lt 99614720 ] || [ "$bytes" -gt 115343360 ]; then
	fail "unpacked size outside 95-110 MiB window: $bytes bytes"
fi
printf 'unpacked: %s (%s bytes = %s.%s MiB)\n' \
	"$human" "$bytes" $((bytes / 1048576)) $(( (bytes % 1048576) * 10 / 1048576 ))

echo "ipk:      $abs_ipk"
echo "ipk size: $(wc -c < "$abs_ipk") bytes"
echo "sha256:   $(sha256sum "$abs_ipk" | cut -d' ' -f1)"
echo "control:"
sed 's/^/  /' ctl/control
echo "OK"

#!/bin/sh
# Run the packaged node binary against an aarch64 musl userspace.
#
# The issue's step 3 asks for `docker run --rm --platform linux/arm64`.
# This build runtime has no usable docker daemon (/run/docker.sock is not a
# live socket, no root, no rootless helpers), so the equivalent check is done
# with qemu-user on an Alpine 3.12 rootfs (musl 1.1.24 -> same libc as the
# device) plus the device's own libgcc1 package from OpenWrt 21.02.7
# armvirt/64. Nothing is installed on the host; everything lands in
# build/smoke/ and is hash-pinned below.
#
# Usage:  pixi run smoke
#     or  scripts/smoke-arm64.sh [path/to/node20_20.20.2_aarch64_cortex-a53.ipk]
#
# Requires inside the pixi environment: ar (binutils). Host tools: curl, tar,
# xz, gzip, sha256sum.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
feed=$(cd "$here/.." && pwd)
ipk=${1:-$feed/dist/node20_20.20.2_aarch64_cortex-a53.ipk}
[ -f "$ipk" ] || { echo "no such ipk: $ipk" >&2; exit 1; }

work=${SMOKE_WORK:-$feed/build/smoke}
mkdir -p "$work"

QEMU_URL=https://github.com/multiarch/qemu-user-static/releases/download/v7.2.0-1/qemu-aarch64-static
QEMU_SHA=dce64b2dc6b005485c7aa735a7ea39cb0006bf7e5badc28b324b2cd0c73d883f

ALPINE=alpine-minirootfs-3.12.12-aarch64.tar.gz
ALPINE_URL=https://dl-cdn.alpinelinux.org/alpine/v3.12/releases/aarch64/$ALPINE
ALPINE_SHA=619d19ab855c001772142a84791f4dabc7895dbb9a07019c94222cfb40374f3c

LIBGCC=libgcc1_8.4.0-3_aarch64_cortex-a53.ipk
LIBGCC_URL=https://downloads.openwrt.org/releases/21.02.7/targets/armvirt/64/packages/$LIBGCC
LIBGCC_SHA=70288de2e0eb910b4d3575921def19fec6947e07a4217b9f455392f44521506e

fetch() {
	url=$1; out=$2; sha=$3
	if [ -f "$out" ] && echo "$sha  $out" | sha256sum -c - >/dev/null 2>&1; then
		return 0
	fi
	echo "fetching $(basename "$out")"
	curl -fsSL --retry 3 --retry-delay 2 -o "$out.part" "$url"
	echo "$sha  $out.part" | sha256sum -c -
	mv "$out.part" "$out"
}

# OpenWrt 21.02 packages are gzipped tar; newer/standard ipks are ar archives.
unpack_ipk() {
	src=$1; dst=$2
	mkdir -p "$dst"
	if tar tzf "$src" >/dev/null 2>&1; then
		tar xzf "$src" -C "$dst"
	else
		( cd "$dst" && ar x "$src" )
	fi
}

fetch "$QEMU_URL" "$work/qemu-aarch64-static" "$QEMU_SHA"
chmod +x "$work/qemu-aarch64-static"
fetch "$ALPINE_URL" "$work/$ALPINE" "$ALPINE_SHA"
fetch "$LIBGCC_URL" "$work/$LIBGCC" "$LIBGCC_SHA"

rm -rf "$work/rootfs" "$work/node-ipk" "$work/libgcc-ipk"
mkdir -p "$work/rootfs" "$work/node-ipk" "$work/libgcc-ipk"

tar xzf "$work/$ALPINE" -C "$work/rootfs"
unpack_ipk "$ipk" "$work/node-ipk"
tar xzf "$work/node-ipk/data.tar.gz" -C "$work/rootfs"
unpack_ipk "$work/$LIBGCC" "$work/libgcc-ipk"
tar xzf "$work/libgcc-ipk/data.tar.gz" -C "$work/rootfs"

echo "rootfs libc: $(ls "$work"/rootfs/lib/ld-musl-aarch64.so.1) (Alpine 3.12 / musl 1.1.24)"
actual=$("$work/qemu-aarch64-static" -L "$work/rootfs" \
	"$work/rootfs/opt/node20/bin/node" -v)
echo "node -v -> $actual"
[ "$actual" = "v20.20.2" ] || { echo "FAIL: expected v20.20.2" >&2; exit 1; }

js=$("$work/qemu-aarch64-static" -L "$work/rootfs" \
	"$work/rootfs/opt/node20/bin/node" -e 'process.stdout.write(process.version + " " + process.arch)')
echo "node -e -> $js"
[ "$js" = "v20.20.2 arm64" ] || { echo "FAIL: unexpected JS result" >&2; exit 1; }

echo "SMOKE OK"

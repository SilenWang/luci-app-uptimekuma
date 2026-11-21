# node20 运行时（不随 Release 分发）

Uptime Kuma 2.5.12 要求 Node ≥ 20.4。OpenWrt 21.02 的 feed 里只有 14.21.3，
所以要自带一个运行时。这个包把 **Node 20.20.2 官方 `linux-arm64-musl` 预编译**
原样投放，不做交叉编译。

## 为什么是 20.20.2，不是 22

21.02 的 musl 是 **1.1.24**，没有 `pthread_getname_np`。Node 22 的 arm64-musl
构建一启动就报 `pthread_getname_np: symbol not found`（exit 127）；Node 20 不调
这个符号，实测 `node -v` 正常。

## 打包内容

- 安装到 `/opt/node20`，保留 `LICENSE`
- 删掉运行时用不到的：`include/`（54 MB）、`lib/node_modules/npm`（17 MB）、
  `corepack`，以及随 npm 一起变成悬空链接的 `bin/{npm,npx,corepack}`
- `Depends: libgcc1`；**不要**加 `libstdcpp6`——这个二进制静态链 libstdc++，
  `DT_NEEDED` 只有 `libgcc_s.so.1` 与 `libc.so`

## 产物

- `node20_20.20.2_aarch64_cortex-a53.ipk`：37,863,542 B
- 解包后 100.7 MiB
- sha256 `4f5cbcca8aee70c760e51b455b7202a4b2269482864564407d2e1978547745eb`
- 上游 tarball sha256 `02d7c51f40f165e248c80d01fd26a80ab9dc726737d971edc94a65dc1c74d613`

## 校验

```sh
pixi run make -C node20 verify
pixi run smoke                 # qemu-user + Alpine 3.12 rootfs（musl 1.1.24）
```

`verify.sh` 断言 `bin/node` 与 `LICENSE` 存在、`include/` 与 npm/corepack 不存在、
`Architecture: aarch64_cortex-a53`、`Depends: libgcc1`、体积在 95–110 MiB。

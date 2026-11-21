# OpenWrt feed（OpenWrt 21.02 / aarch64_cortex-a53 / musl）

手工维护的 ipk feed。包体是预编译产物，不做交叉编译：下载上游官方 tarball，
校验 sha256，裁掉运行时不需要的部分，再用 OpenWrt 生态的 `opkg-build` 打成 ipk。

目前包含：

| 包 | 上游产物 | 架构 |
| --- | --- | --- |
| `node20` | Node.js 20.20.2 `linux-arm64-musl`（unofficial-builds） | `aarch64_cortex-a53` |

## 依赖管理

整个流程是 Makefile + POSIX shell，不需要 Python/Node/Rust 运行时。
`pixi.toml` 只声明打包时用到的两个工具：

- `make` —— 构建入口
- `binutils` —— `opkg-build` 写 ipk 外层归档需要 `ar`

其余（`curl`、`tar`、`xz`、`gzip`、`sha256sum`）是系统基础工具。
**不要**用 pip/npm/apt 额外安装任何东西；需要新工具时先加进 `pixi.toml`。

## 构建

```sh
pixi install          # 只在首次需要
pixi run build        # 等价于 make，产出 dist/node20_20.20.2_aarch64_cortex-a53.ipk
```

产物在 `dist/`（已 gitignore）。单包也可以单独构建：

```sh
pixi run make -C node20
```

`node20/Makefile` 里的关键参数：

- `PKG_SOURCE_URL` / `PKG_HASH`：官方 tarball 与 sha256（失败即中止）
- 裁剪：`include/`（头文件）、`lib/node_modules/npm`、`lib/node_modules/corepack`，
  以及 `bin/{npm,npx,corepack}` 三个随 npm 一起删掉的悬空链接
- 安装前缀：`/opt/node20`，保留 `LICENSE`
- 控制字段：`Depends: libgcc1`（`node` 二进制的 `NEEDED` 只有 `libgcc_s.so.1`
  和 `libc.so`，libstdc++ 已静态链接，**不要**加 `libstdcpp6`）

## 打包链

用 **opkg-utils 0.5.0 的 `opkg-build`**（vendored 在 `scripts/opkg-build`，默认
`outer=ar`），不下载 21.02.7 SDK。理由：只需一个脚本，版本固定，产物是标准
ar 格式（`debian-binary` + `control.tar.gz` + `data.tar.gz`），`opkg` 和
`ar x` 都能直接读。

## 本次产物

- 文件：`dist/node20_20.20.2_aarch64_cortex-a53.ipk`
- ipk 大小：38,175,028 bytes（36.4 MiB）
- 解包后：105,668,047 bytes（100.7 MiB，在 95–110 MiB 验收窗口内）
- ipk sha256：`720e5db33fefcb8edd69587ad44421ce78f031e2f6e7c580cfedf98d31f872a4`
- 上游 tarball sha256：`02d7c51f40f165e248c80d01fd26a80ab9dc726737d971edc94a65dc1c74d613`

两次 `make clean && make` 得到完全相同的 ipk sha256：`SOURCE_DATE_EPOCH` 固定为上游
tarball 的 mtime（1774487510），`opkg-build` 用它给归档条目打时间戳，`gzip -9n`
不写时间戳与文件名。

## 校验

```sh
pixi run verify
```

`node20/verify.sh` 会 `ar x` 解包并断言：

- `opt/node20/bin/node` 与 `opt/node20/LICENSE` 存在
- `opt/node20/include/`、`opt/node20/lib/node_modules/npm/`、`corepack/` 不存在
- `control` 中 `Architecture: aarch64_cortex-a53`、`Depends: libgcc1`
- 解包总大小落在 95–110 MiB

手工解包（审计用）：

```sh
cd dist
ar x node20_20.20.2_aarch64_cortex-a53.ipk
tar tzf data.tar.gz
tar xzf data.tar.gz -C /tmp/node20-unpack
du -sb /tmp/node20-unpack
```

## arm64 冒烟

```sh
pixi run smoke          # scripts/smoke-arm64.sh
```

脚本用 qemu-user 在 **Alpine 3.12 rootfs（musl 1.1.24，与设备同 libc）** 上执行
包内的 `node`，并额外解入 OpenWrt 21.02.7 `armvirt/64` 的
`libgcc1_8.4.0-3_aarch64_cortex-a53.ipk`（设备同款 `libgcc_s.so.1`）：

```
node -v  -> v20.20.2
node -e  -> v20.20.2 arm64
```

qemu 静态二进制、rootfs、libgcc1 都按 sha256 固定在脚本里，只落在
`build/smoke/`，不安装到系统。它们会缓存，重复跑不会重新下载。

> 为什么不是 `docker run --platform linux/arm64`：当前构建 runtime 里没有可用的
> docker daemon（`/run/docker.sock` 不是活动 socket，无 root，也没有 rootless
> helper），所以改用 qemu-user 做同等保真的检查。在有 docker 的机器上可以直接跑：
>
> ```sh
> docker run --rm --platform linux/arm64 \
>   -v "$PWD/dist:/mnt" alpine:3.12 sh -c '
>     apk add --no-cache binutils libgcc >/dev/null &&
>     mkdir -p /tmp/x && cd /tmp/x && ar x /mnt/node20_20.20.2_aarch64_cortex-a53.ipk &&
>     tar xzf data.tar.gz -C / &&
>     node -v'
> ```
>
> 这条命令没有在本 runtime 执行过（无 docker），仅作为等价入口记录。

## 目录

```
feed/
├── pixi.toml            # make + binutils，任务 build/clean/distclean/verify/smoke
├── Makefile              # 顶层：make -> 各包
├── scripts/
│   ├── opkg-build        # opkg-utils 0.5.0（ar 外层）
│   └── smoke-arm64.sh    # qemu-user + Alpine 3.12 + OpenWrt libgcc1
├── node20/
│   ├── Makefile
│   ├── files/control     # ipk 控制文件模板
│   └── verify.sh
├── build/                # 下载缓存与装配中间目录（gitignore）
└── dist/                 # ipk 产物（gitignore）
```

本仓库只在本地 `git init`，不推远端。

# OpenWrt feed（OpenWrt 21.02 / aarch64_cortex-a53 / musl）

手工维护的 ipk feed。包体是预编译产物，不做交叉编译：下载上游官方 tarball，
校验 sha256，裁掉运行时不需要的部分，再用 OpenWrt 生态的 `opkg-build` 打成 ipk。

一个 OpenWrt 21.02（musl 1.1.24）上的 Uptime Kuma 原生运行方案：`node20` 提供
Node 20 运行时，`uptime-kuma` 带着装好的 `node_modules` 和官方前端，`luci-app-uptime-kuma`
是管理它们的 LuCI 外壳。设备侧零下载，`DATA_DIR` 落持久化分区。

目前包含：

| 包 | 上游产物 | 架构 |
| --- | --- | --- |
| `node20` | Node.js 20.20.2 `linux-arm64-musl`（unofficial-builds） | `aarch64_cortex-a53` |
| `uptime-kuma` | Uptime Kuma 2.5.12 源码 + 官方 `dist` + 构建期装好的 `node_modules` | `aarch64_cortex-a53` |
| `luci-app-uptime-kuma` | 无（本仓库自己写的 LuCI 外壳，纯文本） | `all` |

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
pixi run build        # 等价于 make，产出 dist/ 下两个 ipk
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

> `node20` 的冒烟是在 SIL-980 阶段做的，当时这个 runtime 还没有可用的 docker
> daemon，所以用 qemu-user + Alpine 3.12 rootfs 做等价检查。`uptime-kuma`
> 的构建/冒烟现在直接走 `docker --platform linux/arm64`。

## uptime-kuma

`uptime-kuma/` 产出 `dist/uptime-kuma_2.5.12_aarch64_cortex-a53.ipk`：
`server/` + 官方 `dist/` + 构建期装好的 `node_modules/`，装到
`/opt/uptime-kuma`，并附带 `/etc/init.d/uptime-kuma`（procd）与
`/etc/config/uptime-kuma`。

### 构建

```sh
pixi run make -C uptime-kuma          # 或 pixi run build（两个包一起）
```

构建在 **arm64/musl 的 `node:20-alpine` 容器**里跑（本 runtime 的 bind mount
不可用，源码与产物用 `docker cp` 进出）。输入全部按 sha256 固定：

| 输入 | sha256 |
| --- | --- |
| GitHub tag `2.5.12` 源码 tarball | `48f32d9651081f35cd69c84bf7cf26e131a5d9b9b1549b9f84980d67e67acb5e` |
| 官方 release `dist.tar.gz` | `8524bfbf0140de84fe14a5f3946bb322beaf7070aa51f36ebd568db1b9758472` |
| `@louislam/sqlite3` `napi-v6-linux-arm64-musl` 预编译 addon | `d14ab9d2a8611fc086c2c14ad9704592db499cab84b1dddb31df89240f6f493c` |
| Alpine 3.12 `libstdc++.so.6` | `fd9f4683f979345e58253b3d21e82c1f9af27996269c07404ed74fa2b0566d06` |

要点：

- `npm ci --omit dev`（649 包，`node_modules` 未裁剪 ~255 MB），并设置
  `npm_config_fallback_to_build=false`：sqlite3 只允许取上游
  `napi-v6-linux-arm64-musl` 预编译件，**回落源码编译就直接失败**（构建后还会
  校验 addon 的 sha256 和 `build-tmp-*` 是否存在）。
- 该 addon 的 `DT_NEEDED` 是 `libstdc++.so.6` + `libgcc_s.so.1` + `libc.musl-aarch64.so.1`。
  因此把 Alpine 3.12（musl 1.1.24，与设备同版）的 `libstdc++.so.6` 放进
  `/opt/uptime-kuma/lib`，init 脚本用 `LD_LIBRARY_PATH` 指过去；**不需要、
  也不写 `libstdcpp6` 依赖**。`libgcc_s.so.1` 由 `node20` 的 `libgcc1` 依赖提供。
  冒烟容器只 `apk add libgcc`、不装 libstdc++，`.node` 加载的就是包内
  `lib/libstdc++.so.6`，所以这条路径在 musl 1.1.24 上是实测过的。
- 前端直接用官方 release 的 `dist.tar.gz`，不在本地 vite build。
- `server/check-version.js` 的更新检查被关闭（非 git 安装无法自更新），
  `getSettings` 返回 `checkUpdate=false`，界面上更新按钮显示为关闭。
- 只跑本来就需要的东西：`server/`、`db/`（去掉开发用 `kuma.db`）、`dist/`、
  `node_modules/`、`package.json`、`src/util.js`、`extra/rdap-dns.json`。

### 裁剪

每轮单独量 `du -sk`（解包后的 `/opt/uptime-kuma`），每轮都在 arm64 容器里冒烟：

| 轮次 | 删除 | 解包后大小 | alpine:3.12 冒烟（`/api/entry-page`） |
| --- | --- | --- | --- |
| 0 | 不裁 | 270.4 MiB | — |
| 1 | `**/*.md` | 261.8 MiB | `{"type":"setup-database"}` ✓ |
| 2 | `**/*.map` | 205.8 MiB | `{"type":"setup-database"}` ✓ |
| 3 | `**/*.d.ts` | 170.5 MiB | ✓（低于 180 MiB 下限，回退） |
| 4 | `**/test/` | 164.8 MiB | ✓（低于 180 MiB 下限，回退） |

第 2 轮已经落进 180–220 MB 验收窗口（也贴合父任务 ~207 MB 的体积预算），
所以第 3、4 轮只做测量、不落包；再裁会让包低于下限。`*.md`/`*.map` 的冒烟
结果与最终树一致（最终树是第 2 轮的超集裁剪）。四轮冒烟容器里都没有系统
`libstdc++.so.6`，只靠包内 `lib/` 的那份。

### 服务与 uci

`/etc/config/uptime-kuma` 默认值：

```
config uptime-kuma 'main'
	option enabled '1'
	option listen '0.0.0.0'
	option port '3001'
	option data_dir '/opt/uptime-kuma/data'
	option tz 'UTC'
```

init 脚本用 `/opt/node20/bin/node server/server.js` 启动（`dist/index.html`
是相对 cwd 读取的）。procd 21.02 **没有 `cwd` 参数**，所以命令写成
`/bin/sh -c "cd /opt/uptime-kuma && exec /opt/node20/bin/node server/server.js"`，
再交给 procd 管 pid；环境变量用
`UPTIME_KUMA_HOST` / `UPTIME_KUMA_PORT` / `DATA_DIR` / `TZ`，并加
`LD_LIBRARY_PATH=/opt/uptime-kuma/lib`。procd 负责 respawn、日志和 uci 变更
触发的 reload。不改 `HOST`（`server/config.js` 会读系统 `HOST`）。

手工起服务时要带上同一个 `LD_LIBRARY_PATH`（init 已带）：

```sh
cd /opt/uptime-kuma
LD_LIBRARY_PATH=/opt/uptime-kuma/lib /opt/node20/bin/node server/server.js
```

### 校验与冒烟

```sh
pixi run make -C uptime-kuma verify   # ipk 结构/control/体积/addon 身份
pixi run smoke-uptime-kuma            # alpine:3.12 + node20 ipk 里真启动
```

2026-11-21 本 runtime 结果：

- ipk：39,751,260 bytes（37.9 MiB）
- 解包后：210,688 KiB（`du -sk`，205.8 MiB；`du -sb` 135,663,397 bytes）
- ipk sha256：`657ee5739bf5b62841cd7b1e1398d6875c1e1bfc3edafe29d6cdba917c8ffcf3`
- 干净重建两次得到同一 sha256（`SOURCE_DATE_EPOCH` 固定为 tag 的 mtime）
- `verify.sh` 会对 `.node` 和包内 `libstdc++.so.6` 做 `readelf -d`：NEEDED 必须是
  `libc.musl-aarch64.so.1` + `libgcc_s.so.1`（+`.node` 的 `libstdc++.so.6`），
  不能出现 glibc 的 `libc.so.6`；两个文件的 sha256 同时固定
- `alpine:3.12`（musl 1.1.24）+ 包内 `/opt/node20/bin/node`：
  - `@louislam/sqlite3` 能 `dlopen`，内存库建表/读写通过
  - `/api/entry-page` → `{"type":"setup-database"}`
  - qemu-user 下 RSS 362,164 kB；同一棵树在原生 x64 node 20.20.2 下
    RSS 133,256 kB，设备侧参考值 139–157 MB。qemu 的 TCG 翻译缓存会把
    RSS 抬高约 200 MB，**RSS 的 140–170 MB 验收请在 arm64 真机/原生容器里看**。

## luci-app-uptime-kuma

纯文本包，`Architecture: all`，不打任何编译产物。载荷六个文件：

- `www/luci-static/resources/view/uptime-kuma/overview.js` —— 页面（启停/端口与监听地址/数据目录/日志/打开面板/备份）
- `usr/share/luci/menu.d/luci-app-uptime-kuma.json` —— 菜单，`Services → Uptime Kuma`
- `usr/share/rpcd/acl.d/luci-app-uptime-kuma.json` —— `service list`、`file exec`（`/sbin/logread`、init 脚本、备份脚本）、`uci` 读写
- `usr/libexec/luci-app-uptime-kuma/backup` —— 服务端备份，`data_dir` 只从 UCI 读，请求里传不进路径
- `usr/lib/lua/luci/i18n/luci-app-uptime-kuma.zh-cn.lmo` —— 编译好的中文目录（设备上不需要 python/po2lmo）
- `etc/uci-defaults/90_luci-app-uptime-kuma` —— 首次安装只放行 LAN 侧一个 TCP 端口；`prerm` 删规则但**不删数据目录**

构建与校验：

```sh
pixi run make -C luci-app-uptime-kuma          # 产出 dist/luci-app-uptime-kuma_1.0.0_all.ipk
./luci-app-uptime-kuma/verify.sh dist/luci-app-uptime-kuma_1.0.0_all.ipk
```

`verify.sh` 是纯静态的：JSON/`node --check`/`sh -n`、ACL 与 view 实际调用逐项对齐、
翻译 `.po`↔`.lmo`↔msgid 一致性、载荷清单与体积。**渲染、procd 拉起、防火墙规则是否生效
属于 Stage 3 真机验证，脚本里没有任何 mock。**

注意：脚本里引用 UCI 一律写全 `uptime-kuma.main.<option>`（`/etc/config/uptime-kuma`
的唯一 section 是 `config uptime-kuma 'main'`）。写成 `@service[0]` 不会报错，只会静默
读空、退回默认值——端口/数据目录就会和页面里配的对不上。`verify.sh` 有一条守卫盯这个。

## 目录

```
feed/
├── pixi.toml            # make + binutils，任务 build/clean/verify/smoke/smoke-uptime-kuma
├── Makefile              # 顶层：make -> 各包
├── scripts/
│   ├── opkg-build        # opkg-utils 0.5.0（ar 外层）
│   └── smoke-arm64.sh    # qemu-user + Alpine 3.12 + OpenWrt libgcc1
├── node20/
│   ├── Makefile
│   ├── files/control     # ipk 控制文件模板
│   └── verify.sh
├── uptime-kuma/
│   ├── Makefile          # arm64 容器里 npm ci，装配 /opt/uptime-kuma
│   ├── files/control
│   ├── files/uptime-kuma.init
│   ├── files/uptime-kuma.config
│   ├── verify.sh
│   └── smoke.sh          # alpine:3.12 + node20 ipk 启动冒烟
├── build/                # 下载缓存与装配中间目录（gitignore）
└── dist/                 # ipk 产物（gitignore）
```

## 许可证

本仓库自身（Makefile、校验脚本、LuCI 外壳）为 MIT，见 `LICENSE`。随包的第三方
产物保留各自许可：Node.js 20（MIT，包内 `/opt/node20/LICENSE`）、Uptime Kuma 2.5.12
（MIT）、从 Alpine 3.12 取的 `libstdc++.so.6`（GPL-2.0 WITH GCC-exception-3.1）。

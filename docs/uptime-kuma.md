# uptime-kuma 包

`uptime-kuma/` 产出 `dist/uptime-kuma_2.5.12-1_aarch64_cortex-a53.ipk`：`server/` +
官方 `dist/` + 构建期装好的 `node_modules/`，装到 `/opt/uptime-kuma`，附
`/etc/init.d/uptime-kuma`（procd）、`/etc/config/uptime-kuma`、`CONTROL/prerm`。

## 构建

```sh
pixi run make -C uptime-kuma
```

在 **arm64/musl 的 `node:20-alpine` 容器**里 `npm ci --omit dev`（649 包）。输入全部
按 sha256 固定：

| 输入 | sha256 |
| --- | --- |
| tag `2.5.12` 源码 tarball | `48f32d9651081f35cd69c84bf7cf26e131a5d9b9b1549b9f84980d67e67acb5e` |
| 官方 release `dist.tar.gz` | `8524bfbf0140de84fe14a5f3946bb322beaf7070aa51f36ebd568db1b9758472` |
| `@louislam/sqlite3` `napi-v6-linux-arm64-musl` | `d14ab9d2a8611fc086c2c14ad9704592db499cab84b1dddb31df89240f6f493c` |
| Alpine 3.12 `libstdc++.so.6` | `fd9f4683f979345e58253b3d21e82c1f9af27996269c07404ed74fa2b0566d06` |

要点：

- `npm_config_fallback_to_build=false`：sqlite3 只允许取上游 musl 预编译件，
  回落源码编译直接失败；构建后还校验 addon sha256 并确认没有 `build-tmp-*`。
- 该 addon 的 `DT_NEEDED` 是 `libstdc++.so.6` + `libgcc_s.so.1` + `libc.musl-aarch64.so.1`，
  所以把 Alpine 3.12 的 `libstdc++.so.6` 放进 `/opt/uptime-kuma/lib`，init 用
  `LD_LIBRARY_PATH` 指过去；不写 `libstdcpp6` 依赖。注意 addon 的目录名是
  `napi-v6-linux-arm64`（不带 `-musl`），判断 libc 要看 ELF 而不是路径。
- 前端用官方 `dist.tar.gz`，不在本地 vite build。
- `check-version.js` 的更新检查关闭（非 git 安装无法自更新），界面更新按钮显示关闭。
- `db/kuma.db` 是首启模板（`Database.templatePath`，`copyFileSync` 到 `DATA_DIR`），
  **必须随包发**；删掉它会让 setup 之后主服务 `ENOENT` 退出进 crash loop。

## 裁剪

每轮单独量解包后大小并冒烟：

| 轮次 | 删除 | 解包后 | 结果 |
| --- | --- | --- | --- |
| 1 | `**/*.md` | 261.8 MiB | 通过 |
| 2 | `**/*.map` | 205.8 MiB | 通过（落包） |
| 3 | `**/*.d.ts` | 170.5 MiB | 低于 180 MiB 下限，回退 |
| 4 | `**/test/` | 164.8 MiB | 同上，回退 |

## 服务与 uci

```
config uptime-kuma 'main'
	option enabled '1'
	option listen '0.0.0.0'
	option port '3001'
	option data_dir '/opt/uptime-kuma/data'
	option tz 'UTC'
```

init 用 `/opt/node20/bin/node server/server.js` 启动。`dist/index.html` 是相对 cwd
读的，而 procd 21.02 **没有 `cwd` 参数**（写了会被静默忽略，进程留在 `/`），所以命令写成
`/bin/sh -c "cd /opt/uptime-kuma && exec /opt/node20/bin/node server/server.js"`。
环境变量用 `UPTIME_KUMA_HOST` / `UPTIME_KUMA_PORT` / `DATA_DIR` / `TZ` 加
`LD_LIBRARY_PATH=/opt/uptime-kuma/lib`；不改 `HOST`（`server/config.js` 会读系统 `HOST`）。

`postinst` 在 `/etc/config/uptime-kuma` 丢失时补回默认配置（否则 init 读到 `enabled=0`，服务静默不启动）。`prerm` 在卸载时 `stop` + `disable`：opkg 不管 `/etc/rc.d` 链接，没有它会留下一个
仍占着 3001 的 node 进程。数据目录任何情况下都不动。

## 产物与校验

- ipk 39,616,023 B，解包 205.8 MiB
- sha256 `c0cbc3f92f9c585697e9c0a8fd7dd6ac8e9c534ebe5d4dec5f51b5c0cd3ea307`
- `pixi run make -C uptime-kuma verify`；`pixi run smoke-uptime-kuma` 在
  `alpine:3.12` + 包内 node20 里跑到 `{"type":"setup-database"}` → `{"ok":true}` →
  `/dashboard` 200

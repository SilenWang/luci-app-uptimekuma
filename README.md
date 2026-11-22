# luci-app-uptimekuma

在 OpenWrt 21.02（musl 1.1.24，`aarch64_cortex-a53`）上原生运行 Uptime Kuma，
并提供一个 LuCI 管理页：启停服务、改端口/监听地址/数据目录、看日志、打开面板、一键备份。

设备侧不联网安装：`node_modules` 与官方前端都在构建期装好随包发；数据库落在
持久化分区（默认 `/opt/uptime-kuma/data`），升级和卸载都不会动它。

## 包

| 包 | 版本 | 内容 |
| --- | --- | --- |
| `uptime-kuma` | 2.5.12-2 | 服务端 + 官方 `dist` + 构建期装好的 `node_modules`，附 procd/uci/prerm/postinst |
| `luci-app-uptime-kuma` | 1.0.3 | LuCI 外壳（纯文本，`Architecture: all`）；同时支持新版 JS LuCI 与老式 Lua LuCI |

`node20` 只是本仓库用来产出运行时的打包配方，不属于发布物，Release 里不提供。
Uptime Kuma 2.5.12 需要 Node ≥ 20.4，用官方的 arm64-musl 构建即可：
<https://unofficial-builds.nodejs.org/download/release/v20.20.2/node-v20.20.2-linux-arm64-musl.tar.xz>
（22.x 在这类 musl 1.1.24 固件上起不来，见 `docs/node20.md`。）

## 安装

从 [Releases](https://github.com/SilenWang/luci-app-uptimekuma/releases) 下载两个 ipk，
连同上面那个 Node 20 运行时一起装：

```sh
opkg install ./node20_*.ipk ./uptime-kuma_*.ipk ./luci-app-uptime-kuma_*.ipk
/etc/init.d/uptime-kuma enable && /etc/init.d/uptime-kuma start
```

浏览器打开 `http://<设备 IP>:3001/` 完成初始化；LuCI 里在 **Services → Uptime Kuma**。

## 文档

- [构建与打包](docs/build.md) —— pixi、`make`、为什么 ipk 必须是 gzip-tar
- [node20 运行时](docs/node20.md) —— 为什么钉 20.20.2、裁剪、依赖
- [uptime-kuma 包](docs/uptime-kuma.md) —— arm64 容器构建、裁剪、procd/uci、踩过的坑
- [LuCI 外壳](docs/luci-app.md) —— 页面能力、ACL、防火墙跟随、i18n
- [验收记录](docs/testing.md) —— 本地与 photonicat 真机结果、已知限制

## 许可证

本仓库自身 MIT，见 `LICENSE`；随包的第三方产物保留各自许可。

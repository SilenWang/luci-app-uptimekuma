# 验收记录

两端都验过：本地 arm64/musl 1.1.24 容器（与目标固件同 libc），以及一台真实
photonicat（RK3568，OpenWrt 21.02 `R21.8.6`，`armvirt/64`，`aarch64_cortex-a53`）。

## 真机结果

| 项 | 结果 |
| --- | --- |
| 三包 `opkg install` | `exit 0`，无依赖冲突、无缺 `.so` |
| procd 自启 | `S99` 链接在，`ubus call service list` → `running: true` |
| `/api/entry-page` | `setup-database` → `{"ok":true}` → `/dashboard` 200 + `<!DOCTYPE html>` |
| 冷启动 | 重启后自启、`kuma.db` 在、能登录、监控心跳正常 |
| `VmRSS` | 131.7–136.9 MB（设计区间 140–160，实测更低，按实测接受） |
| 改端口 | 3001↔3002 生效，`firewall.uptime_kuma.dest_port` 跟随 |
| 备份 | 产出 tgz，`tar tzf` 8 项 |
| 卸载 | 停服务、清 `/etc/rc.d` 链接、删防火墙规则，`/opt/uptime-kuma/data` 与 conffile 保留 |

## 已知限制

- **浏览器点按未做**：参考设备 80 端口被占、无 root 明文口令。页面调用的每条后端
  路径（`ubus file exec` / `uci` / `firewall`）都在真机上单独验过。
- **`opkg remove` 留空目录**：opkg 只删文件，`/opt/uptime-kuma` 下会剩一批空目录项。
  计划在后续版本加 `postrm` 清空。
- **真实浏览器监控不支持**：依赖 chromium，OpenWrt 上没有。
- **RSS 口径**：procd 会把进程名改成实例名，`pgrep -f server.js` 取不到；用
  `ubus call service list` 的 pid 读 `/proc/<pid>/status`。

## 本地冒烟

```sh
pixi run smoke               # node20：qemu-user + Alpine 3.12
pixi run smoke-uptime-kuma   # uptime-kuma：alpine:3.12 + 包内 node20，跑到 /dashboard
```

qemu 下 RSS 会被 TCG 翻译缓存抬高约 200 MB，不要在本地拿 RSS 做验收。

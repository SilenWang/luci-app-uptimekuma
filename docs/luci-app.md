# LuCI 外壳

纯文本包，`Architecture: all`，`Depends: luci-base`，**同一份包同时支持两种 LuCI**：

- 新版（JS）LuCI：`/usr/share/luci/menu.d` + `/www/luci-static/resources/view/...`
- 老式（Lua）LuCI（不少厂商 21.02 固件仍是 bootstrap 主题）：`/usr/lib/lua/luci/controller/uptimekuma.lua`
  + `/usr/lib/lua/luci/view/uptime-kuma/overview.htm`

两个运行时各读自己那份，另一份忽略，互不冲突。判断固件属于哪种：`ls /www/luci-static/resources/luci.js`
存在即 JS 版；只有 `/usr/lib/lua/luci/controller/*.lua` 且主题是 bootstrap 就是 Lua 版。

载荷九个文件：

| 文件 | 作用 |
| --- | --- |
| `www/luci-static/resources/view/uptime-kuma/overview.js` | 页面：启停、监听地址/端口、数据目录、日志、打开面板、备份 |
| `usr/share/luci/menu.d/luci-app-uptime-kuma.json` | 菜单 `Services → Uptime Kuma` |
| `usr/share/rpcd/acl.d/luci-app-uptime-kuma.json` | `service list`、`file exec`（logread/init/备份/防火墙同步）、`uci` 读写 |
| `usr/libexec/luci-app-uptime-kuma/backup` | 服务端备份；`data_dir` 只从 uci 读，请求里传不进路径 |
| `usr/libexec/luci-app-uptime-kuma/sync-firewall` | `Save & Apply` 后把 `firewall.uptime_kuma.dest_port` 对齐到新端口 |
| `usr/lib/lua/luci/i18n/luci-app-uptime-kuma.zh-cn.lmo` | 编译好的中文目录 |
| `etc/uci-defaults/90_luci-app-uptime-kuma` | 首次安装只放行 LAN 侧一个 TCP 端口 |
| `usr/lib/lua/luci/controller/uptimekuma.lua` | 老式 Lua LuCI 的路由注册 |
| `usr/lib/lua/luci/view/uptime-kuma/overview.htm` | 老式 Lua LuCI 的页面模板 |

## 几个设计取舍

- **不重写监控面板**：Uptime Kuma 是 socket.io 驱动的 SPA，重写等于重做产品。
  页面只给外链；它默认发 `X-Frame-Options: SAMEORIGIN`，内嵌只会是空白页。
- **防火墙规则只建一次**（安装钩子），之后由 `sync-firewall` 跟随端口；`listen`
  改成回环则删规则，规则被操作者删掉则不重建。
- **UCI 一律写全 `uptime-kuma.main.<option>`**。写成 `@service[0]` 不会报错，只会
  静默读空、退回默认值——`verify.sh` 有一条守卫盯这个。
- ACL 漏 scope 是静默 403 而不是加载报错，所以 `verify.sh` 把 view 里实际用到的
  动作和 ACL 逐项对齐。
- **`postinst` 会清 `/tmp/luci-indexcache*` 并重启 `rpcd`。** LuCI 的路由表来自
  `menu.d`，而 rpcd 只在启动时读 `acl.d`；不重启它，装完包访问
  `/admin/services/uptime-kuma` 会得到 "No page is registered"（菜单节点因为 ACL
  组未知被丢掉），要等重启才恢复。老 session 还需要重新登录一次。

## 前置：rpcd-mod-file

页面用 `fs.exec` 调 init 脚本/日志/备份，需要 rpcd 的 `file` 对象。原厂固件若没带，
装 `rpcd-mod-file`（21.02 官方源有；注意它依赖的 `libubus20210630` 版本可能比
固件里的新）。没有它页面能打开，但按钮会失败。

## 构建与校验

```sh
pixi run make -C luci-app-uptime-kuma
./luci-app-uptime-kuma/verify.sh dist/luci-app-uptime-kuma_1.0.4_all.ipk
```

`verify.sh` 是纯静态的：JSON 解析、`node --check`、`sh -n`、require 白名单、
uci 寻址守卫、载荷无 CJK、`.po`↔`.lmo`↔msgid 一致性、ipk 控制字段/ACL/载荷清单。

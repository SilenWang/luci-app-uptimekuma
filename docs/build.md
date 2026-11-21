# 构建与打包

## 工具链

整个流程是 Makefile + POSIX shell，不需要 Python/Node/Rust 运行时。`pixi.toml`
只声明两个工具：`make` 与 `binutils`（`opkg-build` 写外层归档要用 `ar`）。
其余（`curl`、`tar`、`xz`、`gzip`、`sha256sum`）是系统基础工具。

```sh
pixi install
pixi run build                 # 三个包依次构建，产物在 dist/
pixi run make -C uptime-kuma   # 也可以单包构建
pixi run verify                # 逐包跑 verify.sh
```

`uptime-kuma` 的构建需要 docker（arm64 容器里跑 `npm ci`），其余两个不需要。

## 为什么 ipk 必须是 gzip-tar

`scripts/opkg-build` 是 vendored 的 opkg-utils 0.5.0，三个包的 Makefile 一律带
`-c`，产出 gzip 压缩的 tar，成员是 `./debian-binary`、`./control.tar.gz`、
`./data.tar.gz`。

设备上的 opkg 是 `1bf042dd06751b693a8544d2317e5b969d666b69 (2021-06-13)`，读不了
Debian `ar` 容器：小包报 `pkg_init_from_file: Malformed package file`，38/39 MB 的
大包直接 `Segmentation fault`。官方 21.02 镜像里的 ipk 同样是 gzip-tar。

`control.tar.gz` 里的 conffiles 必须是独立的 `CONTROL/conffiles` 文件，不能写成
`control` 里的 `Conffiles:` 字段——opkg 0.4 会报 `Failed to parse Conffiles line`
并拒绝整包。

## 可复现

每个包都固定 `SOURCE_DATE_EPOCH`（上游 tarball 的 mtime），输入按 sha256 锁定，
`rm dist/*.ipk && pixi run make` 两次得到相同 sha256。

## 目录

```
feed/
├── pixi.toml            # make + binutils
├── Makefile             # 顶层：PACKAGES 依次构建
├── scripts/opkg-build   # opkg-utils 0.5.0
├── node20/              # Node 运行时（不随 Release 发）
├── uptime-kuma/
└── luci-app-uptime-kuma/
```

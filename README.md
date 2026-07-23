# 360T7 ImmortalWrt ImageBuilder

本仓库只使用 ImmortalWrt `24.10-SNAPSHOT` 的
`mediatek/filogic` ImageBuilder，为 `qihoo_360t7` 生成专用
SquashFS sysupgrade 镜像。构建流程不会生成、接受或发布其他机型固件。

## 集成内容

- 构建时读取 ImmortalWrt 官方 `profiles.json`，校验目标、架构、内核和
  `qihoo,360t7` supported device。
- 从 `kenzok8/openwrt-daede` 的当前最新 Release 下载
  `daed`、`luci-app-daede` 和 `vmlinux-btf` IPK。
- 对已校验的 daed IPK 做最小构建兼容修补：保留 Release 二进制与
  `cleanup.sh`，只给 init 脚本的绝对引用增加 ImageBuilder rootfs
  相对路径回退，避免其在 Ubuntu 宿主环境执行时错误退出。
- BTF 必须同时匹配 ImageBuilder 的内核版本和
  `aarch64_cortex-a53` 架构；没有唯一匹配项时构建立即失败。
- 生成后检查包 manifest，确认 `daed`、`luci-app-daede` 和
  `vmlinux-btf` 已进入固件。
- 只保留并发布文件名包含 `qihoo_360t7` 的 sysupgrade 镜像。
- 全新安装的默认 LAN 地址为 `192.168.233.1`。

## GitHub Actions 构建

打开仓库的 **Actions** 页面，选择
**Build 360T7 ImageBuilder firmware**，点击 **Run workflow**。
工作流也会在每天北京时间 04:30 检查并构建当前组合；同一版本的
Release 会更新原有资产，不创建其他机型产物。

构建成功后可从 Actions artifact 或仓库 Releases 下载：

- `*qihoo_360t7*sysupgrade.itb`
- 对应包清单、固件元数据和 SHA-256 校验文件
- 外部 daed/BTF IPK 的 SHA-256 清单

## 本地 Linux 构建

需要 Linux x86_64、约 5 GB 可用空间，以及 `curl`、`jq`、`make`、
`tar`、`zstd` 等基础工具：

```bash
chmod +x scripts/build.sh
./scripts/build.sh
```

产物输出到 `dist/`。`work/` 和 `dist/` 均为临时生成目录。

## 刷写限制

只允许在 Qihoo 360T7 上通过 sysupgrade 使用本仓库生成的镜像。
刷写前必须校验 SHA-256，并确认文件名包含
`mediatek-filogic-qihoo_360t7`。不要在其他型号或其他分区布局的设备上
尝试刷写。

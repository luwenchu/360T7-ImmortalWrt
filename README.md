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
  `vmlinux-btf` 已进入固件，并且版本与下载的 Release IPK control
  字段完全一致；不允许回退到 ImmortalWrt 软件源中的旧版本。
- daed 服务保持默认禁用，完成配置并确认路由策略后再启用，避免新刷固件
  在未配置状态下接管流量。
- 只保留并发布文件名包含 `qihoo_360t7` 的 sysupgrade 镜像。
- 上游 ImageBuilder 即使完成 FIT 和校验和也可能返回非零；工作流不以该
  状态单独判定成功，而是强制执行机型、包清单和固件元数据校验。
- 全新安装的默认 LAN 地址为 `192.168.233.1`。

## GitHub Actions 构建

打开仓库的 **Actions** 页面，选择
**Build 360T7 ImageBuilder firmware**，点击 **Run workflow**。
工作流也会在每天北京时间 04:30 检查并构建当前组合；同一版本的
Release 会更新原有资产，不创建其他机型产物。

构建成功后可从 Actions artifact 或仓库 Releases 下载：

- `*qihoo_360t7*sysupgrade.itb`
- 同一 ImageBuilder 版本的 `*qihoo_360t7*initramfs-recovery.itb`
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

## 正确刷写入口

不要把 `squashfs-sysupgrade.itb` 上传到 U-Boot 自身的 Web 更新页面；
该页面会按 U-Boot 的固件格式规则拒绝 sysupgrade 文件，改成 `.bin`
后缀也不会改变内部格式。

如果现有 ImmortalWrt 可以正常启动，直接在 LuCI 的“备份/升级”页面
上传 `squashfs-sysupgrade.itb`，或者通过 SSH 执行：

```bash
sysupgrade -n /tmp/immortalwrt-*-qihoo_360t7-*-squashfs-sysupgrade.itb
```

如果只能进入 U-Boot，先通过 U-Boot/TFTP 启动 Release 中的
`initramfs-recovery.itb`。某些 360T7 U-Boot 固定请求以下文件名，
部署到 TFTP 根目录前需要重命名：

```text
openwrt-mediatek-filogic-qihoo_360t7-initramfs-recovery.itb
```

恢复系统启动后访问 `192.168.1.1`，再上传本仓库生成的
`squashfs-sysupgrade.itb`。initramfs 只用于在内存中启动恢复环境，
不包含 daed；daed 和匹配 BTF 位于最终 sysupgrade 固件中。

## 刷写限制

只允许在 Qihoo 360T7 上通过 sysupgrade 使用本仓库生成的镜像。
刷写前必须校验 SHA-256，并确认文件名包含
`mediatek-filogic-qihoo_360t7`。不要在其他型号或其他分区布局的设备上
尝试刷写。

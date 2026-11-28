# 发行版矩阵

[English](../en/distributions.md) | [中文](distributions.md)

每个发行版有一个自包含的 `golden/<distro>/golden-image-setup-<distro>.sh`，运行
共享的 A–F 定制流程；宿主侧辅助脚本与打包器在 `golden/shared/` 下。每个脚本内嵌
`initramfs-nbft` 组件与 GRUB 2.14 产物，单文件即可拷入母盘运行。组件变更后
重新运行 `python3 golden/shared/embed-components.py`。

## 支持的发行版

| 发行版 | 版本 | 内核 | 验收 |
|---|---|---|---|
| Debian 12 | bookworm | 6.12（backports） | TLS 冷启动；源码构建 NVMe 用户态（workaround） |
| Debian 13 | 13.6.0 | 6.12（自带） | TLS 冷启动 |
| Ubuntu 24.04 | 24.04 LTS | 6.8（GA） | TLS 冷启动；源码构建 ktls-utils（workaround） |
| Ubuntu 26.04 | 26.04 LTS | 7.0（自带） | TLS 冷启动 |
| Fedora 44 | 44 | 6.19（自带） | TLS 冷启动；dracut 网络模块 override（workaround） |
| AlmaLinux 10.2 | 10.2 | 6.12（`CONFIG_NVME_TCP_TLS=y`） | TLS 冷启动；dracut 网络模块 override（workaround） |
| openSUSE Leap 16.0 | 16.0 | 6.12（`CONFIG_NVME_TCP_TLS=y`） | TLS 冷启动；dracut 网络模块 override（workaround） |
| Arch Linux | rolling（2026.11.01 ISO） | 7.3.6-arch1-1 | TLS 冷启动；源码构建 ktls-utils（workaround） |

验收运行使用各发行版原生的无人值守安装方式，但仓库不把安装输入作为交付物。仅保留
三份验收夹具：`golden/almalinux10/almalinux10.ks.in`、
`golden/archlinux/archinstall.json.in` 与
`golden/opensuse-leap16/leap16-profile.json`。安装按使用者自己的流程完成，A–F 从
已安装系统开始。

三个发行版需要源码构建 NVMe 用户态工具，因为其发行版没有打包 TLS 能力的组件：

- Debian 12（bookworm）构建 `ktls-utils`、`libnvme`、`nvme-cli`；代价记录在
  [验收记录](archive/debian12-tls-coldboot-verification.md)（源码约 1.24 MiB、
  落盘产物约 6.22 MiB、母盘保留约 50.2 MiB 构建依赖；三个组件在 apt 之外，
  不会升级或打补丁）。
- Ubuntu 24.04 自带 ktls-utils 0.9，其 `tlshd` 缺少 `gnutls_psk_*` 符号，
  内核 TLS 握手报 `-5`；定制脚本 purge 后源码构建固定版本 ktls-utils 1.5.0。
- Arch Linux 为滚动发行版；矩阵以 2026.11.01 ISO 与内核 7.3.6-arch1-1 为实测
  基线，定制脚本按固定标签与提交构建 ktls-utils 1.5.0；initramfs 使用
  mkinitcpio 钩子（`install/nbft`、`hooks/nbft`），移除 `autodetect`，并经
  `dhcpcd` 获取地址。

Fedora、AlmaLinux 与 openSUSE Leap 使用 dracut，其 `kernel-network-modules`
会拉入整个 `drivers/net`（`--no-hostonly` 下还会经 `kernel-modules` 拉入 GPU
模块）。dracut 没有受支持的参数能约束该集合，共享定制用固定有线网卡 allowlist
替换 `kernel-network-modules` 的 `module-setup.sh` 并 `--omit drm`。initramfs
因此只含 allowlist 内的有线网卡驱动，无线、USB 网卡与 GPU/DRM 模块被排除；
dracut 重排模块目录时需重验该 override。

## 验收判据

目标端记录 **两条** 控制器记录——固件段与内核段各一条。DH-HMAC-CHAP 路径记录
`..., DH-HMAC-CHAP`；TLS 路径记录 `..., TLS.`，并加抓包判据：到数据端口的每条
客户端连接首字节为 `0x16`，明文端口 4420 的包数为 0（由
`test/shared/pcap-flows.py` 判定）。串口出现登录提示。

## A–F 定制流程

| 阶段 | 内容 |
|---|---|
| A | 系统与内核（需要时用 backports 内核；`ktls-utils` / `keyutils`） |
| B | `initramfs-nbft` 种子模块（NBFT/NBCT 消费、hostid 修复） |
| C | 系统配置（fstab root UUID、DHCP、hostname 占位） |
| D | GRUB 引导参数（`net.ifnames=0 ip=dhcp nbft_auto` + initrd 模块屏蔽） |
| E | 磁盘格式（4K 原生 GPT + 4K FAT32 ESP + GRUB；交互确认） |
| F | 无状态校验（盘内零身份硬编码） |

阶段 E 把盘转为 4K 语义，之后盘仅作为 SAN 4K 导出或 4Kn 设备可读。
`--skip-disk --yes` 只跳过 GPT/ESP 重建，仍刷新 ESP 内容。

## 新增发行版

1. 从最接近的现有变体派生脚本，逐项核对参数（安装器内核/initrd 文件名、
   使用无人值守安装器时的引导参数、包管理源格式）；目标盘用 4K 逻辑块。
2. 用自有流程安装并关机。
3. 用 `golden/shared/golden-vm-run.sh`（或 `golden-ubuntu-vm-run.sh`）启动定制 VM，
   拷入脚本并运行 A–F。
4. 运行隔离的宿主侧验收（见 [verification.md](verification.md)）；生产桥与端口不动。
5. 组件变更后重新内嵌，并运行 `test/test-nbft-connect-nbct.sh`。

各发行版的排障说明保留在归档中。

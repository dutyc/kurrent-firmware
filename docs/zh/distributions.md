# 发行版矩阵

[English](../en/distributions.md) | [中文](distributions.md)

每个发行版有一个自包含的 `test/<distro>/golden-image-setup-<distro>.sh`，运行
共享的 A–F 定制流程；宿主侧辅助脚本与打包器在 `test/shared/` 下。每个脚本内嵌
`initramfs-nbft` 组件与 GRUB 2.14 产物，单文件即可拷入母盘运行。组件变更后
重新运行 `python3 test/shared/embed-components.py`。

## 支持的发行版

| 发行版 | 版本 | 无人值守 | 内核 | 验收 |
|---|---|---|---|---|
| Debian 12 | bookworm | preseed（d-i） | 6.12（backports） | ⚠️ TLS 冷启动；需源码构建 NVMe 用户态 |
| Debian 13 | 13.6.0 | preseed（d-i） | 6.12（自带） | ✅ 认证冷启动 |
| Ubuntu 24.04 | 24.04 LTS | autoinstall（subiquity） | 6.8（GA） | ✅ TLS 冷启动 |
| Ubuntu 26.04 | 26.04 LTS | autoinstall（subiquity） | 7.0（自带） | ✅ 认证冷启动 |
| Fedora 44 | 44 | kickstart（Anaconda） | 6.19（自带） | ✅ TLS 冷启动 |
| AlmaLinux 10.2 | 10.2 | kickstart（Anaconda） | 6.12（`CONFIG_NVME_TCP_TLS=y`） | ✅ TLS 冷启动 |
| openSUSE Leap 16.0 | 16.0 | Agama profile | 6.12（`CONFIG_NVME_TCP_TLS=y`） | ✅ TLS 冷启动 |

Debian 12 需要源码构建的 NVMe 用户态（`ktls-utils` / `libnvme` / `nvme-cli`），
因为 bookworm 没有打包 TLS 能力工具链；代价记录在
[验收记录](archive/debian12-tls-coldboot-verification.md) 中。

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
   preseed/autoinstall/kickstart 引导参数、包管理源格式）；目标盘用 4K 逻辑块。
2. 运行无人值守安装直至自动关机。
3. 用 `test/shared/golden-vm-run.sh`（或 `golden-ubuntu-vm-run.sh`）启动定制 VM，
   拷入脚本并运行 A–F。
4. 运行隔离的宿主侧验收（见 [verification.md](verification.md)）；生产桥与端口不动。
5. 组件变更后重新内嵌，并运行 `test/test-nbft-connect-nbct.sh`。

各发行版的排障说明保留在归档中。

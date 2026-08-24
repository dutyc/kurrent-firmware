# Kurrent Firmware

[![License](https://img.shields.io/badge/License-GPL--2.0-green)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/dutyc/kurrent-firmware)](https://github.com/dutyc/kurrent-firmware)
[![Version](https://img.shields.io/github/v/tag/dutyc/kurrent-firmware)](https://github.com/dutyc/kurrent-firmware/releases)
[![Platform](https://img.shields.io/badge/Platform-x86_64%20UEFI%2FBIOS-0f766e)](docs/network-support.zh-CN.md)
[![Upstream](https://img.shields.io/badge/Upstream-iPXE%20e6e51ccb-111111)](patches/README.zh-CN.md)
[![Patches](https://img.shields.io/badge/Patches-12-7c3aed)](docs/customizations.zh-CN.md)

[English](README.md) | [中文](README.zh-CN.md)

**Kurrent Firmware** 是 **Kurrent（周流）的固件引擎**——让裸机在引导层流动起来。它是**网络引导固件构建仓库**：不包含 iPXE 源码，仅维护差异补丁与构建资产，可在任意上游基线之上重建。`research/nvme-of` 分支以 **NVMe-oF（NVMe over TCP）SAN 引导**能力为主线：自研 `nvmetcp` 驱动（含 DH-HMAC-CHAP 认证），配合带内引导凭证表（NBCT），让内核侧重连复用固件持有的密钥。

> **分支：`research/nvme-of`** — NVMe-oF SAN 引导实验分支：`nvmetcp` 驱动、DH-HMAC-CHAP 认证、NBCT 凭证表、NBFT/initramfs 消费种子模块与测试工具。探索性开发与 `main` 主干隔离，稳定后可能合入 `main`。

----

## NVMe-oF：NVMe over TCP 的 SAN 引导

上游 iPXE 没有 NVMe-oF 客户端。本分支补齐了原生实现（补丁 [0006](patches/0006-nvmeof-adaptation.patch)）：`nvmetcp`——参照 Linux 内核 NVMe-oF 实现与 TP 8000 / NVM Express Base 2.x 规范自研的 NVMe/TCP 驱动。固件直接通过网络引导磁盘，携带完整的 DH-HMAC-CHAP 认证，固件与 target 之间不需要任何额外引导软件。

### 引导链路

```
UEFI → iPXE nvmetcp → NVMe/TCP :4420 → nvmet target
  → Connect → DH-HMAC-CHAP（Negotiate → Challenge → Reply → Success1）
  → Property Set（CC.EN=1）→ Identify Ctrl/NS → I/O 队列（qid 1）
  → sanboot（GRUB 2.14）→ 内核 → initramfs NBFT/NBCT 消费
  → 携带固件密钥的 `nvme connect` 重连 → rootfs
```

### 认证

- DH-HMAC-CHAP（单向往）：Negotiate → Challenge → Reply → Success1，由 Connect 响应中的 ATR 标志 / `AUTH_REQUIRED` 状态触发
- SHA-256/384/512 哈希、DH 组 2048/3072/4096（验证中实测 ffdhe4096）；DHHC-1 密钥格式带 CRC32 校验
- 状态机竞态修复（补丁 [0007](patches/0007-nvmetcp-auth-fix.patch)）：`completed`/`rx_complete` 阶段门控 + 命令 id 匹配，拦截乱序完成事件

### 凭据接力：NBCT

补丁 [0012](patches/0012-nvmetcp-nbct-acpi-table.patch) 新增带内引导凭证 ACPI 表（NBCT）：固件按会话写入 DH-HMAC-CHAP 密钥与 host NQN；initramfs 种子模块（[initramfs-nbft/](initramfs-nbft/)）读取该表并以 `nvme connect --dhchap-secret` 重连——内核侧重连无需二次网络获取凭据。

### 身份

补丁 [0011](patches/0011-nvmetcp-hostnqn-setting.patch) 新增 `hostnqn` 设置，支持按 MAC 下发 NVMe 身份，从而在 target 侧启用严格模式认证（`allow_any_host=0`）。

### 验证状态

- DH-HMAC-CHAP 认证 → SAN 引导链路在 QEMU + Linux nvmet 下端到端闭环（2026-08-19）：[nvmeof-auth-debug-log.md](docs/nvmeof-auth-debug-log.md)
- 六环 NBFT 链路——sanboot → GRUB → 内核 → initramfs NBFT 消费 → rootfs → 登录提示符——验证通过（2026-08-21）：[nbft-boot-verification.md](docs/nbft-boot-verification.md)
- 协议设计、消息格式与线缆细节：[nvmeof-research.md](docs/nvmeof-research.md)

## 其他定制

除 NVMe-oF 外，补丁集（共十二个，固定基线 `e6e51ccb`）还包括：RTL8125（2.5G）/ RTL8126（5G）原生驱动、SNP 本地引导兜底、调试构建、设备信息采集、EFI 变量 NVS 后端（设备身份密钥 / 服务端证书指纹重启保留）、TOFU（trust-on-first-use）证书指纹链路、设备身份密钥命令（`keygen`/`pubkey`/`sign`，ECDSA P-256）。设计动机与实现详见 **[docs/customizations.zh-CN.md](./docs/customizations.zh-CN.md)**；网卡支持矩阵与实测记录见 [docs/network-support.zh-CN.md](./docs/network-support.zh-CN.md)。

## 快速开始

```bash
./build/build.sh    # 完整构建：拉取源码 -> 应用补丁 -> 构建 -> 归档
```

环境要求 Linux + `git` / `make` / `gcc`。产物输出至 `dist/`（7 种 UEFI 形态 + SHA256SUMS），完整列表与选用指南见 [docs/build-artifacts.zh-CN.md](./docs/build-artifacts.zh-CN.md)。

在 QEMU 中快速体验 NVMe-oF：

```bash
sudo bash test/nvmet-setup.sh        # NVMe/TCP target（127.0.0.1:4420；AUTH=1 启用 DH-HMAC-CHAP）
python3 test/cred-server.py 8000     # 凭据下发服务（AUTH=1 时必需）
bash test/run-qemu-auth.sh           # 一轮 QEMU 验证
```

## 文档

- [NVMe-OF 使用指南](./docs/nvmeof-usage.md) — target 配置（含 DH-HMAC-CHAP 认证）、`sanboot` 用法、QEMU 验证方法（仅中文）
- [NVMe-OF 测试流程](./docs/nvmeof-test-procedure.md) — 端到端测试流程：`test/` 脚本、GRUB 引导盘、QEMU 轮次、pcap 分析（仅中文）
- [NBFT 引导链路验证](./docs/nbft-boot-verification.md) — 六环全链路验证记录（仅中文）
- [定制详解](./docs/customizations.zh-CN.md) — 每个补丁的设计动机与实现
- [网卡支持矩阵](./docs/network-support.zh-CN.md) — 覆盖情况与实测记录
- [设备信息上报](./docs/device-info-reporting.zh-CN.md) — 采集变量清单与用法
- [构建产物](./docs/build-artifacts.zh-CN.md) — 产物列表、校验与选用
- [能力实现参考（Kurrent 集成用）](./docs/capability-reference.md) — 固件能力实现与接口契约，认证凭证注入链路详解（仅中文）
- [设备信任根能力使用文档](./docs/device-trust-usage.md) — `keygen`/`pubkey`/`sign` 命令、TOFU HTTPS 行为、NVRAM 持久化设置、签名验签契约（仅中文）
- [补丁集说明](./patches/README.zh-CN.md) — 授权边界与上游升级流程
- [RTL8126 移植审计](./docs/8126-porting-audit.md) — 双来源移植审计记录（仅中文）

## 主仓库

**[Kurrent](https://github.com/dutyc/ipxe-all-ready)**（周流）—— 把「无状态」贯彻到算力层本身的云原生平台：算力不绑定任何具体硬件，节点插电即活、可丢弃、可瞬间重建。同一理念的一体两面：Kurrent 让算力无状态，本仓库让引导固件流动。

## 社区与贡献

欢迎 Star / Watch / Issues / Pull Requests。与主仓库一致：**AI 可以写语法，架构必须由人脑理解**。

## 许可证

本仓库整体遵循 **[GPL-2.0](./LICENSE)**，与上游 iPXE（GPL-2.0-or-later / UBDL 双许可）兼容；参考第三方驱动的适配部分**仅按 GPL-2.0 授权**，不得以 UBDL 或更高版本许可再分发——详见 [patches/README.zh-CN.md](./patches/README.zh-CN.md)。

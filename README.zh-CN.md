# Kurrent Firmware

[![License](https://img.shields.io/badge/License-GPL--2.0-green)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/dutyc/kurrent-firmware)](https://github.com/dutyc/kurrent-firmware)
[![Version](https://img.shields.io/github/v/tag/dutyc/kurrent-firmware)](https://github.com/dutyc/kurrent-firmware/releases)
[![Platform](https://img.shields.io/badge/Platform-x86_64%20UEFI%2FBIOS-0f766e)](docs/network-support.zh-CN.md)
[![Upstream](https://img.shields.io/badge/Upstream-iPXE%20e6e51ccb-111111)](patches/README.zh-CN.md)
[![Patches](https://img.shields.io/badge/Patches-12-7c3aed)](docs/customizations.zh-CN.md)

[English](README.md) | [中文](README.zh-CN.md)

**Kurrent Firmware** 是 **Kurrent（周流）的固件引擎**——让裸机在引导层流动起来。不包含 iPXE 源码，仅维护差异补丁与构建资产，可在任意上游基线之上重建；核心是 **NVMe-oF（NVMe over TCP）SAN 引导**——自研 `nvmetcp` 驱动（含 DH-HMAC-CHAP 认证）补齐上游缺口，配合带内引导凭证表（NBCT）让内核侧重连复用固件持有的密钥，固件与 target 之间不需要任何额外引导软件。

## 引导链路

```
UEFI → iPXE nvmetcp（TLS 1.3 PSK）→ NVMe/TCP :4421 → nvmet target
  → Connect → DH-HMAC-CHAP（Negotiate → Challenge → Reply → Success1）
  → Property Set（CC.EN=1）→ Identify Ctrl/NS → I/O 队列（qid 1）
  → sanboot（GRUB 2.14）→ 内核 → initramfs NBFT/NBCT 消费
  → 携带固件密钥的 `nvme connect --tls` 重连 → rootfs
```

协议设计、消息格式与线缆细节见 [nvmeof-research.md](docs/nvmeof-research.md)。

## 核心能力

- **NVMe-oF SAN 引导**——原生 `nvmetcp` 驱动（TP 8000 / NVM Express Base 2.x），UEFI 固件直连 NVMe/TCP target 引导磁盘。
- **DH-HMAC-CHAP 认证**——单向往认证（SHA-256/384/512、DH 组至 ffdhe4096），DHHC-1 密钥格式带 CRC32 校验；按 MAC 下发 `hostnqn`，target 可启用严格模式（`allow_any_host=0`）。
- **凭据接力（NBCT）**——固件按会话写入密钥与 host NQN；initramfs 种子模块（[initramfs-nbft/](initramfs-nbft/)）读表并以 `nvme connect --dhchap-secret` 重连，内核侧无需二次获取凭据。
- **母盘定制矩阵**——Debian 12/13、Ubuntu 24.04/26.04、Fedora 44 的 SAN 母盘均完成冷启动验收：[发行版矩阵](docs/golden-image-matrix.md)。
- **网卡与固件定制**——RTL8125/RTL8126 原生驱动、SNP 本地引导兜底、设备身份密钥与 TOFU 指纹链路；共十二个补丁：[定制详解](docs/customizations.zh-CN.md)、[网卡支持矩阵](docs/network-support.zh-CN.md)。

## 快速开始

```bash
./build/build.sh    # 完整构建：拉取源码 -> 应用补丁 -> 构建 -> 归档
```

环境要求 Linux + `git` / `make` / `gcc`；产物输出至 `dist/`（7 种 UEFI 形态 + SHA256SUMS），清单与选用见[构建产物](docs/build-artifacts.zh-CN.md)。

## 文档

完整文档见 [`docs/`](./docs/) 目录，常用入口：

- [NVMe-OF 使用指南](docs/nvmeof-usage.md)——target 配置（含 DH-HMAC-CHAP）、`sanboot` 用法与 QEMU 验证
- [母盘定制发行版矩阵](docs/golden-image-matrix.md)——各发行版定制脚本、差异对照与验收状态
- [能力实现参考（Kurrent 集成用）](docs/capability-reference.md)——固件能力与接口契约、凭据注入链路
- [补丁集说明](patches/README.zh-CN.md)——授权边界与上游升级流程

## 主仓库

**[Kurrent](https://github.com/dutyc/ipxe-all-ready)**（周流）—— 把「无状态」贯彻到算力层本身的云原生平台：算力不绑定任何具体硬件，节点插电即活、可丢弃、可瞬间重建。同一理念的一体两面：Kurrent 让算力无状态，本仓库让引导固件流动。

## 社区与贡献

欢迎 Star / Watch / Issues / Pull Requests。与主仓库一致：**AI 可以写语法，架构必须由人脑理解**。

## 许可证

本仓库整体遵循 **[GPL-2.0](./LICENSE)**，与上游 iPXE（GPL-2.0-or-later / UBDL 双许可）兼容；参考第三方驱动的适配部分**仅按 GPL-2.0 授权**，不得以 UBDL 或更高版本许可再分发——详见 [patches/README.zh-CN.md](./patches/README.zh-CN.md)。

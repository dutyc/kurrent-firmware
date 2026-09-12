# 网卡支持矩阵

[English](network-support.md) | [中文](network-support.zh-CN.md)

本仓库固件对网卡的支持情况（上游基线 `e6e51ccb` + 定制补丁），基于源码驱动设备表（`src/drivers/net/`）与本项目实测记录整理。上游升级或新增补丁后可能变化。

## 适配方向

本仓库聚焦 **2.5G/5G 及以上速率高性能网卡** 的驱动移植与适配（如 RTL8125 / RTL8126 系列）；普通千兆/百兆网卡仅维持上游基线既有支持，**不再进行新的适配与更新**。

状态图例：

- **覆盖良好** —— 驱动成熟或实测通过，可放心使用
- **有条件** —— 驱动存在但有已知问题或限制
- **协议层支持** —— 无 native 驱动；通过网卡自带 UEFI SNP / BIOS UNDI 引导 ROM 运行（snponly.efi / undionly.kpxe）；附带下方“有条件”中的 SNP 注意事项
- **不支持** —— 基线无驱动（含本项目补丁范围）

## 覆盖良好

| 网卡 | 驱动 | 说明 |
|---|---|---|
| Intel e1000e 全系（82540 → I219 最新步进） | intel.c | **物理机实测通过**（direct-uefi ipxe.efi） |
| Intel I210 / I211 / I350 / 82576 | intel.c | 含服务器常见 I350 |
| **Intel I225 / I226**（2.5G，主流主板） | intel.c | 全步进覆盖：I225（0x15f2/15f3/0d9f/5502）、I226（0x125b/125c/125d） |
| Intel 82599 / X540 / X550 / X553 / X552（10G） | intelx.c | 含 X553-AT（10GBASE-T） |
| Intel X710 / XL710（10G / 40G） | intelxl.c | 服务器常见 |
| Intel E810 / E823（25G / 100G） | ice.c | 新驱动 |
| Realtek RTL8136 / 8139 / 8129 / 8167 / 8168 / 8169 | realtek.c | 基线原生 |
| **Realtek RTL8125 全系**（2.5G） | realtek.c（0001 补丁） | **物理机实测 DHCP 通过**；原生驱动适配 |
| **Realtek RTL8126**（5G，2024 新卡） | realtek.c（0001 补丁） | **编译验证通过**（含 GPHY OCP/CSI 机制、PHY 静态配置表 ×3）；待硬件实测 |
| Marvell/Aquantia AQC100 / 107 / 108 / 109 / 111 / 112 / 113 / 114（10G / 5G / 2.5G） | aqc1xx.c | 设备表全系覆盖（含 AQC113，Atlantic 2）；高端主板 / 工控常见 |
| Broadcom BCM57xx 千兆（tg3，82 设备） | tg3 | 覆盖广 |
| Broadcom BNX2（BCM5706/5708 等） | bnx2 | 1G/10G 旧系 |
| Broadcom NetXtreme-E（BCM957xxx） | bnxt | 服务器新系 |
| 虚拟化：virtio / vmxnet3 / ENA(AWS) / GVE(GCP) / netvsc(Hyper-V) | — | 云原生场景全覆盖 |
| USB：AX88179（axge）、LAN7800（lan78xx）、SMSC95xx/75xx、DM96xx、CDC ECM/NCM | — | USB 网卡仅此几类 |

## 协议层支持（无 native 驱动）

部分服务器级网卡出厂自带引导 ROM（UEFI SNP / BIOS UNDI），无需移植驱动——协议层固件（snponly.efi / undionly.kpxe）直接运行在网卡自带 PXE 栈之上，获得完整 iPXE 能力。当 native 驱动移植成本（如 mlx5 的固件命令接口架构）与收益不成比例时，有意采用协议层方案。

| 网卡 | 路径 | 备注 |
|---|---|---|
| **Mellanox ConnectX-4 / 5 / 6 / 7**（25G / 40G / 100G，服务器） | snponly.efi（UEFI）/ undionly.kpxe（BIOS） | 零适配；附带下方“有条件”中的 SNP 注意事项（iSCSI 挂起风险） |
| Broadcom bnx2x 系（BCM57710/57711/57712/57800/57810/57840，10G，NetXtreme II） | snponly.efi（UEFI）/ undionly.kpxe（BIOS） | 服务器卡自带 Broadcom 官方引导 ROM；零适配；附带下方“有条件”中的 SNP 注意事项（iSCSI 挂起风险） |

## 不支持（重点风险）

| 网卡 | 场景 | 备注 |
|---|---|---|
| **Realtek USB RTL8152 / 8153 / 8156** | 笔记本 USB-C 转 RJ45（最常见） | iPXE 无此驱动 |
| 现代 WiFi 全系（Intel AX、Realtek 88 系列） | 笔记本 | 仅古董 prism2 / rtl818x |

## 有条件（已知问题）

- **Realtek RTL8168 部分版本**：native 驱动初始化挂起（本项目实证，研究终止）→ 需走 SNP 兜底，见 [8168-research-log.md](8168-research-log.md)
- **SNP 驱动 iSCSI 挂起缺陷**（本项目实证）：影响**所有没有 native 驱动、只能走 UEFI 网卡驱动**的网卡——即走 SNP 引导的网卡（“不支持”与“协议层支持”两节所列）同样有此风险
- **Intel I219 系列**：带 `INTEL_PBSIZE_RST` / `NO_PHY_RST` 特殊处理（历史 bug 修复，实际影响小）
- **Marvell/Aquantia AQC 系列**：Marvell 官方轻量实现（约为 Linux atlantic 的 1/6）；链路协商依赖硬件自协商（无速率管理）；AQC113 动态固件加载未实现（固件空白时返回 `-ENOTSUP`）；本项目无实测记录
- **82599 / X550（SFP+）**：兼容性依赖光模块质量

## 实测记录

| 日期 | 网卡 | 固件 | 结果 |
|---|---|---|---|
| 2026-08-07 | Realtek RTL8125 | SNP 固件 | iSCSI 挂载挂起（native 驱动接管） |
| 2026-08-09 | Realtek RTL8168 | native 驱动 | 部分版本初始化挂起（SNP 兜底） |
| 2026-08-10 | Intel e1000（82540EM 等） | direct-uefi ipxe.efi | 通过 |
| 2026-08-11 | Realtek RTL8125 | 定制固件（0001 补丁） | 正常 |

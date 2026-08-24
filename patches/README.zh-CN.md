# 补丁集说明

[English](README.md) | [中文](README.zh-CN.md)

所有补丁基于**同一上游基线**生成；应用顺序 = 文件名顺序。

## 基线

- 上游仓库：`https://github.com/ipxe/ipxe.git`（国内可换 `https://gitee.com/mirrors/ipxe.git`）
- 基线提交：`e6e51ccbf17ff40a899c8859fb4e95abd5cfcd57`（master）
- 重新生成补丁时，在构建缓存工作树（`.cache/ipxe-upstream`，已含补丁与修改）中：

  ```bash
  git -C .cache/ipxe-upstream diff > patches/NNNN-xxx.patch
  ```

## 补丁清单

| 补丁 | 修改文件 | 内容 |
|---|---|---|
| `0001-realtek-8125-adaptation.patch` | `src/drivers/net/realtek.c`、`realtek.h` | RTL8125 全系适配（XID 0x688 版本表、EPHY 初始化表、32 位中断寄存器、FETCH/PAUSE_SLOT、BAR 0x4808、TPPOLL_8125） |
| `0002-makefile-ipxe-debug.patch` | `src/Makefile` | 新增 `DRIVERS_ipxe-debug` 定义（debug 目标继承全驱动集，修复 `obj_ipxe_debug` 链接失败） |
| `0003-snponly-local-boot.patch` | `src/drivers/net/efi/snponly.c` | snponly 本地引导支持：链加载定位失败时（本地 UEFI 引导）回退接管全部 SNP/NII/MNP 设备，PXE 链加载场景行为不变 |
| `0004-realtek-8126-adaptation.patch` | `src/drivers/net/realtek.c`、`realtek.h` | RTL8126 5GbE 适配（ICVerID 检测与 PHY 配置方法分派、GPHY OCP/CSI 接口、PHY 静态配置表 ×3、ZRXDC/ASPM 配置） |
| `0005-device-info-collection.patch` | `src/include/ipxe/smbios.h`、`src/interface/smbios/smbios_settings.c`、`src/drivers/bus/pci.c` | 设备信息采集：SMBIOS type 17 内存设置（`mem-total` 全插槽聚合、`mem-type` / `mem-speed` 取首槽，自定义 fetch）+ PCI `driver_name` 填充，使 `${net0/chip}` 输出设备表名（如 `RTL8125`） |
| `0006-nvmeof-adaptation.patch` | `src/config/config.c`、`src/config/general.h`、`src/include/ipxe/errfile.h`、`src/include/ipxe/nvmetcp.h`、`src/net/tcp/nvmetcp.c`、`src/net/tcp/nvmetcp_auth.c`、`src/tests/nvmetcp_test.c`、`src/tests/tests.c` | NVMe-oF（NVMe over TCP）SAN 协议支持：新增 nvmetcp 驱动（ICReq/ICResp 参数协商、Property Set（CC 寄存器）、Connect/Identify、块读写、R2T 流控、DH-HMAC-CHAP 认证、EFI 设备路径描述与 BlockIo 钩接）+ `SANBOOT_PROTO_NVME_TCP` 配置与单元测试 |
| `0007-nvmetcp-auth-fix.patch` | `src/include/ipxe/nvmetcp.h`、`src/net/tcp/nvmetcp.c`、`src/net/tcp/nvmetcp_auth.c`、`src/tests/nvmetcp_test.c` | NVMe/TCP 认证与状态机修复：瞬态 `-EAGAIN` 处理（等待窗口恢复而非关闭会话）、AuthReceive 发送幂等与 step 统一推进（消除双重发送）、认证阶段完成以 `completed`/`rx_complete` 双标志 + 命令 id 匹配（`rx_cid`）门控（确保 Property Set 不被跳过，修复 Identify 被 `0x8018` 拒绝）、Identify Namespace 的 LBAF 偏移修正（64→128）、`NVME_SC_AUTH_REQUIRED` 常量、认证状态机单元测试（阶段完成门控、AuthReceive 命令 id 匹配、START 步守卫）。详见 `../docs/nvmeof-auth-debug-log.md` |
| `0008-efi-nvs-backend.patch` | `src/config/config_efi.c`、`src/interface/efi/efi_nvs.c`、`src/include/ipxe/dhcp.h`、`src/include/ipxe/errfile.h` | EFI 变量 NVS 后端：新增 `efi_nvs.c` 设置后端，持久化于 EFI NVRAM 变量（项目命名空间 GUID）——`device-key`（0x5e）与 `server-fingerprint`（0x5f）设置重启保留 |
| `0009-tofu-fingerprint.patch` | `src/include/ipxe/tofu.h`、`src/net/tofu.c`、`src/net/tls.c`、`src/include/ipxe/errfile.h` | TOFU 指纹链路：首次 TLS 握手时接受未受信任的叶子证书并将其 SHA-256 指纹存储（镜像至 `trust` 设置）；一旦存在指纹，后续任何证书校验失败均致命 |
| `0010-devicekey-commands.patch` | `src/hci/commands/devicekey_cmd.c`、`src/config/general.h`、`src/config/config.c`、`src/include/ipxe/dhcp.h`、`src/include/ipxe/errfile.h` | 设备身份密钥命令（`keygen`/`pubkey`/`sign`）：ECDSA P-256 密钥生成（DRBG 以 EFI RNG 为熵源）、公钥推导（未压缩点，130 hex）、SHA-256 → ECDSA 签名并以 base64(DER) 输出；`DEVICEKEY_CMD` 配置项 |
| `0011-nvmetcp-hostnqn-setting.patch` | `src/net/tcp/nvmetcp.c` | NVMe/TCP host NQN 设置：注册 `hostnqn` 设置项，覆盖 `nvmetcp_set_host_nqn()` 中 UUID 派生的默认值，使引导服务器可按 MAC 注入与 nvmet `hosts/` 注册匹配的身份（严格模式认证）；未设置该选项的普通 `nvme://` URI 保持原回退行为 |
| `0012-nvmetcp-nbct-acpi-table.patch` | `src/drivers/block/nbct.c`（新）、`src/include/ipxe/nbct.h`（新）、`src/include/ipxe/errfile.h`、`src/include/ipxe/nvmetcp.h`、`src/net/tcp/nvmetcp.c` | NVMe 引导凭证表（NBCT）：sanboot 时按 iBFT 的 `acpi_model` 注册模式安装自定义 ACPI 表，每个已认证 NVMe/TCP 会话一条定长记录（传输地址、子系统 NQN、host NQN、DH-HMAC-CHAP 密钥）；initramfs 侧 `nbft-connect`（见 `../initramfs-nbft/`）消费该表，以 `--dhchap-secret`/`--hostnqn` 逐条重连，避免二次网络获取凭证 |

> RTL8168 相关研究已于 2026-08 终止，补丁不含 8168 过滤或修复代码（见 `../docs/8168-research-log.md`）。

## 授权说明

- 补丁修改的上游文件（`realtek.c`、`snponly.c`、`Makefile`、`smbios.h`、`smbios_settings.c`、`pci.c`）继承 iPXE 的 GPL-2.0-or-later / UBDL 许可；
- `0001` 中 RTL8125 适配部分（XID 版本表、EPHY 初始化、电源管理等）参考 Linux 内核 r8169 驱动（`drivers/net/ethernet/realtek/r8169_main.c`，GPL-2.0-only），该部分**仅按 GPL-2.0 授权**，不得以 UBDL 或更高版本许可再分发；
- `0004` 中 RTL8126 适配部分（PHY 静态配置表、GPHY OCP/CSI 接口、ZRXDC/ASPM 配置等）参考 Realtek r8126 驱动（`r8126_n.c`，GPL-2.0-only，Copyright 2025 Realtek Semiconductor Corp.）与 Linux 内核 r8169 驱动（`drivers/net/ethernet/realtek/r8169_main.c`，GPL-2.0-only），该部分**仅按 GPL-2.0 授权**，不得以 UBDL 或更高版本许可再分发；
- `0006`/`0007` 中的 NVMe/TCP 驱动文件（`nvmetcp.c`、`nvmetcp_auth.c`、`nvmetcp.h`、`nvmetcp_test.c`）为 kurrent-firmware 自研实现，文件头 `FILE_LICENCE ( GPL2_ONLY )`，**仅按 GPL-2.0 授权**，不得以 UBDL 许可再分发；
- `0008`/`0009`/`0010` 中的设备身份新文件（`efi_nvs.c`、`tofu.c`、`tofu.h`、`devicekey_cmd.c`）为 kurrent-firmware 自研实现，文件头 `FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )`，与上游 iPXE 双许可一致；
- `0012` 中的 NBCT 新文件（`nbct.c`、`nbct.h`）为 kurrent-firmware 自研实现，文件头 `FILE_LICENCE ( BSD2 )`（类内核许可，对齐上游 iPXE `ibft.c` 的 ACPI 表先例）；
- 本仓库整体遵循 GPL-2.0（见 `../LICENSE`），补丁头部均含 SPDX 声明。

## 升级上游基线流程

上游升级后补丁可能无法应用，按以下流程迁移：

1. 更新基线：

   ```bash
   git fetch https://github.com/ipxe/ipxe.git master
   git log FETCH_HEAD --oneline | head   # 确认新基线
   ```

2. 在构建缓存工作树（`.cache/ipxe-upstream`）中**在新基线上重新生成补丁**：

   ```bash
   # 在 .cache/ipxe-upstream 中：先检出新基线，再手动复现修改（或对照旧补丁），最后：
   git diff > patches/0001-realtek-8125-adaptation.patch
   ```

   注意：**先应用旧补丁到新基线 → 手动解决冲突 → 再重新生成**，比手工重写更可靠；
   重新生成的补丁会覆盖头部许可注释，须从旧补丁头部复制保留（见上方"授权说明"）。
3. 更新 `build/build.sh` 中的 `UPSTREAM_COMMIT` 与本文档基线记录。

4. 运行 `./build/build.sh` 验证补丁可干净应用、产物功能正常（重点回归：8125/8126 引导）。

## 注意事项

- `embed/auto.ipxe` 属于**配置资产**（非源码补丁），改动无需重新生成补丁，直接修改 `../embed/auto.ipxe` 后重新构建即可
- 补丁需保持 `git apply --check` 通过；补丁与基线提交强绑定，`UPSTREAM_COMMIT` 变更前务必走升级流程

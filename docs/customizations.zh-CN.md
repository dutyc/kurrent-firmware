# 定制内容

[English](customizations.md) | [中文](customizations.zh-CN.md)

本仓库相对上游 iPXE 基线（默认 `e6e51ccb`）的全部定制 = **十二个补丁** + **构建级 EMBED 定制**（`embed/auto.ipxe`，经 `EMBED=` 编译进固件，非补丁）：

| # | 补丁 | 内容 |
|---|---|---|
| 0001 | `0001-realtek-8125-adaptation.patch` | RTL8125（2.5G）全系 native 驱动适配 |
| 0002 | `0002-makefile-ipxe-debug.patch` | debug 构建修复 |
| 0003 | `0003-snponly-local-boot.patch` | snponly 本地引导支持 |
| 0004 | `0004-realtek-8126-adaptation.patch` | RTL8126（5G）native 驱动适配 |
| 0005 | `0005-device-info-collection.patch` | 设备信息采集：SMBIOS type 17 内存设置（`mem-total` / `mem-type` / `mem-speed`）+ PCI 设备表名经 `${net0/chip}` 暴露 |
| 0006 | `0006-nvmeof-adaptation.patch` | NVMe-oF（NVMe over TCP）SAN 协议支持 |
| 0007 | `0007-nvmetcp-auth-fix.patch` | NVMe/TCP 认证与状态机修复 |
| 0008 | `0008-efi-nvs-backend.patch` | EFI 变量 NVS 后端（`device-key` / `server-fingerprint` 重启保留） |
| 0009 | `0009-tofu-fingerprint.patch` | TOFU 指纹链路（首次接触 TLS 放行、指纹存储） |
| 0010 | `0010-devicekey-commands.patch` | 设备身份密钥命令（`keygen` / `pubkey` / `sign`） |
| 0011 | `0011-nvmetcp-hostnqn-setting.patch` | NVMe/TCP host NQN 设置（按 MAC 注入身份，严格模式认证） |
| 0012 | `0012-nvmetcp-nbct-acpi-table.patch` | NVMe 引导凭证表（NBCT：DH-HMAC-CHAP 密钥 + host NQN 经 ACPI 表交接内核侧） |

## 设计动机

很多主板没有 PXE 网络启动选项，或设置繁琐（BIOS 无 Network Boot 入口、默认关闭 UEFI 网络栈、需逐台进 BIOS 配置且 Secure Boot 限制多）。与其依赖主板 PXE，不如提供可经本地介质（USB / 磁盘 / GRUB2 链加载）引导、启动即自动进入网络引导流程的固件——`embed/auto.ipxe`（EMBED 定制）与 `0003`（SNP 固件本地引导适配）即为此而作。

对这些定制的维护采用补丁机制而非直接 fork：fork 分支在上游升级时需要持续合并，成本太高。本仓库改为：

```
上游 ipxe 源码（固定基线 commit）
    +
patches/（差异文件，唯一事实来源）
    +
embed/（脚本资产）
    ↓ build/build.sh
dist/（七个固件产物 + SHA256SUMS）
```

补丁全部基于**固定上游基线**生成，升级上游时重新生成补丁即可（见 [patches/README.zh-CN.md](../patches/README.zh-CN.md)）。

## 定制详解

### 1. RTL8125 全系适配（`0001`）

- **背景**：RTL8125（2.5G）网卡必须由 iPXE native 驱动接管——固件 SNP 驱动在 iSCSI 挂载场景存在挂起缺陷，无法用于无盘引导；而上游 iPXE 对部分 8125 版本（XID 0x688 系列）支持不完整。
- **修改**：`src/drivers/net/realtek.c`、`realtek.h`
  - XID 0x688 版本表与设备识别
  - EPHY 初始化表（2.5G PHY 配置）
  - 32 位中断状态寄存器
  - FETCH/PAUSE_SLOT 配置
  - BAR 0x4808（2.5G 专用寄存器窗口）
  - TPPOLL_8125 轮询方式
- **许可**：8125 适配部分参考 Linux 内核 r8169 驱动（GPL-2.0-only），仅按 GPL-2.0 授权，不得以 UBDL 再分发（见 `patches/0001` 头部声明）。

### 2. debug 构建修复（`0002`）

- **背景**：`ipxe-debug.efi` 目标未定义驱动集，构建产物为空壳（无任何网卡驱动），无法用于故障定位。
- **修改**：`src/Makefile` 新增 `DRIVERS_ipxe-debug += $(DRIVERS_ipxe)`，debug 目标继承全驱动集。

### 3. snponly 本地引导支持（`0003`）

- **背景**：官方 `snponly.efi` 仅支持固件 PXE 链加载场景（只接管加载 iPXE 的那个设备）；从本地 UEFI（U 盘/磁盘）引导时找不到任何网卡，直接进入 shell。这是"主板无 PXE 网络启动选项"场景的配套适配——本地介质引导时同样需要网络接管能力。
- **修改**：`src/drivers/net/efi/snponly.c`——链加载定位失败时回退接管全部 SNP/NII/MNP 设备；PXE 链加载场景行为不变。
- **作用**：native 驱动不可用（如特定主板 RTL8168 初始化挂起）的机器，本地引导也有 SNP 兜底路径。

### 4. RTL8126 5GbE 适配（`0004`）

- **背景**：RTL8126（5G）为 2024 年新卡，上游 iPXE 基线无 0x8126 设备项；其 GPHY 需按 ICVerID 分三种 PHY 配置方法（静态寄存器表）初始化，且部分 PCIe 配置（ZRXDC 超时上报、ASPM 入口延迟）需经 CSI 机制访问扩展配置空间，基线驱动均不具备。
- **修改**：`src/drivers/net/realtek.c`、`realtek.h`
  - `0x8126` 设备项与 `realtek_detect_8126`（TxConfig 0x64800000 族检测 + ICVerID → mcfg 1/2/3 分派）
  - GPHY OCP 接口函数（`realtek_gphy_ocp_read/write/modify`，重构 0001 内联 MII 访问并复用）
  - CSI 扩展配置空间接口（`realtek_csi_read/write/modify`，Linux `rtl_csi_*` 同机制）
  - PHY 静态配置表 ×3（`realtek_8126a_1/2/3_phy`，共 367 项，源自官方 r8126 驱动；剔除 MCU 微码段；区分直接写与读改写语义，分别对应官方 `rtl8126_mdio_direct_write_phy_ocp` 与 `rtl8126_clear_and_set_eth_phy_ocp_bit`）与 `realtek_hw_phy_config_8126`
  - `realtek_hw_start_8126`：ZRXDC 关闭 + ASPM 默认入口延迟（CSI 路径）+ 8125 公共初始化 + PHY 配置
  - 挂载：`realtek_detect` / `realtek_open` / `realtek_probe` 按 `mac_ver == 70` 分派
- **验证**：完整构建 10 产物全部通过（含 `DEBUG=realtek:3` debug 目标）；待物理机实测。
- **审计**：双来源 PHY 表对照审计与 PHY MCU 微码轻量方案（版本检查）详见 [8126-porting-audit.md](8126-porting-audit.md)。
- **许可**：8126 适配部分参考 Realtek r8126 驱动（GPL-2.0-only，Copyright 2025 Realtek Semiconductor Corp.）与 Linux 内核 r8169（GPL-2.0-only），仅按 GPL-2.0 授权，不得以 UBDL 再分发（见 `patches/0004` 头部声明）。

### 5. 设备信息采集（`0005`）

- **背景**：固件侧设备信息采集（身份 / CPU / 内存 / 网卡）供 HTTP 上报。身份（SMBIOS type 1-3）与 CPU（CPUID）设置官方已有，缺口有二：SMBIOS type 17（内存设备，每插槽一条）无具名设置；PCI 网卡从不填充 `driver_name`，导致 `${net0/chip}` 在 PCI 上不可用。
- **修改**：`src/include/ipxe/smbios.h`、`src/interface/smbios/smbios_settings.c`、`src/drivers/bus/pci.c`
  - `struct smbios_memory_device`（type 17 布局经 dmidecode 三个版本交叉验证：Memory Type `0x12`、Speed `0x15`、Extended Size `0x1C`）+ `SMBIOS_TYPE_MEMORY_DEVICE 17`
  - `${mem-total}`（uint32 MB，全插槽聚合：`0xFFFF` 跳过、`0x7FFF` 回退 Extended Size、bit15=GB）、`${mem-type}`（首槽，映射为 `DDR5` 等字符串）、`${mem-speed}`（首槽，MT/s）——按名分派的自定义 fetch，复用现有 SMBIOS 设置 scope
  - `pci_probe` 现从匹配的设备表项填充 `driver_name`，使 `${net0/chip}`（如 `RTL8125`）对所有 PCI 网卡生效
- **用法**：设置项清单与上报 URL 模板见 [device-info-reporting.zh-CN.md](device-info-reporting.zh-CN.md)。
- **验证**：完整构建 10 产物全部通过；设置已编入（字符串验证）；真机行为待实测（空格 / 特殊字符的 URL 编码）。

### 6. NVMe-oF（NVMe over TCP）SAN 支持（`0006`）

- **背景**：上游 iPXE 无 NVMe-oF 传输支持；从 NVMe/TCP target（如 Linux `nvmet`）SAN 引导需要完整协议驱动 + `SANBOOT_PROTO_NVME_TCP` 配置项。
- **修改**：`src/config/config.c`、`src/config/general.h`（`SANBOOT_PROTO_NVME_TCP`）、`src/include/ipxe/errfile.h`、`src/include/ipxe/nvmetcp.h`、`src/net/tcp/nvmetcp.c`、`src/net/tcp/nvmetcp_auth.c`、`src/tests/nvmetcp_test.c`、`src/tests/tests.c`
  - 8 阶段状态机：ICReq/ICResp 参数协商 → Connect（Admin）→ Property Set（CC.EN=1）→ Identify（控制器/命名空间）→ Connect（I/O）→ 块读写（R2T 流控）
  - DH-HMAC-CHAP 认证（AuthSend/AuthReceive，DH 群 0/2048/3072/4096）
  - EFI 设备路径描述与 BlockIo 钩接（供 `sanboot`）；单元测试（结构布局 + Identify NS 解析）
- **用法**：端到端指南（nvmet 服务端配置含认证、`sanboot` 语法、QEMU 验证）见 [nvmeof-usage.md](nvmeof-usage.md)。
- **验证**：QEMU/OVMF + Ubuntu 26.04 内核 7.0 nvmet target，GRUB 2.14 SAN 引导链路通过（见 [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md)）。
- **授权**：kurrent-firmware 自研实现，`FILE_LICENCE ( GPL2_ONLY )`——仅按 GPL-2.0 授权，不得以 UBDL 再分发。

### 7. NVMe/TCP 认证与状态机修复（`0007`）

- **背景**：针对 nvmet 端到端验证 0006 认证路径时发现三个 bug：瞬态 `-EAGAIN` 误杀会话（应等待 TCP 窗口）、AuthReceive 可能被重复发送、认证完成竞态（phase 在最终 AuthReceive 完成前切换，导致 Property Set 被跳过、Identify 被拒）。
- **修改**：`src/include/ipxe/nvmetcp.h`、`src/net/tcp/nvmetcp.c`、`src/net/tcp/nvmetcp_auth.c`、`src/tests/nvmetcp_test.c`
  - 瞬态 `-EAGAIN` 处理（挂起进程、窗口恢复后继续）与 AuthReceive 发送幂等、step 统一推进
  - 认证阶段完成以 `completed`/`rx_complete` 双标志 + 命令 id 匹配（`rx_cid`）门控，确保 Property Set 不被跳过（修复 Identify 被 `0x8018` 拒绝）；Connect 响应无 ATR 位时的 `NVME_SC_AUTH_REQUIRED` 状态码触发路径
  - Identify NS 的 LBAF 偏移修正（64→128）
- **排障日志**：完整调查时间线与 wire 层证据见 [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md)。
- **验证**：全链路复跑：`sending Property Set (CC)` 出现、wire 层全部命令 `status=0x0000`、`0x8018` 出现 0 次、GRUB 2.14 SAN 引导成功。

### 8. EFI 变量 NVS 后端（`0008`）

- **背景**：设备信任根体系需要在非易失存储中保存设备身份密钥与服务端证书指纹；iPXE 默认 NVS 后端（PCI option ROM、SMBIOS）在 EFI 引导路径上缺失或只读，需要基于 EFI NVRAM 变量的专用后端。
- **修改**：`src/interface/efi/efi_nvs.c`、`src/config/config_efi.c`、`src/include/ipxe/dhcp.h`（`DHCP_EB_DEVICE_KEY` 0x5e、`DHCP_EB_SERVER_FINGERPRINT` 0x5f）、`src/include/ipxe/errfile.h`
  - 新增 `efi_nvs.c` 设置后端：单个 EFI NVRAM 变量（项目命名空间 GUID）承载整个 options 块；store/load/delete 钩子接入 EFI 设置机制
  - `device-key` 与 `server-fingerprint` 因此重启保留
- **验证**：QEMU/OVMF 两轮测试——第 2 轮（保留 NVRAM）密钥仍存在且无需重新生成；`keygen` 拒绝覆盖。

### 9. TOFU 指纹链路（`0009`）

- **背景**：信任根体系需在首次接触时容忍自签或未受信任的 HTTPS 服务器（注册窗口），此后固定该服务器；上游 iPXE 无 trust-on-first-use 机制。
- **修改**：`src/net/tofu.c`、`src/include/ipxe/tofu.h`、`src/net/tls.c`、`src/include/ipxe/errfile.h`
  - `tofu_fingerprint_present()` / `tofu_store()`：TLS 叶子证书的 SHA-256 指纹，镜像至 `trust` 设置
  - `tls_validator_done()`：校验失败时，若尚未存有指纹则接受握手并记录指纹（TOFU）；一旦存在指纹，后续任何失败均致命
- **验证**：在 0008 基础上补丁双向应用通过。

### 10. 设备身份密钥命令（`0010`）

- **背景**：信任根体系要求设备侧完成 ECDSA P-256 密钥生成、公钥导出与签名——私钥永不出设备。
- **修改**：`src/hci/commands/devicekey_cmd.c`、`src/config/general.h`（`DEVICEKEY_CMD`）、`src/config/config.c`（`REQUIRE_OBJECT ( devicekey_cmd )`）、`src/include/ipxe/dhcp.h`（`DHCP_EB_PUBKEY` 0x60、`DHCP_EB_SIG` 0x61）、`src/include/ipxe/errfile.h`
  - `keygen`：DRBG（以 EFI RNG 熵源为种子）生成 32 字节 P-256 私钥并存入 `device-key`；拒绝覆盖已存在的密钥
  - `pubkey`：经 P-256 曲线乘法推导未压缩点（`0x04‖X‖Y`，130 hex）
  - `sign`：数据（参数拼接）SHA-256 摘要 → ECDSA P-256 → base64(DER) 签名，同时存入 `sig` 设置供脚本使用
- **验证**：QEMU/OVMF 两轮——第 1 轮（清空 NVRAM）：keygen/pubkey/sign 全部成功；主机侧（OpenSSL/python）对打印的公钥与签名独立验签通过（PREHASHED 与 REHASH）；第 2 轮（保留 NVRAM）：keygen 拒绝覆盖，pubkey/sign 输出与第 1 轮完全一致（持久化验证）。
- **授权**：kurrent-firmware 自研实现，`FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )`。

### 11. NVMe/TCP host NQN 设置（`0011`）

- **背景**：严格模式 DH-HMAC-CHAP 认证要求 host NQN 与 nvmet `hosts/` 注册匹配；引导服务器无法预测任意客户端的 UUID 派生默认值。
- **修改**：`src/net/tcp/nvmetcp.c`——注册 `hostnqn` 设置项，覆盖 `nvmetcp_set_host_nqn()` 中 UUID 派生的默认值；未设置该选项的普通 `nvme://` URI 保持原回退行为（`nqn.2014-08.org.ipxe:<uuid>`）。
- **验证**：引导服务器按 MAC 经凭证端点注入 host NQN；nvmet `hosts/` 严格模式接受（`test/nvmet-setup.sh` 的 `AUTH=1`）。

### 12. NVMe 引导凭证表（`0012`）

- **背景**：认证引导下，内核侧重连不得第二次经网络获取凭证——固件已持有每会话的 DH-HMAC-CHAP 密钥与 host NQN，应以内核可读的方式带内接力。
- **修改**：`src/drivers/block/nbct.c`（新）、`src/include/ipxe/nbct.h`（新）、`src/include/ipxe/errfile.h`、`src/include/ipxe/nvmetcp.h`、`src/net/tcp/nvmetcp.c`
  - 按 iBFT 的 `acpi_model` 注册模式安装（`nbct_model`）；每个已认证 NVMe/TCP 会话暴露 `acpi_describe` 接口操作
  - sanboot 描述时（`efi_block_describe` → `acpi_install`）安装签名为 `NBCT` 的自定义 ACPI 表：36 字节 ACPI 头 + 记录数 + N 条定长 1024 字节记录（traddr / trsvcid / nqn / hostnqn / secret）
  - 表仅驻留内存（不入 NVRAM），随引导会话消亡
- **消费侧**：`initramfs-nbft/nbft-connect --connect` 检测 `/sys/firmware/acpi/tables/NBCT*`，以 `--dhchap-secret` / `--hostnqn` 逐条重连；无表时回退 `connect-all --nbft`（见 [../initramfs-nbft/README.md](../initramfs-nbft/README.md)）
- **验证**：`nbft-connect --selftest`（合成表解析）+ `test/test-nbft-connect-nbct.sh`（mock nvme 场景）；QEMU `AUTH=1` 六环全链路验证记录见仓库验证部分。
- **授权**：kurrent-firmware 自研实现，`FILE_LICENCE ( BSD2 )`。

## EMBED 自动引导脚本

`embed/auto.ipxe` 属于**配置资产**（非源码补丁）：改动无需重新生成补丁，直接修改文件后重新构建即可（见 [patches/README.zh-CN.md](../patches/README.zh-CN.md)）。

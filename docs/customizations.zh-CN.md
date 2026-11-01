# 定制内容

[English](customizations.md) | [中文](customizations.zh-CN.md)

本仓库相对上游 iPXE 基线（默认 `e6e51ccb`）的全部定制 = **十个补丁** + **构建级 EMBED 定制**（`embed/auto.ipxe`，经 `EMBED=` 编译进固件，非补丁）：

| # | 补丁 | 内容 |
|---|---|---|
| 0001 | `0001-realtek-adaptation.patch` | Realtek 网卡适配：RTL8125（2.5G）全系 + RTL8126（5G） |
| 0002 | `0002-makefile-ipxe-debug.patch` | debug 构建修复 |
| 0003 | `0003-snponly-local-boot.patch` | snponly 本地引导支持 |
| 0004 | `0004-device-info-collection.patch` | 设备信息采集：SMBIOS type 17 内存设置（`mem-total` / `mem-type` / `mem-speed`）+ PCI 设备表名经 `${net0/chip}` 暴露 |
| 0005 | `0005-nvmeof-adaptation.patch` | NVMe-oF（NVMe over TCP）SAN 协议支持（含认证与状态机修复、`hostnqn` 设置覆盖） |
| 0006 | `0006-efi-nvs-backend.patch` | EFI 变量 NVS 后端（`device-key` / `server-fingerprint` 重启保留；清空后的空块也落盘，即删除变量） |
| 0007 | `0007-tofu-fingerprint.patch` | TOFU 指纹链路（首次接触 TLS 放行、指纹存储） |
| 0008 | `0008-devicekey-commands.patch` | 设备身份密钥命令（`keygen` / `pubkey` / `sign` / `nvclear`） |
| 0009 | `0009-nvmetcp-nbct-acpi-table.patch` | NVMe 引导凭证表（NBCT：DH-HMAC-CHAP 密钥 + host NQN 经 ACPI 表交接内核侧） |
| 0010 | `0010-tls13-psk.patch` | TLS 1.3（RFC 8446）PSK 客户端：握手原语 + `add_tls13_psk()` 过滤连接 + `nvmetcp` 接线，含 RFC 8448 自测 |

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

### 1. Realtek 网卡适配（`0001`）

RTL8125（2.5G）全系：

- **背景**：RTL8125（2.5G）网卡必须由 iPXE native 驱动接管——固件 SNP 驱动在 iSCSI 挂载场景存在挂起缺陷，无法用于无盘引导；而上游 iPXE 对部分 8125 版本（XID 0x688 系列）支持不完整。
- **修改**：`src/drivers/net/realtek.c`、`realtek.h`
  - XID 0x688 版本表与设备识别
  - EPHY 初始化表（2.5G PHY 配置）
  - 32 位中断状态寄存器
  - FETCH/PAUSE_SLOT 配置
  - BAR 0x4808（2.5G 专用寄存器窗口）
  - TPPOLL_8125 轮询方式
- **许可**：8125 适配部分参考 Linux 内核 r8169 驱动（GPL-2.0-only），仅按 GPL-2.0 授权，不得以 UBDL 再分发（见 `patches/0001` 头部声明）。

RTL8126 5GbE：

- **背景**：RTL8126（5G）为 2024 年新卡，上游 iPXE 基线无 0x8126 设备项；其 GPHY 需按 ICVerID 分三种 PHY 配置方法（静态寄存器表）初始化，且部分 PCIe 配置（ZRXDC 超时上报、ASPM 入口延迟）需经 CSI 机制访问扩展配置空间，基线驱动均不具备。
- **修改**：`src/drivers/net/realtek.c`、`realtek.h`
  - `0x8126` 设备项与 `realtek_detect_8126`（TxConfig 0x64800000 族检测 + ICVerID → mcfg 1/2/3 分派）
  - GPHY OCP 接口函数（`realtek_gphy_ocp_read/write/modify`，重构 8125 内联 MII 访问并复用）
  - CSI 扩展配置空间接口（`realtek_csi_read/write/modify`，Linux `rtl_csi_*` 同机制）
  - PHY 静态配置表 ×3（`realtek_8126a_1/2/3_phy`，共 367 项，源自官方 r8126 驱动；剔除 MCU 微码段；区分直接写与读改写语义，分别对应官方 `rtl8126_mdio_direct_write_phy_ocp` 与 `rtl8126_clear_and_set_eth_phy_ocp_bit`）与 `realtek_hw_phy_config_8126`
  - `realtek_hw_start_8126`：ZRXDC 关闭 + ASPM 默认入口延迟（CSI 路径）+ 8125 公共初始化 + PHY 配置
  - 挂载：`realtek_detect` / `realtek_open` / `realtek_probe` 按 `mac_ver == 70` 分派
- **验证**：完整构建 10 产物全部通过（含 `DEBUG=realtek:3` debug 目标）；待物理机实测。
- **审计**：双来源 PHY 表对照审计与 PHY MCU 微码轻量方案（版本检查）详见 [8126-porting-audit.md](8126-porting-audit.md)。
- **许可**：8126 适配部分参考 Realtek r8126 驱动（GPL-2.0-only，Copyright 2025 Realtek Semiconductor Corp.）与 Linux 内核 r8169（GPL-2.0-only），仅按 GPL-2.0 授权，不得以 UBDL 再分发（见 `patches/0001` 头部声明）。

### 2. debug 构建修复（`0002`）

- **背景**：`ipxe-debug.efi` 目标未定义驱动集，构建产物为空壳（无任何网卡驱动），无法用于故障定位。
- **修改**：`src/Makefile` 新增 `DRIVERS_ipxe-debug += $(DRIVERS_ipxe)`，debug 目标继承全驱动集。

### 3. snponly 本地引导支持（`0003`）

- **背景**：官方 `snponly.efi` 仅支持固件 PXE 链加载场景（只接管加载 iPXE 的那个设备）；从本地 UEFI（U 盘/磁盘）引导时找不到任何网卡，直接进入 shell。这是"主板无 PXE 网络启动选项"场景的配套适配——本地介质引导时同样需要网络接管能力。
- **修改**：`src/drivers/net/efi/snponly.c`——链加载定位失败时回退接管全部 SNP/NII/MNP 设备，但**排除 iPXE 自己安装的 SNP 句柄**；PXE 链加载场景行为不变。
- **作用**：native 驱动不可用（如特定主板 RTL8168 初始化挂起）的机器，本地引导也有 SNP 兜底路径。排除自安装句柄是本地引导的必要条件：否则回退会绑定到 `efi_snp_probe()` 刚为本机网卡安装的 SNP 句柄，递归产生 `net0..netN`，直到 4 MB 堆耗尽——此后所有 HTTPS/TLS 分配（8 KB 菜单记录、TLS 1.3 sanboot）都会 `ENOMEM`。

### 4. 设备信息采集（`0004`）

- **背景**：固件侧设备信息采集（身份 / CPU / 内存 / 网卡）供 HTTP 上报。身份（SMBIOS type 1-3）与 CPU（CPUID）设置官方已有，缺口有二：SMBIOS type 17（内存设备，每插槽一条）无具名设置；PCI 网卡从不填充 `driver_name`，导致 `${net0/chip}` 在 PCI 上不可用。
- **修改**：`src/include/ipxe/smbios.h`、`src/interface/smbios/smbios_settings.c`、`src/drivers/bus/pci.c`
  - `struct smbios_memory_device`（type 17 布局经 dmidecode 三个版本交叉验证：Memory Type `0x12`、Speed `0x15`、Extended Size `0x1C`）+ `SMBIOS_TYPE_MEMORY_DEVICE 17`
  - `${mem-total}`（uint32 MB，全插槽聚合：`0xFFFF` 跳过、`0x7FFF` 回退 Extended Size、bit15=GB）、`${mem-type}`（首槽，映射为 `DDR5` 等字符串）、`${mem-speed}`（首槽，MT/s）——按名分派的自定义 fetch，复用现有 SMBIOS 设置 scope
  - `pci_probe` 现从匹配的设备表项填充 `driver_name`，使 `${net0/chip}`（如 `RTL8125`）对所有 PCI 网卡生效
- **用法**：设置项清单与上报 URL 模板见 [device-info-reporting.zh-CN.md](device-info-reporting.zh-CN.md)。
- **验证**：完整构建 10 产物全部通过；设置已编入（字符串验证）；真机行为待实测（空格 / 特殊字符的 URL 编码）。

### 5. NVMe-oF（NVMe over TCP）SAN 支持（`0005`）

- **背景**：上游 iPXE 无 NVMe-oF 传输支持；从 NVMe/TCP target（如 Linux `nvmet`）SAN 引导需要完整协议驱动 + `SANBOOT_PROTO_NVME_TCP` 配置项。针对 nvmet 端到端验证认证路径时发现的三个 bug 已就地修复：瞬态 `-EAGAIN` 误杀会话（应等待 TCP 窗口）、AuthReceive 可能被重复发送、认证完成竞态（phase 在最终 AuthReceive 完成前切换，导致 Property Set 被跳过、Identify 被拒）；另加严格模式 DH-HMAC-CHAP 认证要求 host NQN 与 nvmet `hosts/` 注册匹配，而 UUID 派生默认值对任意客户端不可预测。
- **修改**：`src/config/config.c`、`src/config/general.h`（`SANBOOT_PROTO_NVME_TCP`）、`src/include/ipxe/errfile.h`、`src/include/ipxe/nvmetcp.h`、`src/net/tcp/nvmetcp.c`、`src/net/tcp/nvmetcp_auth.c`、`src/tests/nvmetcp_test.c`、`src/tests/tests.c`
  - 8 阶段状态机：ICReq/ICResp 参数协商 → Connect（Admin）→ Property Set（CC.EN=1）→ Identify（控制器/命名空间）→ Connect（I/O）→ 块读写（R2T 流控）
  - DH-HMAC-CHAP 认证（AuthSend/AuthReceive，DH 群 0/2048/3072/4096）
  - EFI 设备路径描述与 BlockIo 钩接（供 `sanboot`）；单元测试（结构布局 + Identify NS 解析）
  - 瞬态 `-EAGAIN` 处理（挂起进程、窗口恢复后继续）与 AuthReceive 发送幂等、step 统一推进
  - 认证阶段完成以 `completed`/`rx_complete` 双标志 + 命令 id 匹配（`rx_cid`）门控，确保 Property Set 不被跳过（修复 Identify 被 `0x8018` 拒绝）；Connect 响应无 ATR 位时的 `NVME_SC_AUTH_REQUIRED` 状态码触发路径
  - Identify NS 的 LBAF 偏移修正（64→128）
  - 注册 `hostnqn` 设置项，覆盖 `nvmetcp_set_host_nqn()` 中 UUID 派生的默认值；未设置该选项的普通 `nvme://` URI 保持原回退行为（`nqn.2014-08.org.ipxe:<uuid>`）
- **用法**：端到端指南（nvmet 服务端配置含认证、`sanboot` 语法、QEMU 验证）见 [nvmeof-usage.md](nvmeof-usage.md)。
- **排障日志**：完整认证调查时间线与 wire 层证据见 [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md)。
- **验证**：QEMU/OVMF + Ubuntu 26.04 内核 7.0 nvmet target，GRUB 2.14 SAN 引导链路通过；全链路复跑：`sending Property Set (CC)` 出现、wire 层全部命令 `status=0x0000`、`0x8018` 出现 0 次。引导服务器按 MAC 注入 host NQN，nvmet `hosts/` 严格模式接受（`test/nvmet-setup.sh` 的 `AUTH=1`）。
- **授权**：kurrent-firmware 自研实现，`FILE_LICENCE ( GPL2_ONLY )`——仅按 GPL-2.0 授权，不得以 UBDL 再分发。

### 6. EFI 变量 NVS 后端（`0006`）

- **背景**：设备信任根体系需要在非易失存储中保存设备身份密钥与服务端证书指纹；iPXE 默认 NVS 后端（PCI option ROM、SMBIOS）在 EFI 引导路径上缺失或只读，需要基于 EFI NVRAM 变量的专用后端。
- **修改**：`src/interface/efi/efi_nvs.c`、`src/core/nvo.c`、`src/config/config_efi.c`、`src/include/ipxe/dhcp.h`（`DHCP_EB_DEVICE_KEY` 0x5e、`DHCP_EB_SERVER_FINGERPRINT` 0x5f）、`src/include/ipxe/errfile.h`
  - 新增 `efi_nvs.c` 设置后端：单个 EFI NVRAM 变量（项目命名空间 GUID）承载整个 options 块；store/load/delete 钩子接入 EFI 设置机制
  - `device-key` 与 `server-fingerprint` 因此重启保留
  - `src/core/nvo.c`：`nvo_save()` 在 options 块长度归零时下发一次零长度写。`nvs_write()` 是 `while (len)` 循环，零长度时**一次设备写都不做**——于是"存一个空块"是空转：EFI 变量保留上一次的内容，被"删掉"的设置下次开机又回来了。EFI 后端把零长度写实现为删除变量。
- **验证**：QEMU/OVMF 两轮测试——第 2 轮（保留 NVRAM）密钥仍存在且无需重新生成；`keygen` 拒绝覆盖。整块清空由 `test/run-qemu-nvclear.sh` 三轮验证（第 3 轮开机时三项设置均已不存在）；去掉 `nvo.c` 那段改动后第 3 轮会重新进入清理分支——最后被删的 `trust` 从陈旧变量里复活。

### 7. TOFU 指纹链路（`0007`）

- **背景**：信任根体系需在首次接触时容忍自签或未受信任的 HTTPS 服务器（注册窗口），此后固定该服务器；上游 iPXE 无 trust-on-first-use 机制。
- **修改**：`src/net/tofu.c`、`src/include/ipxe/tofu.h`、`src/net/tls.c`、`src/include/ipxe/errfile.h`
  - `tofu_fingerprint_present()` / `tofu_store()`：TLS 叶子证书的 SHA-256 指纹，镜像至 `trust` 设置
  - `tls_validator_done()`：校验失败时，若尚未存有指纹则接受握手并记录指纹（TOFU）；一旦存在指纹，后续任何失败均致命
- **验证**：在 0006 基础上补丁双向应用通过。

### 8. 设备身份密钥命令（`0008`）

- **背景**：信任根体系要求设备侧完成 ECDSA P-256 密钥生成、公钥导出与签名——私钥永不出设备。
- **修改**：`src/hci/commands/devicekey_cmd.c`、`src/config/general.h`（`DEVICEKEY_CMD`）、`src/config/config.c`（`REQUIRE_OBJECT ( devicekey_cmd )`）、`src/include/ipxe/dhcp.h`（`DHCP_EB_PUBKEY` 0x60、`DHCP_EB_SIG` 0x61）、`src/include/ipxe/errfile.h`
  - `keygen`：DRBG（以 EFI RNG 熵源为种子）生成 32 字节 P-256 私钥并存入 `device-key`；拒绝覆盖已存在的密钥
  - `pubkey`：经 P-256 曲线乘法推导未压缩点（`0x04‖X‖Y`，130 hex）
  - `sign`：数据（参数拼接）SHA-256 摘要 → ECDSA P-256 → base64(DER) 签名，同时存入 `sig` 设置供脚本使用
  - `nvclear`：一条命令把 `device-key`、`server-fingerprint`、`trust` 三项从非易失 options 块删除，逐项报告（`cleared` / `not present` / 错误）。删除时按 `nvo/<名>` 定位到该块：裸名只清内存副本，存储里的那份仍在。
- **验证**：QEMU/OVMF 两轮——第 1 轮（清空 NVRAM）：keygen/pubkey/sign 全部成功；主机侧（OpenSSL/python）对打印的公钥与签名独立验签通过（PREHASHED 与 REHASH）；第 2 轮（保留 NVRAM）：keygen 拒绝覆盖，pubkey/sign 输出与第 1 轮完全一致（持久化验证）。`nvclear` 验收：`test/run-qemu-nvclear.sh`（三轮，第 3 轮开机时三项已全部不存在）。
- **授权**：kurrent-firmware 自研实现，`FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )`。

### 9. NVMe 引导凭证表（`0009`）

- **背景**：认证引导下，内核侧重连不得第二次经网络获取凭证——固件已持有每会话的 DH-HMAC-CHAP 密钥与 host NQN，应以内核可读的方式带内接力。
- **修改**：`src/drivers/block/nbct.c`（新）、`src/include/ipxe/nbct.h`（新）、`src/include/ipxe/errfile.h`、`src/include/ipxe/nvmetcp.h`、`src/net/tcp/nvmetcp.c`
  - 按 iBFT 的 `acpi_model` 注册模式安装（`nbct_model`）；每个已认证 NVMe/TCP 会话暴露 `acpi_describe` 接口操作
  - sanboot 描述时（`efi_block_describe` → `acpi_install`）安装签名为 `NBCT` 的自定义 ACPI 表：36 字节 ACPI 头 + 记录数 + N 条定长 1152 字节记录（traddr / trsvcid / nqn / hostnqn / secret / tls_trsvcid / tls_psk）
  - 表仅驻留内存（不入 NVRAM），随引导会话消亡
- **消费侧**：`initramfs-nbft/nbft-connect --connect` 检测 `/sys/firmware/acpi/tables/NBCT*`，以 `--dhchap-secret` / `--hostnqn` 逐条重连；记录带 `tls_trsvcid` 时改为在内核全局 `.nvme` keyring 注入 `tls_psk` 并以 `--tls` 在 TLS 端口重连（内核段传输加密）；无表时回退 `connect-all --nbft`（见 [../initramfs-nbft/README.md](../initramfs-nbft/README.md)）
- **验证**：`nbft-connect --selftest`（合成表解析）+ `test/test-nbft-connect-nbct.sh`（mock nvme 场景）；QEMU `AUTH=1` 六环全链路验证记录见仓库验证部分。
- **授权**：kurrent-firmware 自研实现，`FILE_LICENCE ( BSD2 )`。

### 10. TLS 1.3 预共享密钥客户端（`0010`）

- **动机**：固件段（`sanboot` 读 ESP/kernel/initrd）是加密链条上最后的明文环——iPXE 的 TLS 栈只到 1.2，内核段（GRUB 之后）可交内核加密，固件段却不行。本补丁给固件补上 TLS 1.3 PSK 客户端（客户端握手原语 + 驱动这些原语的过滤连接）；配合控制面默认把 sanboot 端口切到数据面 TLS 端口，固件段与内核段即全程加密。
- **改动**：`src/net/tls.c`、`src/include/ipxe/tls.h`、`src/net/tls13.c`（新）、`src/include/ipxe/tls13.h`（新）、`src/net/tcp/nvmetcp.c`、`src/include/ipxe/errfile.h`、`src/tests/tls13_test.c`（新）、`src/tests/tls13_conn_test.c`（新）、`src/tests/tests.c`
  - 密钥调度：`tls13_expand_label` / `tls13_derive_secret` / `tls13_early_secret` / `tls13_handshake_secret` / `tls13_master_secret` / `tls13_traffic_key`，基于现有 `hkdf.c`
  - `tls13_client_hello`：TLS 1.3 ClientHello 构造器，单套件（`TLS_AES_128_GCM_SHA256`）+ `psk_dhe_ke` 模式，`pre_shared_key` 置尾，binder 覆盖截断 ClientHello
  - `tls13_binder` 与 `tls13_finished`：Finished/binder 共用的 `HMAC( finished_key, Transcript-Hash( ... ) )` 构造
  - `tls13_parse_server_hello`：ServerHello 解析（协商版本、套件、被接受的 PSK 身份、X25519 key share）
  - 记录保护：`tls13_nonce`（写 IV 异或序列号）、`tls13_seal` 与 `tls13_open`（AES-128-GCM AEAD，明文尾附内层内容类型，记录头作附加数据）
  - `tls13_generate_key` / `tls13_shared_secret`：经现有 `x25519_algorithm` 生成临时密钥对与协商共享密钥
  - `struct tls13_handshake` 及其访问器：握手 transcript 上下文（带边界检查的 transcript 累积、`tls13_handshake_exchange` 完成 Early → Handshake 跃迁、`tls13_handshake_derive` / `_finished` / `_master`）
  - `add_tls13_psk()`（`tls13.c`）：连接本体——位于字节流消费者与 socket 之间的过滤接口，含 ClientHello → 服务端 flight → 客户端 Finished → 数据 的阶段机、接收记录重组，以及握手完成前保持关闭的明文窗口。明文窗口在每次 `tls13_psk_tx()` 调用时**无条件**重新通知，包括当前无待发记录时：iPXE 的 TCP 在有未确认段时报零窗口，此刻若跳过通知就再也不会补发，消费者会永久停摆
  - `tls13_psk_open_socket`（`tls13.h`）：`add_tls13_psk()` 所用的 socket 打开器，缺省即 `xfer_open_named_socket()`；存在目的是让连接层自测能替换成 mock socket
  - TLS 1.3 版本/扩展/套件常量（`TLS_VERSION_TLS_1_3`、扩展 5/8/41/43/45/51、`TLS_AES_128_GCM_SHA256`）
  - `nvmetcp`：`nvmetcp_use_tls()` 判真时（引导 URI 带 `tls_psk=`（十六进制解码）**且** 连接端口等于 `tls_trsvcid`）`nvmetcp_open_socket()` 把会话接入 `add_tls13_psk()`，并推导 `NVMe0R01 <hostnqn> <subsysnqn>` 形式的 PSK identity；否则明文路径不变——即带交接参数但仍指向明文端口的 URI 不会让固件连接加密
- **验证**：`tls13_test` 自测（RFC 8448 第 3、4 节向量——密钥调度、PSK binder、ServerHello 解析、X25519 密钥交换、握手 transcript 上下文、Finished verify_data、记录加解密——外加 ClientHello 扩展块结构遍历与经变异测试的负例）；经 QEMU/OVMF 跑 `bin-x86_64-efi/tests.efi`，110 项断言全绿（Linux 的 `tests.linux` 二进制因 `0006` 引入的 EFI 耦合无法构建）。`tls13_conn_test` 在进程内以 mock socket + mock 消费者驱动连接层，服务端由测试自身扮演：ClientHello → ServerHello → 服务端 Finished → 客户端 Finished → 数据，并在握手态与建立态各验一次明文窗口契约（27 项断言；已变异验证：把窗口通知挪回"仅在发出记录时"、以及删掉 `SERVER_FINISHED → CLIENT_FINISHED` 阶段跃迁，分别令 2 项与 6 项变红）。线级验收：内嵌 `sanboot nvme://…:4421/<nqn>?tls_psk=…` 的 EFI 镜像对真实 `nvmet` TLS 目标完成握手（宿主日志 `Created nvm controller … , TLS.`），注册 SAN 设备并完成读盘，且 `:4421` 上每条客户端连接首字节均为 `0x16`（ClientHello）、明文 ICReq 计数为 0。
- **授权**：修改的是携带 `FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )` 的上游文件；新增文件与新增自测沿用同一双许可。

> 补丁集已于 2026-09-12 整理：RTL8126 适配（原为修补 8125 补丁的独立补丁）并入 `0001`；NVMe/TCP 认证修复与 `hostnqn` 设置（原为独立追加补丁）并入 `0005`。12 补丁序列整合为 9 个；新序列在干净基线上重放，最终树与旧序列逐位一致。

## EMBED 自动引导脚本

`embed/auto.ipxe` 属于**配置资产**（非源码补丁）：改动无需重新生成补丁，直接修改文件后重新构建即可（见 [patches/README.zh-CN.md](../patches/README.zh-CN.md)）。

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
| `0001-realtek-adaptation.patch` | `src/drivers/net/realtek.c`、`realtek.h` | Realtek 2.5/5GbE 适配：RTL8125 全系（XID 0x688 版本表、EPHY 初始化表、32 位中断寄存器、FETCH/PAUSE_SLOT、BAR 0x4808、TPPOLL_8125）+ RTL8126 5GbE（ICVerID 检测与 PHY 配置方法分派、共用 GPHY OCP/CSI 接口、PHY 静态配置表 ×3、ZRXDC/ASPM 配置） |
| `0002-makefile-ipxe-debug.patch` | `src/Makefile` | 新增 `DRIVERS_ipxe-debug` 定义（debug 目标继承全驱动集，修复 `obj_ipxe_debug` 链接失败） |
| `0003-snponly-local-boot.patch` | `src/drivers/net/efi/snponly.c` | snponly 本地引导支持：链加载定位失败时（本地 UEFI 引导）回退接管全部 SNP/NII/MNP 设备，但排除 iPXE 自己安装的 SNP 句柄（防止递归创建 net0..netN）；PXE 链加载场景行为不变 |
| `0004-device-info-collection.patch` | `src/include/ipxe/smbios.h`、`src/interface/smbios/smbios_settings.c`、`src/drivers/bus/pci.c` | 设备信息采集：SMBIOS type 17 内存设置（`mem-total` 全插槽聚合、`mem-type` / `mem-speed` 取首槽，自定义 fetch）+ PCI `driver_name` 填充，使 `${net0/chip}` 输出设备表名（如 `RTL8125`） |
| `0005-nvmeof-adaptation.patch` | `src/config/config.c`、`src/config/general.h`、`src/include/ipxe/errfile.h`、`src/include/ipxe/nvmetcp.h`、`src/net/tcp/nvmetcp.c`、`src/net/tcp/nvmetcp_auth.c`、`src/tests/nvmetcp_test.c`、`src/tests/tests.c` | NVMe-oF（NVMe over TCP）SAN 协议支持：新增 nvmetcp 驱动（ICReq/ICResp 参数协商、Property Set（CC 寄存器）、Connect/Identify、块读写、R2T 流控、DH-HMAC-CHAP 认证、EFI 设备路径描述与 BlockIo 钩接）+ `SANBOOT_PROTO_NVME_TCP` 配置与单元测试。含认证与状态机修复（瞬态 `-EAGAIN` 处理、AuthReceive 发送幂等与 step 统一推进、`completed`/`rx_complete` 双标志 + `rx_cid` 命令 id 门控、Identify Namespace LBAF 偏移修正）与 `hostnqn` 设置覆盖。详见 `../docs/nvmeof-auth-debug-log.md` |
| `0006-efi-nvs-backend.patch` | `src/config/config_efi.c`、`src/core/nvo.c`、`src/interface/efi/efi_nvs.c`、`src/include/ipxe/dhcp.h`、`src/include/ipxe/errfile.h` | EFI 变量 NVS 后端：新增 `efi_nvs.c` 设置后端，持久化于 EFI NVRAM 变量（项目命名空间 GUID）——`device-key`（0x5e）与 `server-fingerprint`（0x5f）设置重启保留；`nvo_save()` 现在会把被清空的 options 块也下发（零长度写 = 删除变量），缺了它删掉最后一项永远到不了存储 |
| `0007-tofu-fingerprint.patch` | `src/include/ipxe/tofu.h`、`src/net/tofu.c`、`src/net/tls.c`、`src/include/ipxe/errfile.h` | TOFU 指纹链路：首次 TLS 握手时接受未受信任的叶子证书并将其 SHA-256 指纹存储（镜像至 `trust` 设置）；一旦存在指纹，后续任何证书校验失败均致命 |
| `0008-devicekey-commands.patch` | `src/hci/commands/devicekey_cmd.c`、`src/config/general.h`、`src/config/config.c`、`src/include/ipxe/dhcp.h`、`src/include/ipxe/errfile.h` | 设备身份密钥命令（`keygen`/`pubkey`/`sign`）以及 `nvclear`（一条命令清空非易失存储里的 `device-key`、`server-fingerprint`、`trust`）：ECDSA P-256 密钥生成（DRBG 以 EFI RNG 为熵源）、公钥推导（未压缩点，130 hex）、SHA-256 → ECDSA 签名并以 base64(DER) 输出；`DEVICEKEY_CMD` 配置项 |
| `0009-nvmetcp-nbct-acpi-table.patch` | `src/drivers/block/nbct.c`（新）、`src/include/ipxe/nbct.h`（新）、`src/include/ipxe/errfile.h`、`src/include/ipxe/nvmetcp.h`、`src/net/tcp/nvmetcp.c` | NVMe 引导凭证表（NBCT）：sanboot 时按 iBFT 的 `acpi_model` 注册模式安装自定义 ACPI 表，每个已认证 NVMe/TCP 会话一条定长记录（传输地址、子系统 NQN、host NQN、DH-HMAC-CHAP 密钥，以及内核段 TLS 交接参数 `tls_trsvcid`/`tls_psk`）；initramfs 侧 `nbft-connect`（见 `../initramfs-nbft/`）消费该表，以 `--dhchap-secret`/`--hostnqn` 逐条重连，记录带 `tls_trsvcid` 时改为注入 PSK 并以 `--tls` 重连，避免二次网络获取凭证 |
| `0010-tls13-psk.patch` | `src/net/tls.c`、`src/include/ipxe/tls.h`、`src/net/tls13.c`（新）、`src/include/ipxe/tls13.h`（新）、`src/net/tcp/nvmetcp.c`、`src/include/ipxe/errfile.h`、`src/tests/tls13_test.c`（新）、`src/tests/tls13_conn_test.c`（新）、`src/tests/tests.c` | 固件引导段的 TLS 1.3（RFC 8446）预共享密钥客户端，分两层。原语层：RFC 8446 第 7.1 节密钥调度（`tls13_expand_label`、`tls13_derive_secret`、`tls13_early_secret`、`tls13_handshake_secret`、`tls13_master_secret`、`tls13_traffic_key`）、Finished/binder 构造（`tls13_finished`、`tls13_binder`）、ClientHello 构造器（`tls13_client_hello`：psk_dhe_ke、单套件、pre_shared_key 置尾、binder 覆盖截断 ClientHello）、ServerHello 解析（`tls13_parse_server_hello`）、X25519 密钥交换（`tls13_generate_key`、`tls13_shared_secret`）、transcript 上下文（`struct tls13_handshake`）、RFC 8446 第 5.3 节记录保护（`tls13_nonce`、`tls13_seal`、`tls13_open`）与 TLS 1.3 版本/扩展/套件常量。连接层：`add_tls13_psk()`（`tls13.c`）作为字节流消费者与 socket 之间的过滤接口，驱动握手并保护其后每一条记录；`nvmetcp` 仅在 `nvmetcp_use_tls()` 判真时把会话接入该过滤层，即引导 URI 带 `tls_psk=` **且** 连接端口等于 `tls_trsvcid`（TLS 交接参数在每次可加密引导时都会下发，故由端口而非参数有无决定固件连接本身是否加密），并推导 `NVMe0R01 <hostnqn> <subsysnqn>` 形式的 PSK identity。RFC 8448 自测（`tls13_test`，第 3、4 节 + ClientHello 扩展块结构遍历）；连接层自测（`tls13_conn_test`）以 mock socket 与 mock 消费者驱动连接层，服务端由测试自身扮演 |

上表为 **L1 补丁序列**，由 `build/build.sh` 与 `build/build-sb.sh` 共同应用。Secure Boot 构建额外应用第二个叠加补丁，普通 glob 不会匹配到它：

| 补丁 | 修改文件 | 内容 |
|---|---|---|
| `secureboot/0001-no-tofu.patch` | `src/net/tofu.c` | 固定引导 CA 时 TOFU 必须关闭。`tofu_fingerprint_present()` 恒报告"存在"，使不受信任的证书链直接致命，而不是被接受并存储。仅由 `build/build-sb.sh` 应用；每个 L1 构建保持 0007 的行为逐字节不变 |

> RTL8168 相关研究已于 2026-08 终止，补丁不含 8168 过滤或修复代码（见 `../docs/8168-research-log.md`）。
>
> 补丁集已于 2026-09-12 整理合并（原 12 个补丁重打包为补丁 0001-0009；仅修补前序补丁的已并入其源头补丁），并以干净基线重放验证：新序列最终树哈希与旧序列逐位一致（`2151e97b3d0b9029b03ae0f7a3dbfbe88930f206`）。补丁 0010（TLS 1.3 PSK）于 2026-10-06 后续追加；补丁 0003 于 2026-10-17 增加本地引导的 SNP 句柄排除。当前 10 补丁序列（干净基线 + `0001`-`0010`）重放树哈希为 `aeabad7beb6bd7d92657112cd9e88b042f23f6c8`；Secure Boot 叠加补丁位于 `secureboot/`，只由 `build/build-sb.sh` 应用，因此该树哈希仍描述每一个 L1 构建。

## 授权说明

- 补丁修改的上游文件（`realtek.c`、`snponly.c`、`Makefile`、`smbios.h`、`smbios_settings.c`、`pci.c`）继承 iPXE 的 GPL-2.0-or-later / UBDL 许可；
- `0001` 中 RTL8125 适配部分（XID 版本表、EPHY 初始化、电源管理等）参考 Linux 内核 r8169 驱动（`drivers/net/ethernet/realtek/r8169_main.c`，GPL-2.0-only），该部分**仅按 GPL-2.0 授权**，不得以 UBDL 或更高版本许可再分发；
- `0001` 中 RTL8126 适配部分（PHY 静态配置表、GPHY OCP/CSI 接口、ZRXDC/ASPM 配置等）参考 Realtek r8126 驱动（`r8126_n.c`，GPL-2.0-only，Copyright 2025 Realtek Semiconductor Corp.）与 Linux 内核 r8169 驱动（`drivers/net/ethernet/realtek/r8169_main.c`，GPL-2.0-only），该部分**仅按 GPL-2.0 授权**，不得以 UBDL 或更高版本许可再分发；
- `0005` 中的 NVMe/TCP 驱动文件（`nvmetcp.c`、`nvmetcp_auth.c`、`nvmetcp.h`、`nvmetcp_test.c`）为 kurrent-firmware 自研实现，文件头 `FILE_LICENCE ( GPL2_ONLY )`，**仅按 GPL-2.0 授权**，不得以 UBDL 许可再分发；
- `0006`/`0007`/`0008` 中的设备身份新文件（`efi_nvs.c`、`tofu.c`、`tofu.h`、`devicekey_cmd.c`）为 kurrent-firmware 自研实现，文件头 `FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )`，与上游 iPXE 双许可一致；
- `0009` 中的 NBCT 新文件（`nbct.c`、`nbct.h`）为 kurrent-firmware 自研实现，文件头 `FILE_LICENCE ( BSD2 )`（类内核许可，对齐上游 iPXE `ibft.c` 的 ACPI 表先例）；
- `0010` 的 TLS 1.3 改动修改的是携带 `FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )` 的上游文件（`tls.c`、`tls.h`、`errfile.h`、`nvmetcp.c`、`tests.c`），两个新增文件（`tls13.c`、`tls13.h`）与新增自测（`tls13_test.c`）沿用同一上游双许可；
- `secureboot/0001-no-tofu.patch` 修改本项目的 `tofu.c`（GPL2_OR_LATER_OR_UBDL），不引入第三方代码；
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
   git diff > patches/0001-realtek-adaptation.patch
   ```

   注意：**先应用旧补丁到新基线 → 手动解决冲突 → 再重新生成**，比手工重写更可靠；
   重新生成的补丁会覆盖头部许可注释，须从旧补丁头部复制保留（见上方"授权说明"）。
3. 更新 `build/build.sh` 中的 `UPSTREAM_COMMIT` 与本文档基线记录。

4. 运行 `./build/build.sh` 验证补丁可干净应用、产物功能正常（重点回归：8125/8126 引导）。

## 注意事项

- `embed/auto.ipxe` 属于**配置资产**（非源码补丁），改动无需重新生成补丁，直接修改 `../embed/auto.ipxe` 后重新构建即可
- 补丁需保持 `git apply --check` 通过；补丁与基线提交强绑定，`UPSTREAM_COMMIT` 变更前务必走升级流程
- 修补补丁时应在源头补丁上原地修改（从构建缓存工作树重新生成），而非追加"修复补丁的补丁"；如需分层修复，发布前须并回源头补丁

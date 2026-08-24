# NVMe-oF (NVMe/TCP) 支持研究

> 分支：`research/nvme-of`（基于 main / v0.1.2）
> 状态：研究阶段（M1 完成）
>
> 实机验证进展（2026-08-18）：QEMU + nvmet + GRUB 2.14 的 SAN 引导链路已验证通过，
> 详见 [nvmeof-san-boot-verification.md](nvmeof-san-boot-verification.md)。

## 1. 背景与目标

为 iPXE 固件增加从 NVMe/TCP target 启动（sanboot）的能力，与现有 iSCSI 引导并列。

| 已确认的决策（2026-08-17） |

| 决策项 | 结论 |
|---|---|
| 功能范围 | 仅 NVMe/TCP 启动（不实现本地 PCIe NVMe 盘驱动） |
| 推进方式 | 先研究文档后实现（本文档 → M2/M3 分阶段实现） |
| 验收环境 | 编译级验证（构建进固件，无实机协议测试） |
| 引导形态 | sanboot 挂盘 + EFI Block I/O 暴露（覆盖 Linux 与 Windows Server 2025+） |
| 接力通道 | Linux: NBFT（dracut 95nvmf 原生消费）/ rd.nvmf.* 参数；Windows: Server 2025 in-box initiator |
| Target 对接 | Linux nvmet（内核自带；configfs 配置认证密钥与 DH 组） |
| 认证 | DH-HMAC-CHAP 完整实现（FFDHE2048 + HMAC-SHA-256，对齐 nvmet；默认不启用，target 要求认证时启用） |

## 2. 现状调研

### 2.1 上游 iPXE 无任何 NVMe 代码

- 基线 `e6e51ccb`（2026-08-07 上游 master）全树无 `nvme` 文件；`src/drivers/block/` 仅有 `ata.c` / `ibft.c` / `scsi.c` / `srp.c`。
- 本地 NVMe 盘驱动、NVMe-oF 客户端均为空白，需从零实现。
- GitHub issue [ipxe/ipxe#556](https://github.com/ipxe/ipxe/issues/556)（2022-01 提出 "nvme over TCP"）至今 open、无 PR——**无社区现成实现可移植**。

### 2.2 iPXE 可复用基础（已查证）

| 集成点 | 位置 | 说明 |
|---|---|---|
| TCP 客户端范例 | `src/net/tcp/iscsi.c` | iSCSI 是 TCP 上层协议，连接用 `xfer_open_named_socket( SOCK_STREAM )`，是最佳参照模板 |
| URI opener 注册 | `struct uri_opener iscsi_uri_opener __uri_opener`（uri.h 的 `__uri_opener` 链接段） | 新协议注册 `.scheme = "nvme"`, `.open = nvmetcp_open` |
| 块设备接口 | `include/ipxe/blockdev.h`：`block_read` / `block_write` / `block_read_capacity` | NVMe/TCP 块设备需实现这三者 |
| 构建开关 | `src/config/general.h` 的 `SANBOOT_PROTO_*` 宏体系（AOE/FCP/HTTP/IB_SRP/ISCSI） | 新增 `SANBOOT_PROTO_NVME_TCP`，机制细节实现阶段核对 |
| 许可模式 | iscsi.c 头部：`FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )` + `FILE_SECBOOT ( PERMITTED )` | 新文件沿用（若参考 Linux 代码则按 GPL-2.0 单独声明，见 §7） |
| NBFT 同类机制 | `drivers/block/ibft.c`：生成 iBFT ACPI 表并安装进 UEFI | NBFT 表生成照抄此模式 |

注意：iSCSI 位于 `net/tcp/` 而非 `drivers/block/`——TCP 上层协议按此归位，NVMe/TCP 客户端同理放 `src/net/tcp/`。

### 2.3 参考源码查证（thirdparty/ 实况）

- `thirdparty/kernel/linux-7.1.7`：**真内核源码**（7.1.7），nvme-tcp 客户端权威参考：`drivers/nvme/host/tcp.c`（3088 行，含 `nvme_tcp_hdr` / `nvme_tcp_icreq_pdu` / `nvme_tcp_icresp_pdu` 结构）、`fabrics.c`、`include/linux/nvme.h`。`include/acpi/actbl1.h` 保留 `ACPI_SIG_NBFT` 签名，但**无表结构定义**。
- `thirdparty/kernel/linux-v6.12`：无 NBFT 任何痕迹。
- `thirdparty/kernel/linux-master`：**不是内核源码**（HEAD 为 kurrent-firmware 自身提交 20fb7c8），排除。
- `thirdparty/ipxe`：上游 master（e6d0a97c0，2026-08-11），无 NVMe/NBFT 代码。

## 3. 协议研究要点（NVMe/TCP，TP 8000）

### 3.1 NVMe 基础（Admin 命令集）

- 命令格式：64 字节；opcode 0x7F 为 NVMe-oF 所有 Fabric 命令统一 opcode，以 `fctype` 字段区分（Property Set=0x00、Connect=0x01、Property Get=0x04、Auth Send=0x05、Auth Receive=0x06；Disconnect 内核未定义，断开直接断 TCP）。
- Identify 命令（opcode 0x06）取控制器/命名空间信息（命名空间大小、块大小 → 块设备容量）。
- 队列：Submission/Completion Queue 配对；引导场景只需 **admin 队列（qid=0）+ 1 个 I/O 队列（qid=1）**。

### 3.2 NVMe/TCP 传输层

- 默认端口 4420。
- PDU 头 16 字节：`type`(1B) + `flags`(1B，低 3 位为 PDU 头长) + `hlen`(1B) + `plen`(3B 大端，头+数据总长) + 10B PDU 特定头。
- PDU 类型：`ICReq=0x01` / `ICResp=0x02` / `H2CData=0x03` / `C2HData=0x04` / `NOP_In=0x05` / `NOP_Out=0x06` / `Request=0x07` / `Response=0x08` / `R2T=0x09`。
- Digest：可选 `HDGST`（头）/ `DDGST`（数据），CRC32C，ICReq/ICResp 中协商。**实现先关闭 digest，减少边界处理**（target 通常可协商关闭）。
- 数据通路：READ 命令由 target 以 `C2HData` PDU 回传数据；WRITE 命令 host 可能收到 `R2T` 后以 `H2CData` 发送（sanboot 场景只读引导，WRITE 可先实现最小支持或不支持）。

### 3.3 连接建立流程（与 iSCSI 对照）

| 步骤 | iSCSI（现有） | NVMe/TCP（待实现） |
|---|---|---|
| 1 | TCP 连接 | TCP 连接（xfer_open_named_socket） |
| 2 | Login PDU 协商 | ICReq/ICResp（协议版本、digest、maxr2t） |
| 3 | Login 完成 + SCSI 参数 | Connect admin 命令（fctype=0x01，带 HostNQN/SubNQN） |
| 3.5 | — | 认证（可选）：DH-HMAC-CHAP（fabric Auth Send/Receive，fctype=0x05/0x06，四消息协商） |
| 4 | — | Identify Controller → Identify Namespace（取容量） |
| 5 | SCSI READ/WRITE | I/O 队列 Connect（qid=1）→ NVMe READ/WRITE |

### 3.4 参考实现与待核对清单

- 规范：NVM Express Base Spec 2.x + TP 8000（NVMe/TCP）。
- 参考实现：本地 `thirdparty/kernel/linux-7.1.7/drivers/nvme/host/tcp.c`（nvme-tcp 客户端，GPL-2.0）——结构体定义、PDU 收发、状态机逐项对照。
- 实现阶段逐项核对：PDU 头字段布局、ICReq/ICResp 数据段（40B 结构 + digest）、Connect 命令数据结构、Keyed SGL 格式、C2HData 的 CCS 标志位语义。

### 3.5 NBFT 接力机制（内核侧现状）

**NBFT（NVMe Boot Firmware Table）** 是 iBFT 的 NVMe-oF 版 ACPI 表：引导固件（iPXE）生成，OS 侧读取后自动连接 target，即"内核接力"的正式通道。

查证事实（2026-08 调研更新）：

- **mainline 内核驱动层不消费 NBFT**：7.1.7 / v6.12 / master 均无 `drivers/nvme/host/nbft.c`，全历史无该文件（曾有的支持已移除，仅 7.1.7 的 actbl1.h 保留 `ACPI_SIG_NBFT` 签名）。与 iSCSI 对照：iBFT 有内核 `CONFIG_ISCSI_IBFT_FIND=y` 兜底发现表，**NBFT 无内核支持**——发现/消费全部落在发行版用户空间。
- **通用底座已就位**：libnvme（linux-nvme 项目）提供 NBFT 解析 C API，`nvme-cli` 以 `nvme show-nbft`（解析表）与 `nvme connect-nbft`（按表连接）暴露——跨发行版标准件，任何 initramfs 框架的消费逻辑都是"检测 NBFT → 按表配置网络 → connect-nbft"。
- **SUSE（最完整）**：SLES 15 SP7+ / openSUSE Leap 15.5+ 原生支持——dracut `nvmf` 模块扩展 NBFT 解析（逻辑与 iscsi 模块的 iBFT 解析同构：cmdline 阶段翻译成 ip=/ifname 指令 → udev 规则重命名引导网口 `nbft0/nbft1...` → initqueue 阶段执行 `nvme connect-nbft`），安装器（linuxrc/YaST）亦自动检测；官方文档明示"安装后自动从 NVMe-oF/TCP 启动"。早期（15.4/SP4）用 DUD 过渡。
- **RHEL**：9.7+ / 10.x 的 `nm-initrd-generator`（NetworkManager）加入 NBFT 解析器，但官方 release notes（9.7 / 10.2）标注 **Technology Preview**，仅限 select server platforms（需厂商 HII 配合）。
- **systemd**：`network-generator` NBFT 支持 RFE 已关闭（closed as not planned，#36443，2025-02）——NBFT 网络解析不并入 systemd；Red Hat 工程师正开发通用 initramfs 模块（dracut/mkosi 通用，网络层对接 NetworkManager/wicked）替代 dracut 95nvmf 部分功能，尚未落地。
- 结论：iPXE 侧照常生成 NBFT 表；接力端 = 支持 NBFT 解析的发行版 initramfs（SLES 15 SP7+ 完整、RHEL 9.7+/10.x TP），其余发行版需自备消费模块（见 §3.7.4）。

NBFT 表格式来源（按优先级）：① NVMe Boot Specification（NVM Express 官方）；② NetworkManager `nm-initrd-generator` NBFT 解析器源码（用户空间消费方，含表结构定义）；③ SUSE dracut `nvmf` 模块 / libnvme（交叉验证）；④ 7.1.7 `include/acpi/actbl1.h` 签名（仅佐证）。

### 3.6 双客户端接力链路（Linux + Windows）

统一形态：**sanboot 挂盘 + EFI Block I/O 暴露**——iPXE 把 NVMe/TCP 盘以 EFI 块设备呈现（现有机 `interface/efi/efi_block.c`，iSCSI 引导 Windows 的同款机制），两端引导器都能枚举：

| 客户端 | 引导阶段 | 接力阶段 |
|---|---|---|
| Linux | iPXE 从 san 盘文件系统读 vmlinuz+initrd（iPXE fs 层支持块设备文件系统），或 UEFI 引导管理器直接枚举 | 发行版 initramfs 消费 NBFT（SLES 15 SP7+ 原生 / RHEL 9.7+ TP / 其余自备模块，详见 §3.7）或 `rd.nvmf.*` 参数通道 |
| Windows Server 2025+ | bootmgfw.efi 从 EFI Block I/O 读引导文件 | Server 2025 **in-box NVMe-oF initiator**（NVMe/TCP）原生接管 |

边界：Windows 客户端 SKU（11/10）无 in-box NVMe-oF initiator，启动后无法接力，不在支持范围。

### 3.7 发行版系统层接力现状（调研 2026-08）

#### 3.7.1 两种接力通道

| 通道 | 机制 | 代表 |
|---|---|---|
| **NBFT 自动接力** | 固件生成 ACPI NBFT 表，initramfs 解析后自动 `nvme connect-nbft` | SLES 15 SP7+、RHEL 9.7+ |
| **参数驱动** | initramfs 模块读 `rd.nvmf.*` / `rd.nvmf.discover` 手动连接 | dracut 95nvmf（Fedora 等） |

#### 3.7.2 发行版现状矩阵

| 发行版 | 接力通道 | 状态 | 备注 |
|---|---|---|---|
| SLES 15 SP7+ / openSUSE Leap 15.5+ | NBFT 原生（dracut nvmf + nvme-cli） | ✅ 完整官方支持 | 引导网口 `nbft0/nbft1` 命名；`nvme nbft show` 查看 |
| RHEL 9.7+ / 10.x（Rocky/Alma/CentOS Stream 同源） | `nm-initrd-generator` NBFT 解析 | ⚠️ Technology Preview | 官方 9.7/10.2 release notes；限厂商平台（HII） |
| Fedora | dracut 95nvmf（`rd.nvmf.*`） | 🟡 参数驱动 | NBFT 消费未确认（SUSE 扩展为发行版补丁，dracut 已移交 dracut-ng 社区） |
| Ubuntu 24.04 LTS | subiquity + curtin（initramfs hook 脚本） | 🟡 experimental | rootfs 可远程但 /boot 必须本地；无 NBFT（需手动 connect） |
| Ubuntu 24.10+ | canonical/nvme-tcp-poc（dracut） | 🟡 PoC | Canonical 官方仓库 |
| Debian 12/13 | 无内置 | ❌ 空白 | initramfs-tools 无 nvmf 模块，需自备（见 §3.7.4） |
| Arch / Gentoo / Void | 无内置 | ❌ 空白 | 可自装 dracut + nvmf 模块 |
| Windows Server 2025+ | in-box NVMe-oF initiator（TCP+RDMA） | ✅ OS 层支持 | boot 层走 EFI Block I/O 暴露（§3.6），不依赖 NBFT |

#### 3.7.3 iSCSI（iBFT）参照系：Debian 系已走通

ipxe-all-ready 项目已在 Debian 12 验证 iBFT 全自动接力（`docs/zh/guide/exploration/debian-12-ibft.md` 第四章），是 NVMe-oF 接力的直接参照：

六环链路：`iPXE sanboot 写 iBFT → 内核 ISCSI_IBFT_FIND=y（内置）→ iscsi_ibft 模块导出 /sys/firmware/ibft/ → initramfs local-top/iscsi（ISCSI_AUTO 分支）→ iscsistart -b 建会话 → root=UUID 挂载`

- 内核无条件支持：`CONFIG_ISCSI_IBFT_FIND=y` 编进内核（非模块），表发现不依赖 initramfs。
- initramfs 官方开关：open-iscsi 打包自带 `local-top/iscsi` + `iscsi_auto` 内核参数（Debian/Ubuntu/Mint/Deepin 同源）；`iscsistart -b` 遍历固件表作兜底；initramfs 内无 iscsid，一切走 iscsistart。
- 母盘四步配方（克隆即用）：`open-iscsi` + 三模块（iscsi_tcp/ib_iser/iscsi_ibft）+ GRUB 参数（`ip=dhcp ipv6.disable=1 iscsi_auto`）+ `\EFI\BOOT\BOOTX64.EFI` 拷贝。
- 固件契约坑（0x7f22208e）：Debian 安装器不写 `\EFI\BOOT\BOOTX64.EFI`（只写 `\EFI\debian\grubx64.efi` + NVRAM 项），需从 `\EFI\debian\grubx64.efi` 复制——与 GRUB 验证（nvmeof-san-boot-verification.md）同款固件契约。
- 与 NBFT 的差距本质：iSCSI 有内核 `_FIND=y` + 发行版官方开关（十几年沉淀）；NVMe-oF 内核零支持 + 消费方 2023 年起才陆续落地。

#### 3.7.4 目标："母盘一次定制 + 克隆即用"

**充分条件**：固件生成合法 NBFT 表（身份来自固件，盘内零 per-worker 信息）+ 母盘内嵌通用 NBFT 消费组件。

| 发行版 | 现成消费组件 | 母盘定制量 | 克隆即用 |
|---|---|---|---|
| SLES 15 SP7+ / openSUSE Leap 15.5+ | ✅ dracut nvmf NBFT 扩展 | 零 | ✅ |
| RHEL 9.7+ / 10.x | ✅ nm-initrd-generator | 零 | ⚠️ TP |
| Fedora | ❓ 待验证 | 需验证/自备 | ❓ |
| Debian / Ubuntu / Arch | ❌ 无 | 一次注入 | ✅ 可达 |

**施工点（无内置支持的发行版）**：统一 NBFT 消费模块，路线 A（框架无关核心 + 薄适配层）。**种子定位**：实现仅供参考与上游提案，目标由各发行版官方包自行纳入（iBFT 先例：open-iscsi 包自带 `local-top/iscsi` + `iscsi_auto` 开关，Debian/Ubuntu/Mint/Deepin 同源继承，上游一处维护，发行版零自研）：

- **核心（一份，框架无关）** `nbft-connect`（POSIX sh）：检测 ACPI NBFT 表（`/sys/firmware/acpi/tables/NBFT`）→ 按 `nvme show-nbft` 输出翻译成 `ip=/ifname` 网络指令（对齐 SUSE dracut nvmf 模块做法）→ `nvme connect-nbft`。解析与连接已由 nvme-cli（跨发行版标准件）承担，核心只做框架无关的网络翻译与调用，单点维护。
- **薄适配层（各 10-20 行）**：
  - initramfs-tools：`hooks/nbft` + `scripts/local-top/nbft` + `nbft_auto` 内核参数（仿 `iscsi_auto`）
  - mkinitcpio：单个 hook
  - dracut 系不写适配：SUSE 95nvmf 原生 NBFT、RHEL nm-initrd-generator，种子只覆盖无内置的框架
- **上游纳入路径（发行版自己维护，种子退役）**：
  - 主路径：随 **nvme-cli（linux-nvme）** 打包 initramfs 集成（仿 open-iscsi 的 local-top/iscsi 模式，Debian 系同源继承）
  - 并行：SUSE dracut 95nvmf NBFT 补丁上游化到 dracut-ng（覆盖全部 dracut 发行版）
  - 种子验收标准：任一发行版官方包纳入后薄适配层退役，核心脚本并入官方包

至此"母盘一次定制 + 克隆即用"对各发行版全部可达：SLES/openSUSE、RHEL 装好即用（零定制）；Debian/Ubuntu/Arch 在官方纳入前由种子模块一次注入（克隆后 per-worker 零处理），官方纳入后母盘无需注入（装官方包即用，与 iSCSI 的 open-iscsi 一致）。

## 4. 代码结构设计

### 4.1 文件规划

```
src/net/tcp/nvmetcp.c          # 主实现：连接管理、PDU 收发、块设备接口、URI opener
src/include/ipxe/nvmetcp.h     # 协议结构：PDU 头、ICReq/ICResp、Connect、NVMe 命令结构
src/include/ipxe/nbft.h        # NBFT ACPI 表结构（照 NVMe Boot Spec / nm-initrd-generator 定义）
src/drivers/block/nbft.c       # NBFT 表生成（照 ibft.c 模式，含 UEFI ACPI 表安装）
src/config/general.h           # 新增 SANBOOT_PROTO_NVME_TCP（参照 SANBOOT_PROTO_ISCSI）
```

### 4.5 NBFT 生成

- 引导固件侧：`sanboot nvme:tcp://...` 成功后，从会话参数（HostNQN/SubNQN/地址/端口/传输类型）生成 NBFT 表，经 UEFI ACPI 表安装路径暴露（照 `ibft.c` 的 iBFT 安装模式）。
- 表格式以 NVMe Boot Specification 与 `nm-initrd-generator` 解析器为准（内核驱动层不消费，见 §3.5）。

### 4.6 EFI Block I/O 暴露（Windows 路径）

- 复用现有 `interface/efi/efi_block.c`：sanboot 挂盘后 NVMe/TCP 盘自动以 EFI 块设备呈现（与 iSCSI 一致），无需新增代码，仅验证覆盖。
- Linux 端从盘读内核：iPXE fs 层（块设备文件系统：ext2/fat 等）读 san 盘上 vmlinuz/initrd，与现有 embed 脚本体系兼容。

### 4.2 状态机

```
TCP 连接 → ICReq/ICResp → Connect(admin) → Identify(Ctrl+NS) → Connect(IO qid=1) → READY
```

`struct nvmetcp_session`：xfer socket 接口、会话状态、digest 开关、admin/IO 队列号、命名空间容量。

### 4.3 URI 与 sanboot

- URI 格式：`nvme:tcp://<host>[:port]/<subnqn>`（port 默认 4420）。
- 注册 `__uri_opener`；实现 `block_read` / `block_write` / `block_read_capacity` 并走 sanboot 通用路径（sanboot 通过 URI opener 分发，无需改 core/sanboot.c）。

### 4.4 构建与调试

- 经项目 `build.sh` 构建（固定 SOURCE_DATE_EPOCH）。
- 调试宏：`DEBUG=nvmetcp:3`（参照 iscsi 的 DEBUG 模式）。
- 配置：默认编入固件（与 SANBOOT_PROTO_ISCSI 并列），无需新增脚本改动。

## 5. 里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| M1 | 研究文档（本文件） | 文档评审通过 |
| M2 | 协议骨架：nvmetcp.h 结构 + TCP 连接 + ICReq/ICResp + Connect + Identify | 编译通过 |
| M3 | 数据通路：IO 队列 + READ + block 接口 + URI/sanboot 注册 | 编译通过，固件内可见符号 |
| M4 | NBFT 生成：表结构 + 会话参数填充 + UEFI 安装（照 ibft.c） | 编译通过，表结构符号可见 |
| M5 | 验证与文档：构建进固件、strings/objdump 检查、README/customizations 更新 | 构建产物含 NVMe/TCP 代码 |
## 6. 验证方案（编译级）

1. `bash build.sh` 产出固件。
2. `strings <firmware> | grep -i nvme` 确认代码进入固件。
3. `objdump -t` 确认关键符号（nvmetcp_open 等）。
4. 代码审查：与 TP 8000 / Linux nvme-tcp.c 逐项对照（补偿无实机验证）。

## 7. 风险与注意

- **协议复杂度**：digest、capsule 边界、R2T 流程是易错点 → M2/M3 分段落地，每段单独编译验证。
- **许可**：若参考 Linux `nvme-tcp.c`（GPL-2.0 only），补丁头部须声明 GPL-2.0 only（与 0004 补丁同类处理）；仅参考 iPXE 内部代码则沿用 `GPL2_OR_LATER_OR_UBDL`。
- **实机验证进展**：QEMU + nvmet 的 SAN 引导链路（nvmetcp → EFI BlockIo → PartitionDxe → FatDxe → GRUB 2.14）已于 2026-08-18 验证通过，详见 [nvmeof-san-boot-verification.md](nvmeof-san-boot-verification.md)；真实网卡 + NVMe SSD 主机侧的协议细节仍依赖规范对照与代码审查。
- **上游跟踪**：持续关注 ipxe/ipxe#556，若上游合入实现，评估替换为上游方案。

## 8. 引导机制源码级要点（参考阅读ipxe源码）

以下为现有引导机制全链路的源码实读结论（上游 master e6d0a97c0），是 NVMe/TCP 接入设计的事实基础。

### 8.1 全链路六层机制

1. **URI opener 分发**（core/open.c、include/ipxe/open.h）：`xfer_open_uri` → 解析 scheme → `xfer_uri_opener` 查表 → `opener->open(parent, uri)`；注册方式为链接段 `struct uri_opener xxx __uri_opener = { .scheme, .open }`。
2. **sanboot 设备管理**（core/sanboot.c）：`alloc_sandev(uris, count, priv_size)` 多路径；`register_sandev` 四步——reopen（xfer_open_uri 验证）→ ACPI 描述 → 读容量 → ISO9660 检测。`sanpath_open` 中 URI 打开成功后**自动 `acpi_describe(&sanpath->block)` + `acpi_add`**：协议实现 acpi_describe 操作即自动挂描述表，sanboot 层零改动。
3. **协议会话模板**（net/tcp/iscsi.c）：`iscsi_open` 解析 `uri->opaque` → `acpi_init(&iscsi->desc, &ibft_model)` → `xfer_open_named_socket(SOCK_STREAM)` → 挂块设备；socket ops 为 `xfer_deliver` / `xfer_window_changed` / `xfer_vredirect` / `intf_close`。
4. **ACPI 描述表**（drivers/block/ibft.c）：`struct acpi_model { descs, complete, install }` + `__acpi_model` 段；`install` 遍历会话描述符建表（控制/initiator/nic/target 块 + 字符串池 + ACPI 头）后交给 core/acpi.c 安装。
5. **EFI Block I/O 暴露**（interface/efi/efi_block.c）：`efi_block_hook` 内 `alloc_sandev(uris, count, priv=efi_block_data)` → `register_sandev` → `efi_describe(&sandev->active->block)`（协议提供 EFI device path）→ `InstallMultipleProtocolInterfaces(Block I/O + Device Path)` → `efi_connect`。**EFI 块设备暴露为 san 设备层自动获得**，协议侧只需实现 efi_describe（iSCSI 用 `EFI_INTF_OP(efi_describe, ..., efi_iscsi_path)`）。
6. **block 接口**（include/ipxe/blockdev.h、core/blockdev.c）：`block_read/write(control, data, lba, count, buffer, len)`（control 发命令、data 收数据）；`block_read_capacity` + `block_capacity` 回调（blocks/blksize/max_count）；协议 ops 模板见 ata.c（block_read/block_write/block_read_capacity/intf_close/edd_describe）。

构建开关：`SANBOOT_PROTO_*` 宏在 config/config.c 以 `#ifdef` 条件引用符号，需求驱动链接进固件。

### 8.2 NVMe/TCP 接入点映射（与 iSCSI 差异）

| iPXE 机制 | iSCSI 做法 | NVMe/TCP 做法 |
|---|---|---|
| URI opener | `iscsi` scheme | `nvme` scheme（nvmetcp_open） |
| 块设备 | 经 scsi_open（SCSI 命令集） | **直接实现 block ops**（NVMe 命令集，不走 SCSI 层——最大差异点） |
| ACPI 表 | `ibft_model` | `nbft_model`（照 ibft.c 模式新建） |
| EFI device path | `efi_iscsi_path`（iSCSI messaging path） | NVMe-oF messaging device path（UEFI 规范，实现时核对） |
| TCP 连接 | `xfer_open_named_socket` | 完全相同 |
| 构建 | config.c `#ifdef SANBOOT_PROTO_ISCSI` | 新增 `#ifdef SANBOOT_PROTO_NVME_TCP` |

结论：新增 net/tcp/nvmetcp.c（会话 + 块接口 + URI/EFI 描述）、include/ipxe/nvmetcp.h（协议结构）、drivers/block/nbft.c（NBFT 表）三个文件即可，sanboot / EFI block / ACPI 安装全链路零改动。

## 9. 参考资料

- NVM Express Base Specification 2.x
- NVM Express TCP Transport Specification (TP 8000)
- NVMe Boot Specification（NBFT 表格式）
- Linux内核源码 `linux-7.1.7/drivers/nvme/host/tcp.c`（协议实现参考，GPL-2.0）
- NetworkManager `nm-initrd-generator` NBFT 解析器（发行版消费方，表格式对照）
- [timberland-sig/suse-linux-poc](https://github.com/timberland-sig/suse-linux-poc)（SUSE NVMe-oF boot PoC：dracut nvmf NBFT 模块机制、nvme-cli show-nbft/connect-nbft）
- ipxe-all-ready `docs/zh/guide/exploration/debian-12-ibft.md`（iSCSI iBFT 接力参照：iscsi_auto 开关、母盘配方）
- [systemd/systemd#36443](https://github.com/systemd/systemd/issues/36443)（network-generator NBFT RFE，closed as not planned）
- iPXE `src/net/tcp/iscsi.c`（集成模板）、`src/drivers/block/ibft.c`（NBFT 生成模板）

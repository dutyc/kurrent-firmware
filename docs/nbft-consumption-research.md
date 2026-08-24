# 内核侧 NBFT 消费与认证现状研究（前置验证）

> 本文档仅中文。定位：为"iPXE 侧生成 NBFT"方案（补丁 0008 候选）做的前置验证记录——内核侧消费生态（libnvme / nvme-cli / dracut）对 NBFT 认证密钥的处理现状，以及方案路径修正。
> 所有结论均来自 `thirdparty/` 本地源码实证（`thirdparty/` 不入库，路径相对仓库根）。

## 1. 结论摘要

**"iPXE 写 KD 认证子表 → 内核自动认证"的链路在当前生态（nvme-cli + libnvme + dracut）不成立**：

1. NBFT 规范中 KD（Security Profile Descriptor）子表**本身不含明文密钥**，只有 `secret_type` + `sec_keypath_obj`（指向外部密钥存储的 URI 引用）——规范设计即"表内无密钥"
2. 内核侧各层**只解析不消费**认证信息：libnvme 能解析 security_list，但 `libnvmf_discover_nbft` 不传递任何 key；`nvme connect-all --nbft` 无认证密钥参数；dracut 95nvmf 无密钥处理
3. 因此 iPXE 侧生成 NBFT 的定位修正为：**注入网络拓扑与子系统信息（HFI+SS 子表）**；认证密钥走独立注入通道，由种子模块扩展逐条连接时附加
4. **整机引导可行性已由主仓库先例证明**：Kurrent 已在 iSCSI+iBFT 场景完整跑通"固件写表 → 内核/initramfs 消费 → 桌面环境启动"（见 3.5 节六环链路与母盘配方）；NVMe-oF+NBFT 链路与之一一对应，差异点（内核无 NBFT 表发现、表内无密钥）已实证并给出替代路径。该 NVMe-oF+NBFT 六环链路已由本仓库 QEMU 全链路实测闭环（2026-08-21，见 [nbft-boot-verification.md](nbft-boot-verification.md)）

## 2. 验证对象与证据链

### 2.1 表设计层：KD 子表无明文密钥（NVMe Boot Spec）

- 位置：`thirdparty/nvme-cli/libnvme/src/nvme/nvme-types-nbft.h:951-1008`
- KD 子表在 libnvme 中即 `struct nbft_security`（Security Profile Descriptor，Figure 23），关键字段：
  - `secret_type`：Secret Type（1 字节）
  - `sec_keypath_obj`：Secret Keypath Offset Heap Object Reference——指向 heap 中一个 **URI**，URI 类型由 Secret Type 指定（如 Redfish Key Collection Object）
- 解析行为：`libnvme/src/nvme/nbft.c:683-685` "The key URI also points into the heap. An absent URI is valid."——密钥以**路径引用**形式存在，表内无密钥本体
- 推论：KD/keypath 语义与"把 DHHC-1 密钥直塞进表"不兼容；即使 iPXE 生成合法 KD 子表，密钥也只能以 URI 引用形式表达，且下游无人读取

### 2.2 解析层：能解析，不消费

- `libnvme/src/nvme/nbft.c`：完整解析 Header/HFI/SS/Security 子表
- `thirdparty/nvme-cli/libnvme/tests/nbft/nbft-dump.c:65-74`：dump 工具可输出 `security_list`（index/flags/secret_type/sec_chan_algs）——证明解析能力存在，但仅测试用途

### 2.3 连接层：无密钥传递

- `libnvme/src/nvme/fabrics.c:3413-3418`：`libnvmf_discover_nbft` 相关路径仅处理 HFI 的 DHCP 服务器地址回退（`nbft_hfi->tcp_info.dhcp_server_ipaddr`）
- `libnvme/src/nvme/fabrics.c:3435-3450`：`libnvmf_nbft_read_files` 只做 NBFT 文件扫描读取
- 整个 discover 路径无 key/secret/dhchap/security 字段进入连接参数

### 2.4 命令行层：connect-all 无认证参数

- `thirdparty/nvme-cli/src/fabrics.c:795-830`：`connect-all` 完整参数表 = `device/raw/persistent/config/no-reuse/force/nbft/no-nbft/owner/nbft-path`——**无 dhchap-secret / hostkey / ctrlkey**
- 对照：单连接 `nvme connect` 支持认证参数（`src/fabrics.c:131-132`：`fa->hostkey` → `kxchap-secret`；`src/fabrics.c:580`：`fa->hostkey, fa->ctrlkey`）
- `nvmf-autoconnect/`（systemd/dracut-conf 配置）：无 dhchap/key 项

### 2.5 消费脚本层：dracut 不处理密钥

- `thirdparty/dracut/modules.d/95nvmf/`：dhchap/secret/key 零命中——SUSE 消费侧只做 `nvme connect-all --nbft` 网络/子系统连接，不涉及认证

## 3. 对 iPXE 侧生成 NBFT 方案的影响

| 原设想 | 实证修正 |
|---|---|
| 生成 Header+HFI+SS+KD 四类子表 | 生成 **HFI+SS**（网络拓扑+子系统信息）；**KD 无意义**（表内无密钥 + 下游无人读） |
| 密钥写进 KD 子表自动认证 | 密钥**不进表**——规避明文风险（规范本就不允许）；认证走独立通道 |
| 内核二次连接自动带认证 | 内核二次连接**需要种子模块扩展**才能带密钥 |

**积极面**：iPXE 生成表所需的全部数据现成（URI 参数 traddr/trsvcid/nqn + netdev 的 MAC/IP/DHCP 状态 + PCI 定位），HFI+SS 子表方案无新增数据依赖；且"密钥不进表"与现有"密钥不进固件镜像"原则一致，安全面更小。

### 3.5 主仓库 iBFT 先例参照（整机引导可行性）

主仓库（`thirdparty/ipxe-all-ready/docs/zh/guide/exploration/debian-12-ibft.md`）已在 **iSCSI + iBFT** 场景完整走通固件写表到整机启动的六环链路，**验证结论为系统正常进入、桌面环境正常启动**：

```text
① iPXE sanboot ──> 内存写入 iBFT 表
② 内核 ISCSI_IBFT_FIND=y ──> 引导早期发现表
③ iscsi_ibft 模块 ──> 导出 /sys/firmware/ibft/
④ initramfs local-top/iscsi（iscsi_auto 开关）──> iscsistart -N/-f/-b
⑤ 逐条建立会话
⑥ root=UUID ──> 挂载 rootfs，进入用户态
```

**母盘四步配方**（全部收敛进母盘，克隆即用、零 per-worker 定制）：

1. 安装 open-iscsi（提供 iscsistart 与 initramfs 集成脚本）
2. `/etc/initramfs-tools/modules` 注入 `iscsi_tcp`/`ib_iser`/`iscsi_ibft`
3. GRUB 参数追加 `ip=dhcp ipv6.disable=1 iscsi_auto`（`iscsi_auto` 是 open-iscsi 打包预留的官方隐藏开关，对齐本仓库种子模块的 `nbft_auto` 命名）
4. `update-grub` + `update-initramfs -u -k all`

**两个通用工程事实（NBFT 侧同样适用）**：

- **BOOTX64.EFI 固件契约**：iPXE sanboot 在 UEFI 下将盘交给固件后，固件走可移动介质引导路径，只认 ESP 分区 `\EFI\BOOT\BOOTX64.EFI`；Debian 安装器不写该文件（实测报错 `0x7f22208e`，官方注释明确"It is your system Firmware that fails"），须把 `grubx64.efi` 拷贝为 `BOOTX64.EFI`。本仓库 `test/make-grub-bootdisk.sh` 已遵守该契约（产物路径 `EFI/BOOT/BOOTX64.EFI`）
- **root=UUID/PARTUUID**：网络块设备拓扑漂移（会话建立时序/枚举顺序），fstab 与引导参数必须用 UUID/PARTUUID 标识根分区

**NVMe-oF/NBFT 与 iSCSI/iBFT 的差异（实证）**：

| 环节 | iSCSI/iBFT | NVMe-oF/NBFT |
|---|---|---|
| 表发现 | 内核级 `ISCSI_IBFT_FIND=y`（编进内核，无条件） | **内核无 NBFT 表发现**（`thirdparty/kernel` 的 linux-master/linux-v6.12/linux-7.1.7 均无 NBFT 代码）；表经内核 ACPI 子系统通用导出 `/sys/firmware/acpi/tables/NBFT`（XSDT 内表自动导出，无需 nvme 驱动特殊支持） |
| initramfs 消费 | open-iscsi 自带 `local-top/iscsi`（iscsi_auto 官方开关） | 种子模块（`nbft_auto`，对齐命名）+ nvme-cli（initramfs 需打包 nvme-cli + libnvme） |
| 认证凭据 | **iBFT 表内含 CHAP 凭据** → 六环可自动认证 | **NBFT 表无密钥**（KD 为 keypath 引用，见 2.1）→ 认证必须走独立通道（第 4 节路径 B） |

## 4. 可行路径

| 路径 | 内容 | 认证支持 | 工作量 |
|---|---|---|---|
| **A. 无认证直连** | iPXE 生成 HFI+SS 表 → `connect-all --nbft` 重连 | 无（要求子系统 `attr_allow_any_host=1`，与认证目标矛盾） | 小：种子模块消费链路验证 |
| **B. 种子模块扩展**（推荐） | iPXE 生成 HFI+SS 表；密钥经**独立注入通道**（内核 cmdline / initramfs 配置文件）进 initramfs；种子模块对每个发现项**逐条 `nvme connect`**（该命令支持 hostkey/ctrlkey，见 2.4）附加密钥 | 有（DH-HMAC-CHAP） | 中：种子模块改造 + 密钥注入通道 |
| **C. 上游扩展** | 向 nvme-cli/libnvme 提案 `connect-all --nbft` 消费 KD keypath（Redfish Key Collection 对接） | 有（需 Redfish 生态） | 长期，超出本仓库范围 |

路径 B 的密钥来源可复用现有控制面体系（`/boot-vars` 按客户端下发），与固件层凭证链同源。

## 5. 落地顺序建议（总验收标准：系统引导启动成功）

> **总验收标准**：注入 NBFT 后系统必须**完整引导启动**（内核启动 → initramfs 消费 NBFT 连接 → rootfs 挂载 → switch_root 进入系统），而非仅验证"表注入成功"。
> 现状边界：已有验证仅到"GRUB 引导程序从 SAN 盘启动"（见 [nvmeof-san-boot-verification.md](nvmeof-san-boot-verification.md)——GRUB 菜单为 echo/ls/sleep 验证入口，无真实内核）。**内核启动与 rootfs 挂载环节从未验证**，属于本方案的必补环节。
> 可行性参照：主仓库 iBFT 六环链路已验证到桌面启动（3.5 节），NVMe 侧按同构链路映射实施。
> **无状态盘原则（本方案硬约束）**：盘内**禁止任何身份硬编码**——target 地址/端口/NQN、认证密钥、机器标识（MAC/主机名）、控制面地址均不得入盘；身份全部由启动链外部注入（NBFT 表由固件生成、密钥与引导参数由控制面下发）。盘内只允许通用载荷与盘自身固有属性（见下方清单）。

**无状态盘允许/禁止清单**：

| | 内容 | 说明 |
|---|---|---|
| ✅ 盘内允许 | 通用内核、initrd（含种子模块）、GRUB 引导器 | 与机器无关的载荷 |
| ✅ 盘内允许 | root 分区标识（UUID/PARTUUID） | 盘的**固有属性**（克隆不变，非机器身份；与主仓库 iBFT 先例 root=UUID 一致） |
| ❌ 盘内禁止 | target 地址/端口/NQN | 由 NBFT 表注入（六环 ①~④） |
| ❌ 盘内禁止 | 认证密钥 | 启动时动态注入（见下方密钥通道约束）；**不得写入 initramfs 配置文件或盘上 grub.cfg** |
| ❌ 盘内禁止 | 机器标识、控制面地址 | 由 DHCP/控制面下发（盘上 grub.cfg 仅可引用 DHCP 提供的 `${net_default_server}` 等动态变量） |

**密钥通道约束**：密钥载体必须在盘外、注入发生在启动时——候选：① 控制面下发的 grub.cfg 模板（`linux` 行带密钥参数；盘上仅留最小引导 stub：DHCP 后从 `${net_default_server}` 拉取 grub.cfg）；② initramfs 启动时从控制面拉取（网络就绪后 HTTP）。两种通道均满足"每次启动重新下发、可轮换、盘内零密钥"。

**NBFT 六环链路（目标形态，与 iBFT 同构）**：

```text
① iPXE sanboot（NVMe-oF）──> 生成并安装 NBFT ACPI 表（EFI_ACPI_TABLE_PROTOCOL）
② 内核 ACPI 子系统 ──> 通用导出 /sys/firmware/acpi/tables/NBFT（无内核级表发现，见 3.5 差异表）
③ initramfs 种子模块（nbft_auto）──> nvme nbft show -o json 解析
④ nvme connect-all --nbft ──> 建立会话（认证场景：逐条 connect + 密钥通道）
⑤ 盘出现 ──> root=PARTUUID 识别
⑥ 挂载 rootfs ──> switch_root ──> 系统启动成功
```

1. **无认证整机引导**（六环 ①~⑥ 的骨架，外部注入表）：
   - 母盘改造（对齐 3.5 母盘配方）：`test/make-grub-bootdisk.sh` 的 GRUB 菜单从验证入口改为**真实引导**（`linux` / `initrd` / `root=PARTUUID`）；SAN 盘装入最小系统（内核 + initrd + rootfs）；GRUB 参数 `ip=dhcp nbft_auto`；initramfs 含 nvme-cli 与种子模块；确认 BOOTX64.EFI 契约
   - QEMU 外部注入手工 NBFT（HFI+SS）→ 内核 ACPI 导出 → 种子模块消费 → `connect-all --nbft` → rootfs 挂载 → **系统启动成功**
2. **认证补齐**（路径 B）：种子模块改为逐条 `nvme connect` + 密钥注入通道（内核 cmdline / initramfs 配置，密钥与 `/boot-vars` 控制面同源）；同一验收标准（认证场景整机引导成功）
3. **iPXE 侧生成表**（补丁 0008 候选）：`include/ipxe/nbft.h` + `drivers/block/nbft.c`（对齐上游 iBFT 的 `ibft.c`/`acpi_init` 描述符机制）+ nvmetcp 会话 READY 后挂接 + 单测；验收改为**不经外部注入、iPXE 生成表后整机引导成功**

**关键依赖与风险**：

- `root=PARTUUID` 依赖 backing 文件分区布局固定（母盘一次制作，克隆即用——与种子模块 README 的母盘定位一致）
- initramfs 内需包含 nvme-cli 与种子模块组件（母盘安装步骤已覆盖；比对 open-iscsi 打包的 `iscsistart` 先例，nvme-cli 体积较大，需评估 initramfs 打包方式）
- 引导时序：iPXE 连接与内核二次连接是两次独立连接（同 iBFT/iSCSI 模型），盘上文件系统状态不受影响
- 内核 ACPI 导出前提：iPXE 经 `EFI_ACPI_TABLE_PROTOCOL` 安装的表必须进入 XSDT，内核才能导出到 `/sys/firmware/acpi/tables/`（实施时在 QEMU 中先验证此点，iBFT 不依赖 XSDT、机制不同，不可直接照搬）

## 6. 相关文档

| 文档 | 定位 |
|---|---|
| [nvmeof-research.md](nvmeof-research.md) | NVMe-oF 协议研究（固件驱动侧） |
| [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md) | 认证排障全历程（固件侧） |
| [capability-reference.md](capability-reference.md) | 能力实现参考（4.8 节：内核 NBFT 路径缺口） |
| `initramfs-nbft/README.md` | NBFT 消费种子模块（本研究的消费侧对象） |

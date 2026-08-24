# 固件能力实现参考（Kurrent 集成用）

> 本文档仅中文。服务对象：主仓库 Kurrent（算力层无状态运转）的开发者与集成者。
> 本仓库 kurrent-firmware 是 Kurrent 引导链最底层的**固件底座**：两仓库语义一致、职责严格分离（固件构建 vs 算力无状态运转）。
> 本文档描述固件层已实现能力的**实现方式与接口契约**，重点是 **NVMe-oF 认证凭证传入链路**（第 4 章）。使用层面的操作步骤见 [nvmeof-usage.md](nvmeof-usage.md)。

## 1. 能力总览与仓库职责

### 1.1 职责边界

| 仓库 | 职责 | 交付物 |
|---|---|---|
| **Kurrent**（主仓库） | 算力层无状态运转：控制面、动态变量链、身份注入、节点注册、盘机解耦、NBFT 消费 | 控制面服务、引导链脚本（boot.ipxe 等）、initramfs 集成 |
| **kurrent-firmware**（本仓库，固件底座） | 固件构建与定制：协议驱动、认证、设备信息采集、网卡适配 | `dist/` 固件产物、`patches/` 补丁链、`test/` 测试脚本 |

接口边界：主仓库通过 **DHCP/TFTP/HTTP 控制面**与固件交互——引导链脚本由控制面下发，身份与凭据经控制面端点注入（见第 4 章），设备信息由固件采集上报。

### 1.2 固件层能力清单

| # | 能力 | 实现位置 | 状态 |
|---|---|---|---|
| 1 | NVMe over TCP SAN 引导（nvmetcp 驱动，8 阶段状态机） | 补丁 0006 | 已验证（QEMU/OVMF + nvmet 7.0 + GRUB 2.14 全链路） |
| 2 | DH-HMAC-CHAP 认证（含状态机竞态修复） | 补丁 0006/0007 | 已验证（ATR 路径 wire 证据 + 单测覆盖） |
| 3 | 认证凭证控制面注入（`nbft-secret` 动态变量） | `embed/auto.ipxe` + 控制面 `/boot-vars` 端点 | 已验证（test/ 全链路脚本） |
| 4 | 设备信息采集（SMBIOS 内存、PCI 驱动名 → `${net0/chip}` 等） | 补丁 0005 | 已验证 |
| 5 | 网卡适配（RTL8125/8126 驱动、snponly 接管回退、UNDI） | 补丁 0001-0004 | 已验证 |
| 6 | 多形态固件产物（PXE-UEFI/直接 UEFI/BIOS/USB） | `build/build.sh` → `dist/` | 可复现构建 |
| 7 | 测试体系（单测 11625 断言、QEMU 全链路、pcap 分析） | `tests/`（补丁内）、`test/` 目录 | 回归护栏 |

## 2. 引导链与接口边界

### 2.1 固件侧引导链（`embed/auto.ipxe`）

```ipxe
#!ipxe
dhcp || goto failed
chain --autofree tftp://${next-server}/boot.ipxe || goto failed   # 进入主仓库引导链
exit
:failed
shell
```

- `next-server` 由 DHCP 提供，同机部署时即控制面 IP
- `boot.ipxe` 及后续（`boot.ipxe.cfg`、`menu.ipxe`）由**主仓库控制面**托管，固件不内嵌业务脚本
- 认证测试固件内嵌脚本见 `test/nvmeof-auth-test.ipxe`（直接 `chain http://<控制面>/boot-vars` → `sanboot`）

### 2.2 固件层接口点（主仓库需要实现的契约）

| 接口 | 方向 | 用途 |
|---|---|---|
| DHCP（next-server） | 控制面 → 固件 | 定位引导链服务器 |
| TFTP `/boot.ipxe` | 控制面 → 固件 | 引导链入口脚本 |
| HTTP `/boot-vars?mac=...&hostname=...` | 固件 → 控制面 | **动态变量注入（含认证凭据）**，响应为 iPXE 脚本体 |
| HTTP 设备信息上报 | 固件 → 控制面 | 设备信息采集（补丁 0005，见 5.1） |
| `nvme://` SAN URI | 固件内部 | `sanboot` 入口（含 `?secret=` 认证参数） |

**动态变量链在固件层的形态**：主仓库的"控制面经动态变量链注入真实身份"在固件层落地为 `chain --autofree http://.../boot-vars?...` → 响应体（`#!ipxe` 脚本）执行 `set <变量> <值>` → 后续脚本引用 `${<变量>}`。变量在**每次启动时重新拉取**，不固化在固件镜像中。

## 3. NVMe-oF 能力实现参考（驱动层）

### 3.1 会话状态机（8 阶段）

```
ICREQ → CONNECT_ADMIN → AUTH → PROP_SET → IDENTIFY_CTRL → IDENTIFY_NS
      → ICREQ_IO → CONNECT_IO → READY（任一阶段失败 → FAILED）
```

| 阶段 | 动作 | 说明 |
|---|---|---|
| ICREQ | 参数协商（PFV/最大 PDU 等） | 128 字节 ICReq/ICResp |
| CONNECT_ADMIN | Connect 命令（fctype=0x01，Admin 队列） | 完成时识别认证要求（见 4.2） |
| AUTH | DH-HMAC-CHAP 四消息（见 3.3） | 认证子状态机（5 步） |
| PROP_SET | Property Set（CC 寄存器，CC.EN=1） | **必须等认证完全收尾**，否则 Identify 被 `0x8018` 拒绝 |
| IDENTIFY_CTRL/NS | 识别控制器与命名空间 | 解析 LBAF 计算块大小/容量（512B/4K） |
| ICREQ_IO/CONNECT_IO | I/O 队列连接 | 建立后进入 READY |
| READY | 块读写（R2T 流控） | 对 sanboot/BlockIo 提供服务 |

### 3.2 认证子状态机与关键修复点（补丁 0007）

认证子状态机 5 步：`START → COMPLETE_NEGOTIATE → CHALLENGE → COMPLETE_REPLY → SUCCESS1 → START`。

排障中发现并修复的三个 bug（wire 证据见 [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md)）：

1. **瞬态 `-EAGAIN` 杀掉会话**：TCP 窗口关闭时发送失败即关会话 → 改为等待窗口恢复后重试（`tx_in_flight` 门控，防重复发送）
2. **AuthReceive 重复发送**：窗口重试路径与正常推进路径重叠 → 发送幂等 + step 统一推进
3. **认证完成竞态（0x8018）**：Success1 数据与最终 AuthReceive 完成可能乱序到达（同一 TCP 段内），仅凭 step 会把 Reply 的完成误判为 AuthReceive 完成，导致 Property Set 被跳过、Identify 被 `0x8018` 拒绝 → **双标志门控**（`completed` + `rx_complete`）+ **命令 id 匹配**（`rx_cid`），两者齐备才推进到 PROP_SET

单测覆盖（`tests/nvmetcp_test.c`，随补丁 0007 交付）：阶段完成门控、命令 id 匹配、START 步守卫，全量 11625 断言通过。

### 3.3 认证消息流程（DH-HMAC-CHAP，四消息）

fabric 命令 `fctype=0x05`（AuthSend）/`0x06`（AuthReceive），协商消息：

| 消息 | AuthSend 载荷 | 内容 |
|---|---|---|
| 1. Negotiate | `nvmf_auth_dhchap_negotiate_data` | 哈希（SHA-256=01）、DH 群（0/2048/3072/4096）、transaction 随机数 |
| 2. Challenge | `nvmf_auth_dhchap_challenge_data` | 16 字节 cval、服务端 DH 公钥 |
| 3. Reply | `nvmf_auth_dhchap_reply_data` | 客户端 DH 公钥 + 响应 rval |
| 4. Success1 | `nvmf_auth_dhchap_success1_data` | 服务端校验（hl/rvalid 字段） |

- 双向认证（`rvalid=1`）**不支持**，收到即报 `-EPROTO`
- 哈希仅 SHA-256；DH 群 0（无 DH）/2048/3072/4096（服务端可配 `ffdhe4096` 走完整 DH 交换）
- 失败路径：任一校验失败返回错误码，会话进入 FAILED

### 3.4 BlockIo 与 EFI 设备路径（sanboot 协议）

- 驱动实现 EFI 设备路径描述与 BlockIo 钩接，`sanboot` 命令将 SAN 盘挂为可引导设备
- 认证测试固件：`sanboot nvme://<traddr>:<trsvcid>/<nqn>?secret=...`，成功后控制权交给盘上引导程序（GRUB 2.14 验证：`== GRUB BOOTED FROM NVME/TCP SAN DISK ==`）
- 失败时固件回落 iPXE shell（`sanboot rc = ${?}` 可观察）

### 3.5 驱动层限制

- 仅 TCP 传输（无 RDMA/FC）
- 单控制器单命名空间引导路径
- 无编译期默认调试输出；需 `DEBUG=nvmetcp,nvmetcp_auth:3` 构建（`DEBUG=` 按源文件名生效，仅 `nvmetcp` 看不到 auth 打印）

## 4. 认证凭证传入链路（核心）

> 本章是主仓库集成时**必须完全对齐**的部分：密钥格式、触发机制、注入方式、端点契约、主机身份匹配。固件侧已全部验证；主仓库需要实现的是控制面 `/boot-vars` 端点与引导链脚本。

### 4.1 凭证形态：DHHC-1 密钥格式

**格式**：`DHHC-1:XX:<base64(key + CRC32)>`

| 段 | 规则 | 违反后果（实测） |
|---|---|---|
| 前缀 `DHHC-1:` | 固定 7 字符 | — |
| 类型 `XX` | **必须两位数字**（`01`=SHA-256）；内核两侧硬编码跳过 10 字节前缀 | 一位数 → 截断首个 base64 字符 → `base64 key decoding error -1` |
| `base64(key+CRC32)` | 32 字节密钥 + **CRC-32 终值**（`zlib.crc32`，含 final XOR）小端 4 字节；解码总长 36（或 68 字节密钥） | CRC 非终值 → `Failed to setup authentication, dhchap status 2` |

**生成命令**：

```bash
python3 -c 'import zlib,base64; k=b"0123456789abcdef0123456789abcdef"; \
print("DHHC-1:01:"+base64.b64encode(k+zlib.crc32(k).to_bytes(4,"little")).decode())'
```

**自检**：`test/nvmet-setup.sh` / `test/cred-server.py` / `test/nvme-host-diagnose.sh` 均内置同一自检（前缀长度 + 解码长度 + CRC32 终值校验），配置阶段即失败而非运行时暴露。主仓库实现密钥下发时应复用该自检逻辑。

### 4.2 认证触发机制（固件侧识别）

服务端要求认证时，iPXE 从 Connect 完成中识别，**两种形态均支持**：

| 形态 | 证据 | 说明 |
|---|---|---|
| **ATR 位**（主路径） | Connect 响应 `result` 字段 bit 17 置位 | nvmet 7.0.0-14 实测：`status=0x0000, result=0x00020001`（pcap 证据） |
| **状态码**（兼容路径） | Connect 完成状态 `0x0c`（`NVME_SC_AUTH_REQUIRED`）且无 ATR | 补丁 0007 新增兼容分支 |

识别到认证要求但无 `secret` 参数 → 报 `authentication required but no secret` 并拒绝引导。**触发识别与密钥是否传入是两个独立环节**：密钥传入方式见 4.3/4.4。

### 4.3 传入方式 A：URI `?secret=` 参数（直接）

**URI 完整格式**：

```text
sanboot nvme://<服务器地址>:<端口>/<子系统NQN>?secret=<DHHC-1 key>
```

**三个真实示例**（来自 `test/nvmeof-test.ipxe` / `nvmeof-auth-test.ipxe`）：

```ipxe
# 1. 无认证
sanboot nvme://10.0.2.2:4420/nqn.2026-08.org.ipxe-stateless:test

# 2. 带认证（密钥直接写在 URI 里）
sanboot nvme://10.0.2.2:4420/nqn.2026-08.org.ipxe-stateless:test?secret=DHHC-1:01:MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYOtVl3

# 3. 带认证（推荐：密钥由控制面下发，脚本里用变量引用）
dhcp
chain --autofree http://10.0.2.2:8000/boot-vars?mac=${mac}&hostname=ipxe-auth-test
sanboot nvme://10.0.2.2:4420/nqn.2026-08.org.ipxe-stateless:test?secret=${nbft-secret}
```

**逐段拆解**：

| 段 | 示例 | 说明 |
|---|---|---|
| 协议头 | `nvme://` | 固定写法 |
| 服务器地址 | `10.0.2.2` | 存储服务器 IP（QEMU 虚拟机内 `10.0.2.2` 即宿主机；真实网络填服务器地址） |
| 端口 | `4420` | NVMe/TCP 标准端口 |
| 子系统 NQN | `nqn.2026-08.org.ipxe-stateless:test` | 门牌号，必须与服务端 configfs 创建的 NQN 完全一致 |
| `?secret=` | `DHHC-1:01:...` | 可选；服务端要求认证时必须带，否则报 `authentication required but no secret` 拒绝引导 |

**注意事项**：

- `?` 前不能有空格；`secret=` 后直接跟密钥，密钥内的 `:` 与 base64 字符无需转义
- 交互式 shell 可直接输入：`iPXE> sanboot nvme://10.0.2.2:4420/nqn.2026-08.org.ipxe-stateless:test?secret=...`
- 方式 A 的密钥会出现在脚本/菜单/日志可见范围，生产环境优先方式 B（4.4 控制面注入）
- 固件侧 URI 解析实现：`nvmetcp.c` 的 `nvmetcp_parse_secret()`（解析 `secret=` 查询参数存入 session）

### 4.4 传入方式 B：控制面 `/boot-vars` 注入（推荐，完整时序）

**设计原则**：密钥**不进固件镜像**、**不进引导菜单**，由控制面按客户端 MAC/主机名在下发引导脚本时动态注入，每次启动重新拉取。

**时序**：

```text
1. 固件 DHCP（拿到 next-server = 控制面）
2. 固件 chain http://<控制面>:8000/boot-vars?mac=${mac}&hostname=${hostname}
3. 控制面按客户端身份查密钥，返回 iPXE 脚本体：
     #!ipxe
     # credentials for mac=...&hostname=...
     set nbft-secret DHHC-1:01:...
4. 固件执行脚本体 → 变量 nbft-secret 就绪
5. 固件执行 sanboot nvme://...?secret=${nbft-secret}
6. 认证四消息完成 → PROP_SET → Identify → I/O 队列 → 盘上引导程序
```

**固件侧脚本形态**（`test/nvmeof-auth-test.ipxe`，可嵌入主仓库引导链）：

```ipxe
#!ipxe
dhcp || goto failed
chain --autofree http://10.0.2.2:8000/boot-vars?mac=${mac}&hostname=${hostname} \
  && echo CRED-FETCH-OK || goto cred-failed
sanboot nvme://10.0.2.2:4420/nqn.2026-08.org.ipxe-stateless:test?secret=${nbft-secret}
:cred-failed
shell
```

**凭据生命周期**：
- 注入发生在引导链执行期（`chain --autofree` 拉取，执行后自动释放）
- 变量仅在本次引导会话有效；固件重启后重新走 DHCP → 拉取流程
- 密钥轮换：控制面更新端点返回即可，**固件与服务端 configfs 无需重构建**（服务端密钥写入由 `nvmet-setup.sh` 管理）

### 4.5 控制面端点契约（`/boot-vars`）

主仓库需实现的端点（参考实现：`test/cred-server.py`，仅验证用）：

| 项 | 契约 |
|---|---|
| 请求 | `GET /boot-vars?mac=<MAC>&hostname=<主机名>`（可扩展附加查询参数） |
| 响应头 | `Content-Type: text/plain`，`Content-Length` 正确 |
| 响应体 | `#!ipxe` 脚本体：`set nbft-secret <DHHC-1 key>`（可含多条 `set`，即动态变量链） |
| 错误处理 | 未知客户端 → 非 200（如 404/403），固件侧 `chain` 失败进入 `:cred-failed` 分支落 shell |
| 凭据匹配 | 按 MAC/hostname 查找该客户端应得的密钥（测试端点固定返回） |

**安全边界**（重要）：
- 测试端点明文 HTTP，仅限验证环境（`test/cred-server.py` 头部有说明）
- **生产环境该端点必须置于强认证之后**（TLS/mTLS + 客户端身份校验）——密钥经网络传输，固件侧无额外加密层，端点本身是唯一信任边界
- 建议主仓库将该端点与既有控制面身份体系合并（同一 TLS 通道、同一客户端注册表）

### 4.6 密钥一致性与管理

密钥在**三个地方各自硬编码，必须完全一致**：

| 位置 | 角色 | 说明 |
|---|---|---|
| `test/nvmet-setup.sh`（`DHHCP_KEY`） | 写入服务端 configfs | `hosts/<HOSTNQN>/dhchap_key` |
| `test/cred-server.py`（`SECRET`） | 下发给固件 | `/boot-vars` 响应体 |
| `test/nvme-host-diagnose.sh`（`KEY`） | 主机侧直连验证 | nvme-cli `--dhchap-secret` |

主仓库侧对应关系：服务端密钥配置（对应 1）+ 控制面端点密钥库（对应 2）。**密钥轮换流程**：两端（configfs + 控制面）同步更新，客户端无需任何变更（每次启动重新拉取）。所有脚本内置自检，修改后先跑 `bash test/nvmet-setup.sh` 的自检确认。

### 4.7 主机身份匹配（Host NQN）

- 固件 Host NQN 构造（`nvmetcp.c` 实证）：前缀固定 `nqn.2014-08.org.ipxe:`
  - **有 SMBIOS UUID**：`nqn.2014-08.org.ipxe:<uuid>`（`uuid_ntoa` 格式，带连字符）
  - **无 UUID**（QEMU+OVMF 实测）：回退固定 `nqn.2014-08.org.ipxe:ipxe`
- 服务端 configfs：`hosts/<HOSTNQN>/` 目录名必须与客户端实际发送一致，否则认证不生效/拒绝
- 主仓库集成注意：真实硬件（有 SMBIOS UUID）的 NQN 是每机唯一的——控制面应能按机器身份下发对应的密钥；`hosts/` 按 UUID 维度管理

### 4.8 内核态 NBFT 路径现状与缺口

主仓库生态存在两条 NVMe-oF 路径：

| 路径 | 组件 | 认证凭证处理 |
|---|---|---|
| **固件层**（iPXE sanboot） | 本仓库补丁 0006/0007 + 控制面 `/boot-vars` | **已闭环**（本章全部内容） |
| **内核层**（NBFT 消费） | `initramfs-nbft/` 种子模块（`nbft-connect` + hooks/local-top，`nbft_auto` 自动消费，`nvme connect-all --nbft`） | **未覆盖**：nbft-connect 无 dhchap 密钥处理逻辑 |

内核路径的认证密钥注入（NBFT 表内 key 字段或引导参数注入）**待主仓库设计与上游对齐**（SUSE dracut 95nvmf / nvme-cli autoconnect 生态）；固件层路径可作为主仓库的已验证参照实现。

### 4.9 完整时序图（认证链路，wire 视角）

```text
iPXE                                     nvmet(TCP:4420)         控制面(:8000)
  |  DHCP                                    |                       |
  |----------------------------------------->|                       |
  |  chain http://10.0.2.2:8000/boot-vars    |                       |
  |-------------------------------------------------------->|        |
  |  #!ipxe / set nbft-secret DHHC-1:01:...  |                       |
  |<--------------------------------------------------------|        |
  |  ICReq/ICResp                            |                       |
  |  CMD cid=1 Connect                       |                       |
  |<-- RSP status=0x0 result=0x00020001(ATR) |                       |
  |  AuthSend(Negotiate) / AuthReceive(Challenge)                   |
  |  AuthSend(Reply) / AuthReceive(Success1)                        |
  |  CMD cid=7 PropSet (CC.EN=1)             |                       |
  |<-- RSP status=0x0                        |                       |
  |  Identify(Controller/NS) → I/O 队列      |                       |
  |  sanboot 成功 → 盘上 GRUB                |                       |
```

## 5. 其他能力实现参考

### 5.1 设备信息采集（补丁 0005）

- SMBIOS type 17 内存设置：`mem-total`（全插槽聚合）、`mem-type`/`mem-speed`（首槽）
- PCI `driver_name` 填充：`${net0/chip}` 输出设备表名（如 `RTL8125`）
- 用途：主仓库动态变量链的设备侧数据源、节点注册信息。详细清单见 [device-info-reporting.zh-CN.md](device-info-reporting.zh-CN.md)

### 5.2 网卡适配（补丁 0001-0004）

- RTL8125（2.5GbE）与 RTL8126（5GbE，ICVerID 检测 + PHY 配置分派）驱动定制
- `snponly.efi`：链加载失败时回退接管全部 SNP/NII/MNP 设备（补丁 0003）
- 支持矩阵见 [network-support.zh-CN.md](network-support.zh-CN.md)

### 5.3 构建与部署

- 补丁链 `0001-0007`（基线 `e6e51ccb`），`build/build.sh` 每次重置工作树后按序应用，产物入 `dist/`（SHA256SUMS）
- 产物形态：`pxe-uefi/*.efi`、`direct-uefi/*.efi`（内置 auto.ipxe）、`grub-bios/ipxe.lkrn`、`undionly.kpxe`、`usb/ipxe.usb`、`*-debug.efi`
- 调试构建：`DEBUG=nvmetcp,nvmetcp_auth:3`（认证日志）、`DEBUG=realtek:3`（网卡）
- `embed/auto.ipxe` 是配置资产（非源码补丁），修改无需重新生成补丁

## 6. 验证与测试参考（主仓库可复用）

| 手段 | 命令/位置 | 验证内容 |
|---|---|---|
| 单元测试 | `make -C .cache/ipxe-upstream/src bin-x86_64-linux/tests.linux` → 运行 | 全量 11625 断言（含认证状态机） |
| 目标端配置 | `sudo [AUTH=1] bash test/nvmet-setup.sh` | 幂等、密钥自检、`==> LISTENING on 4420` |
| 凭证端点 | `python3 test/cred-server.py` | `/boot-vars` 注入 |
| 引导盘 | `bash test/make-grub-bootdisk.sh` | 可引导 NVMe/TCP 后端盘 |
| QEMU 轮次 | `bash test/run-qemu-auth.sh [round]`（沙箱外） | 全链路日志 `diag/qemu-<round>.log` + 抓包 |
| pcap 分析 | `python3 test/parse-pcap-auth.py` / `-stream.py` | wire 证据链：ATR、认证四消息、全程无 0x8018 |

完整流程见 [nvmeof-test-procedure.md](nvmeof-test-procedure.md)。日志证据链：

```text
sending Connect (qid 0) → completion: cid 1 status 0x0
authentication required → sent Negotiate → authentication succeeded
sending Property Set (CC) → namespace 1: N blocks of 4096 bytes
I/O queue established → == GRUB BOOTED FROM NVME/TCP SAN DISK ==
```

## 7. 集成检查清单（主仓库侧）

- [ ] 控制面实现 `GET /boot-vars?mac=&hostname=`，返回 `#!ipxe` 脚本体（`set nbft-secret ...`），生产环境置于 TLS/mTLS 之后
- [ ] 引导链脚本（boot.ipxe 链）在 `sanboot` 前先 `chain` `/boot-vars` 拉取变量，`sanboot` 使用 `${nbft-secret}`
- [ ] 密钥库与 `nvmet-setup.sh` 的 `DHHCP_KEY` 一致；格式 `DHHC-1:XX:`（两位类型）+ CRC32 终值小端；复用自检逻辑
- [ ] 服务端 `hosts/<HostNQN>/` 与客户端实际 NQN 匹配（SMBIOS UUID 或回退 NQN）
- [ ] 固件包含完整补丁链 0001-0007（缺 0007 时认证流程会跳过 Property Set 导致 `0x8018`）
- [ ] 认证链路验证：QEMU 轮次 + pcap 证据链（第 6 章）
- [ ] 内核 NBFT 路径（initramfs-nbft）的认证密钥注入按 4.8 缺口规划

## 8. 相关文档索引

| 文档 | 定位 |
|---|---|
| [nvmeof-usage.md](nvmeof-usage.md) | 使用指南（服务端配置、sanboot 用法、QEMU 验证） |
| [nvmeof-test-procedure.md](nvmeof-test-procedure.md) | test/ 脚本完整测试流程 |
| [customizations.zh-CN.md](customizations.zh-CN.md) | 补丁 0005/0006/0007 设计与实现 |
| [device-trust-usage.md](device-trust-usage.md) | 设备信任根能力使用说明（0008-0010：keygen/pubkey/sign、TOFU、NVRAM 设置） |
| [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md) | 认证排障全历程（0x8018 根因、wire 证据） |
| [nvmeof-research.md](nvmeof-research.md) | 协议研究与设计 |
| [nvmeof-san-boot-verification.md](nvmeof-san-boot-verification.md) | 无认证 SAN 引导验证记录 |
| `initramfs-nbft/README.md` | NBFT 消费种子模块（内核路径） |
| [patches/README.md](../patches/README.md) | 补丁链、授权（NVMe 驱动文件 GPL-2.0 only）、升级流程 |

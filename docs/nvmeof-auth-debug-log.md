# NVMe/TCP DH-HMAC-CHAP 认证排障日志（QEMU + nvmet）

> 状态：**已闭环**（2026-08-19）。认证 → Property Set → Identify → I/O 队列 → SAN 引导全链路在 QEMU + Linux nvmet（Ubuntu 26.04，内核 7.0）环境验证通过。
>
> 关联文档：[nvmeof-research.md](nvmeof-research.md)（协议研究与设计）、[nvmeof-san-boot-verification.md](nvmeof-san-boot-verification.md)（无认证 SAN 引导验证）。
> 本文件记录认证排障的完整过程，供日后遇到类似状态机竞态时参考。

## 1. 目标与链路

在 iPXE 自研 `nvmetcp` 驱动（`src/net/tcp/nvmetcp.c` + `nvmetcp_auth.c`）中调通 NVMe/TCP DH-HMAC-CHAP 认证，使 QEMU 内的 iPXE 能从要求认证的 nvmet target 完成 sanboot。

```
nvmet (host 127.0.0.1:4420, AUTH=1, DHHC-1 key)
  → slirp 10.0.2.2:4420 → iPXE nvmetcp 驱动
  → 认证握手（Negotiate → Challenge → Reply → Success1）
  → Property Set (CC.EN=1) → Identify Ctrl/NS → I/O 队列 → READY
  → sanboot → GRUB 2.14 菜单
```

认证 wire 序列（DH-HMAC-CHAP 单向往）：

```
CMD Connect(ATR)  → RSP 0x0 (AUTH_REQUIRED)
CMD AuthSend(Negotiate)     → RSP 0x0
CMD AuthReceive             → C2H 4096B (challenge) + RSP 0x0
CMD AuthSend(Reply)         → RSP 0x0
CMD AuthReceive             → C2H 4096B (success1) + RSP 0x0
CMD Property Set (CC)       → RSP 0x0
CMD Identify Ctrl/NS ...    → 后续正常
```

## 2. 环境与工具

| 项 | 值 |
|---|---|
| 虚拟化 | QEMU q35 + KVM，OVMF 4M，串口日志 `diag/qemu-auth.log` |
| 网络 | slirp user 模式，guest 10.0.2.15，host 回环经 10.0.2.2 可达 |
| target | Linux nvmet（`diag/nvmet-setup.sh`，AUTH=1，`DHHC-1:01:...` 密钥，文件后端） |
| 控制面 | host 127.0.0.1:8000 的 python http 服务，按 MAC 下发 `nbft-secret`（`diag/nvmeof-auth-test.ipxe` 嵌入固件经 HTTP 拉取） |
| 固件 | `bin-x86_64-efi/ipxe.efi`，`EMBED=nvmeof-auth-test.ipxe DEBUG=nvmetcp:3`，部署为 fat 盘 `diag/tmp/EFI/BOOT/BOOTX64.EFI` |
| 抓包 | `-object filter-dump` → `diag/netdump-auth.pcap`；跨段重组解析器 `diag/parse-pcap-stream.py` |
| 内核参考 | `/usr/src/linux-headers-7.0.0-14-generic/include/linux/nvme-tcp.h`（PDU 头格式对照）、nvmet 源码（错误码溯源） |

### 调试打印级别说明（DBGLVL）

- `DEBUG=nvmetcp:3`：`nvmetcp.c` 的 `DBGC`（级别 3）可见——`sending ICReq` / `sending Connect` / `completion: cid N status ...` 等
- `nvmetcp_auth.c` **未配置 DEBUG 级别**，其 `DBGC`（`sent Negotiate` / `authentication succeeded` 等）在构建时被裁剪，日志中不可见——不是 bug，是构建配置缺失
- `DBGC2`（级别 2，如 `waiting for window (%zd)`）在 `DEBUG=...:3` 下同样可见

## 3. 迭代根因链

### 3.1 Bug 1：-EAGAIN 被当致命错误，连接立即关闭

**现象**：首轮测试 `could not step (phase 0): Error 0x06506086`，TCP 连接建立前会话即被关闭。

**根因**（两级）：

1. **错误码误读**：`0x06506086` 中 posix 位 `0x06` = `EAGAIN`（EFI 平台压缩错误码），此前被误判为 `EPROTO`。
2. **语义错误**：ICReq 发送时 TCP 连接尚未建立（SYN 未完成），`xfer_window()` 返回 0 → 发送返回 `-EAGAIN`；`nvmetcp_step` 的 err 分支把 `-EAGAIN` 当致命错误 → `nvmetcp_close` 关闭会话。

**修复**：`-EAGAIN` 是瞬态错误——`process_del` 停止调度，等待 `xfer_window_changed` 触发 `nvmetcp_tx_resume` 重新 `process_add` 后重试，而不是关闭会话。

### 3.2 Bug 2：AuthReceive 双重发送，nvmet 断开连接

**现象**：`Connection reset (phase 2)`；wire 上出现两个连续的 AuthReceive。

**根因**：AuthReceive 发送 `-EAGAIN` 时回退 `step=COMPLETE_REPLY`；窗口恢复后 `nvmetcp_auth_step` 重发成功——但重发分支**不推进 step**（仍为 COMPLETE_REPLY）；随后 Reply 的 RSP 到达，`nvmetcp_auth_rx_complete` 看到 COMPLETE_REPLY 又发送一个 AuthReceive。nvmet 收到重复请求 → 断开连接。

**修复**：重发路径与完成路径统一走 `nvmetcp_auth_tx_receive_step()` 辅助函数——发送成功后**统一推进 step**（CHALLENGE / SUCCESS1），失败时回退 COMPLETE 步。同时确认 `nvmetcp_auth_tx_receive` 完全幂等（每次重建命令、新 cid，`-EAGAIN` 不残留发送状态），重发安全。

### 3.3 Bug 3（核心）：认证成功后跳过 Property Set，Identify 被 0x8018 拒绝

**现象**：认证握手全通（各 RSP status=0），随后 `sending Identify (cns 0x1 nsid 0x0)` 被拒 `command failed: status 0x8018`（phase 4）。日志中**始终没有 `sending Property Set (CC)`**。

**错误码解码**：`0x8018 = NVME_SC_CMD_SEQ_ERROR (0x0C) | 0x8000`，来自 nvmet 的 `nvmet_check_ctrl_status()` 的 `CC.EN == 0` 检查——**控制器从未被启用**，即 PropSet（写 CC.EN=1）从未到达 nvmet。

**证据链**：

1. 跨段重组 pcap（修正解析器的 COMMAND PDU fctype 误判后）确认：认证握手全部成功，唯一失败命令是 Identify；PropSet 在 wire 上不存在。
2. 字节级验证 PDU 头格式：iPXE `nvmetcp_pdu_header`（8B：type/flags/hlen/pdo/plen）与内核 `struct nvme_tcp_hdr` 完全一致，排除头格式不匹配。
3. 日志时序分析：4168B 单段 = RSP cid=4（Reply 完成）+ C2H cid=7（success1 数据）+ RSP cid=7（AuthReceive 完成）交错到达。

**根因（一级竞态）**：`nvmetcp_auth_rx_success1` 校验通过后**立即** `phase = NVMETCP_PHASE_PROP_SET`。同一 TCP 段中随后到达的 AuthReceive 完成 RSP 被 `nvmetcp_rx_command` 的 PROP_SET 分支误当作 PropSet 完成处理 → phase 直接跳到 IDENTIFY_CTRL → **PropSet（CC.EN=1）从未发出** → Identify 被拒 0x8018。

**根因（二级竞态，cid 匹配的必要性）**：`-EAGAIN` 重试路径使问题更隐蔽——日志 `waiting for window (72)` 显示 AuthReceive 首次发送失败时 cid 已自增（cid 5 浪费、从未上 wire），重试成功占用 cid 6；且 **Reply 的完成（RSP cid=4）在 AuthReceive(cid=6) 发送之后才被处理**。此时仅凭 `step` 状态（SUCCESS1）无法区分 RSP 归属，会把 RSP cid=4 误判为最终 AuthReceive 的完成。

**修复**（3 个文件，两轮迭代）：

第一轮——双标志 + 统一出口：

| 位置 | 改动 |
|---|---|
| `struct nvmetcp_auth`（nvmetcp.h） | 新增 `completed`（success1 校验通过）/ `rx_complete`（最终 AuthReceive 完成到达）双标志 |
| `nvmetcp_auth_rx_success1` | 校验通过后置 `completed=1`，**不再切 phase** |
| 新增 `nvmetcp_auth_try_complete()` | `completed && rx_complete` 才切 `phase=PROP_SET` |
| `nvmetcp_rx_command` / `nvmetcp_rx_data` 的 AUTH 分支 | 统一接入 `try_complete` + 条件 `process_add` |
| `nvmetcp_auth_step` START 分支 | `completed` 时禁止重发 Negotiate（防 resume 回调在等待窗口期误触发） |

第二轮——命令 id 匹配（修复二级竞态）：

| 位置 | 改动 |
|---|---|
| `struct nvmetcp_auth` | 新增 `rx_cid`（实际上 wire 的 AuthReceive 命令 id） |
| `nvmetcp_auth_tx_receive_step` | 发送成功后记录 `rx_cid = nvmetcp->cid` |
| `nvmetcp_auth_rx_complete` | SUCCESS1/START 分支**仅当 `le16_to_cpu(cqe.command_id) == rx_cid`** 才置 `rx_complete`，拦截迟到的 Reply RSP |

## 4. 最终验证证据

修复后 QEMU 重跑（`diag/qemu-auth.log`），关键序列：

```
sending 72 bytes              ← AuthReceive(success1) 重发成功（cid 6，cid 5 因 -EAGAIN 浪费）
completion: cid 4 status 0x0  ← Reply 完成（cid 匹配拦截，不置 rx_complete）
completion: cid 6 status 0x0  ← AuthReceive 完成（cid == rx_cid → 认证阶段结束）
sending Property Set (CC)     ← 此前永远缺失的命令，现在出现
completion: cid 7 status 0x0  ← nvmet 接受 PropSet（CC.EN=1）
sending Identify (cns 0x1 nsid 0x0) → 0x0
namespace 1: 131072 blocks of 4096 bytes
I/O queue established         ← qid 1 连接成功，进入 READY
... 块读取命令全部 status 0x0
GNU GRUB version 2.14: "NVMe/TCP SAN boot OK"   ← GRUB 从 SAN 盘引导成功
```

统计：全程 `0x8018` / `command failed` 出现 **0 次**。

pcap wire 层确认（`parse-pcap-stream.py`）：

```
CMD cid=6 AuthReceive plen=72 → C2H cid=6 dlen=4096 (success1, t_id=0xf7d4) → RSP cid=6 0x0000
CMD cid=7 PropSet plen=72     → RSP cid=7 0x0000          ← PropSet 真实存在且被接受
RSP cid=8/9 0x0000（Identify Ctrl/NS 完成，数据正确返回）
```

## 5. 修复清单（当前代码状态）

| 文件 | 变更 |
|---|---|
| `src/include/ipxe/nvmetcp.h` | `nvmetcp_auth` 新增 `completed` / `rx_complete` / `rx_cid`；声明 `nvmetcp_auth_try_complete()` |
| `src/net/tcp/nvmetcp_auth.c` | success1 置 `completed`；`tx_receive_step` 记录 `rx_cid`；`rx_complete` cid 匹配置位；`try_complete()`；START 分支 completed 保护 |
| `src/net/tcp/nvmetcp.c` | `rx_command` / `rx_data` 的 AUTH 分支接入 `try_complete` + 条件 `process_add`；`-EAGAIN` 走 `process_del` 等待 resume（Bug 1 修复） |

## 6. 复现步骤

```bash
# 1. 构建带认证测试脚本的诊断固件（DEBUG=nvmetcp:3 打印会话层流程）
cd .cache/ipxe-upstream/src
make bin-x86_64-efi/ipxe.efi \
  EMBED=$PWD/../../diag/nvmeof-auth-test.ipxe DEBUG=nvmetcp:3
cp bin-x86_64-efi/ipxe.efi diag/tmp/EFI/BOOT/BOOTX64.EFI

# 2. 启动 nvmet target（AUTH=1）与控制面 HTTP 服务（127.0.0.1:8000）

# 3. 运行 QEMU（需沙箱外 KVM），150s 超时自动结束
bash diag/run-qemu-auth.sh

# 4. 查看结果
sed 's/\x1b\[[0-9;]*m//g' diag/qemu-auth.log | grep -E "sending|completion|namespace|established"
# 期望：sending Property Set (CC) → namespace 1: 131072 blocks → I/O queue established
```

## 7. 边界与遗留（状态截至 2026-08-19）

1. **修复尚未固化进补丁**：本次改动在 `.cache/ipxe-upstream/` 工作树（gitignore，`build.sh` 每次 `git clean -fdxq` 重置）。需更新 `patches/0006-nvmeof-adaptation.patch`（或新增补丁）持久化，否则重新构建后丢失。 **[2026-08-18 已解决]**：新增 `patches/0007-nvmetcp-auth-fix.patch` 固化，`build.sh` 全量验证通过。 **[2026-09-12 补丁整理]**：补丁集合并重排后，0007 已并入 `patches/0005-nvmeof-adaptation.patch`。
2. **auth.c 调试打印不可见**：`nvmetcp_auth.c` 无 DEBUG 级别配置，`authentication succeeded` 等 DBGC 被裁剪。可后续补 `DEBUG=nvmetcp_auth:3` 支持，便于独立观测认证模块。 **[2026-08-19 已解决]**：iPXE 的 `DEBUG=` 参数按源文件名生效（`src/Makefile.housekeeping`），构建时传 `DEBUG=nvmetcp,nvmetcp_auth:3` 即可使 `nvmetcp_auth.c` 的 DBGC 可见，无需改代码；2026-08-19 已用该参数构建验证 `authentication succeeded` 字符串进入固件。
3. **解析器 fctype 误判**：`parse-pcap-stream.py` 对 COMMAND PDU 无条件读 `p[8+4]` 作 fctype，Identify（opcode 0x06）的 nsid 低字节=0 被误标为 PropSet（fctype 0x00）。已知缺陷，分析时需人工甄别（opcode==0x7f 才读 fctype）。 **[2026-08-19 已修复]**：`parse-pcap-stream.py` 与 `parse-pcap-auth.py`（两脚本均有此问题）已加 `p[8]==0x7f` 判断，非 Fabrics 命令按 opcode 标注（Identify/Read/Write）；用 `netdump-auth.pcap` 验证 `cid=8 Identify`、`cid=11+ Read` 不再误标。
4. **单元测试缺口**：`tests/nvmetcp_test.c` 仅覆盖结构布局与 Identify 解析，认证状态机的 completed/rx_complete/rx_cid 竞态逻辑无单测覆盖（依赖 QEMU 集成验证）。 **[2026-08-19 已解决]**：新增 3 组状态机单测（`nvmetcp_auth_try_complete_test` 阶段完成门控、`nvmetcp_auth_rx_complete_test` 命令 id 匹配、`nvmetcp_auth_step_test` START 步守卫），`enum nvmetcp_auth_steps` 上移至 `nvmetcp.h` 供测试引用；`tests.linux` 全量 11625 个断言通过。
5. **已知时序行为**：`-EAGAIN` 重试后 AuthReceive(success1) 可能在 Reply 完成（RSP）之前发送（如修复后日志 48-53 行），nvmet 实测接受，属安全行为；极端场景下 RSP 乱序的归属判定已由 cid 匹配兜底。 （行为记录，非缺陷）
6. **会话重试语义**：sanboot 失败后 iPXE 会重试整个连接（日志中多轮 ICReq），认证流程每轮独立（新 transaction、新 cid），验证中多轮重试均正常。 （行为记录，非缺陷）

## 8. 参考资料

- [nvmeof-research.md](nvmeof-research.md) — 协议研究与设计（含认证消息格式、错误码表）
- [nvmeof-san-boot-verification.md](nvmeof-san-boot-verification.md) — 无认证 SAN 引导验证记录
- Linux 内核 `drivers/nvme/target/core.c` — `nvmet_check_ctrl_status`（0x8018 来源）
- `/usr/src/linux-headers-7.0.0-14-generic/include/linux/nvme-tcp.h` — PDU 头格式对照
- `test/nvmet-setup.sh` — nvmet 认证配置（AUTH=1、DHHC-1 密钥、configfs 结构）

# Debian 12 NBFT 认证引导验证记录（QEMU + nvmet，DH-HMAC-CHAP 全链路）

> 本文档仅中文。状态：**验证通过**（2026-08-25）。本次验证覆盖完整引导链路上的两段认证：固件段（iPXE 消费内核生成的 NBFT 表后，经 NVMe/TCP 对 nvmet 完成 DH-HMAC-CHAP 认证并 sanboot）与内核段（Debian 12 内核重新认证并挂载 rootfs）。pcap 证据 `diag/netdump-vmw12-612.pcap` 中四个连接全部按预期工作：两个 admin 队列均完成认证（Connect RSP `result=0x00020001` = ATR｜cntlid=1，AuthSend/AuthReceive 各 2 个 PDU），认证后控制面与数据面命令全部返回 status=0（内核 admin 队列 706/706），GRUB 经 iPXE 读盘 120.2 MiB 完成引导。
>
> 关联文档：[nbft-boot-verification.md](nbft-boot-verification.md)（无认证六环链路验证）、[nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md)（DH-HMAC-CHAP 认证链路调试记录）、[nvmeof-research.md](nvmeof-research.md)（认证协议研究）。

## 1. 目标与链路

验证目标：在**认证开启**（nvmet `AUTH=1`）条件下，从内核生成的 NBFT 表出发，固件段与内核段两处都完成 DH-HMAC-CHAP 认证，最终引导 Debian 12 到 rootfs。

```
内核 6.12.102 生成 NBFT 表（nbft-qemu.bin，ACPI 注入）
  → OVMF 加载 iPXE（nbft-qemu.bin：NBFT 消费 + nvmetcp + 认证支持）
  → iPXE 建立 admin 队列，Connect 收到 ATR → DH-HMAC-CHAP 认证（固件段认证①）
  → iPXE 建立 IO 队列 sanboot（环：磁盘枚举 → GRUB 2.14）
  → GRUB 经 iPXE 的 EFI Block IO 读盘 120.2 MiB（内核 + initrd，数据面 IO）
  → Debian 12 内核接管，重建 admin/IO 队列，再次 ATR + DH-HMAC-CHAP（内核段认证②）
  → rootfs 挂载，系统启动（KeepAlive 全程心跳正常）
```

认证仅发生在 admin 队列（NVMe 规范要求）；IO 队列不携带认证 PDU，但必须在认证成功后才能建立——因此 IO 队列的建立与正常工作本身就是认证成功的下游证据。

## 2. 环境与工具

| 项 | 值 |
|---|---|
| 虚拟化 | QEMU q35 + KVM，OVMF 4M（`OVMF_CODE_4M.fd` + `OVMF_VARS.fd`），1024M 内存，`timeout 1200s`；`-serial telnet:127.0.0.1:5555,server=on,wait=off`、`-monitor none`、QMP socket `qmp-vmw12.sock` |
| 网络 | slirp user 模式：guest 10.0.2.15，宿主回环经 10.0.2.2:4420 可达；e1000 MAC `52:54:00:12:34:56`（与 NBFT HFI 一致）；`-object filter-dump` 输出 `diag/netdump-vmw12-612.pcap` |
| target | Linux nvmet（内核 6.12.102）：127.0.0.1:4420，`nqn.2026-08.org.ipxe-stateless:test`，`AUTH=1`（DH-HMAC-CHAP，type=01，32 字节密钥），文件后端 `debian_12.img`（4K 逻辑块） |
| NBFT 表 | 内核 6.12.102 生成 `nbft-qemu.bin`，QEMU 以 `-acpitable` 注入（traddr 10.0.2.2 / trsvcid 4420 / hfi-ip 10.0.2.15） |
| 引导栈 | iPXE（NBFT 消费 + 认证）→ GRUB 2.14 → Debian 12 内核 + initramfs → rootfs |
| 宿主 | Ubuntu 26.04（内核 6.12.102，nvmet target 模块），脚本 `diag/nvmet-setup.sh`、`diag/run-qemu-vmw12-612.sh`、`diag/cred-server.py` |

## 3. 验证证据

### 3.1 nvmet 侧 AUTH=1 配置成功

`sudo env IMG=.../debian_12.img AUTH=1 bash diag/nvmet-setup.sh` 输出关键行：

```
KEY OK: type=01 key=32B        # DH-HMAC-CHAP，密钥已注入
LISTENING on 4420
DONE
```

目标侧就绪：认证协商参数由 nvmet configfs 配置——`dhgroup=ffdhe4096`（走完整 DH 交换）、key 为 `DHHC-1:1:<base64(32B key+CRC32)>` 格式（与 iPXE/cred-server 两侧对齐）；协商发生在 Connect 返回 ATR 后的 AuthSend/AuthReceive 命令中。

### 3.2 四次 TCP 连接总览

pcap 中全部与 4420 的 TCP 流按发起端口归类，共四个连接，角色与证据一览：

| 连接（发起端口） | 阶段与队列 | 时间段（s） | 认证 PDU | 命令构成 | RSP 结果 |
|---|---|---|---|---|---|
| 51444 | 固件段 admin 队列 | 1.42–1.55 | AuthSend×2、AuthReceive×2 | PropSet×1、Connect×1、Identify×2 | 4/4 status=0；Connect RSP `result=0x00020001` |
| 38960 | iPXE IO 队列 qid1 | 2.06–270.32 | 无（IO 队列不认证） | Connect×1、Read×31101、Write×33 | Connect RSP `result=1`（cid=10）；363 个 status=0xC102（见 §6.1）其余成功 |
| 40720 | 内核 admin 队列 | 274.61–1196.56 | AuthSend×2、AuthReceive×2 | PropSet×2、PropGet×4、Connect×1、Identify×6、Read×4、GetLogPage×2、SetFeatures×1、KeepAlive×694 | 706/706 status=0；Connect RSP `result=0x00020001` |
| 40728 | 内核 IO 队列 qid1 | 275.00–469.91 | 无 | Connect×1、Read×1536 | Connect RSP `result=1`；C2H×1493（另 43 个因 slirp 截断未完整捕获） |

认证 PDU 计数（fctype：0x00 PropSet、0x01 Connect、0x04 PropGet、0x05 AuthSend、0x06 AuthReceive）在两个 admin 连接上完全一致：**AuthSend×2 + AuthReceive×2**，即一轮完整的 DH-HMAC-CHAP 交换（发起 → 取挑战 → 回响应 → 校验完成）。

### 3.3 固件段认证（51444）：PDU 级

1. `ICReq`（128 B，nvme-tcp 1.1）→ `ICResp`；
2. `Connect` 命令（PDU 结构完全正常：type=0x04、hlen=72、pdo=72、plen=1096 = 8 + 64 + 1024 数据）；数据区为标准 `nvmf_connect_data` 布局——`subsysnqn` 位于数据区偏移 256（PDU 内偏移 328，值 `nqn.2026-08.org.ipxe-stateless:test`）、`hostnqn` 位于偏移 512（PDU 内偏移 584，值 `nqn.2014-08.org.ipxe:ipxe`）；
3. **Connect RSP `result=0x00020001`**：低 16 位 = cntlid 1（控制器 ID 已分配），bit17 = ATR（Authentication Required，0x00020000）——目标要求认证，会话进入认证协商；
4. `AuthSend` ×2 + `AuthReceive` ×2：DH-HMAC-CHAP 一轮完整交换，全部 status=0；
5. 认证通过后 `Identify` ×2（CNS=Identify Controller/Namespace），status=0——**控制面在认证后立即可用**，连接随即正常关闭（固件段使命完成）。

### 3.4 内核段认证（40720）：PDU 级

内核 nvme-tcp 驱动的建立序列与固件段对照，完全一致且全部成功：

1. `PropSet` ×2（控制器配置）→ `PropGet` ×4（状态轮询）；
2. `Connect` → RSP `result=0x00020001`（ATR｜cntlid=1），认证请求生效；
3. `AuthSend` ×2 + `AuthReceive` ×2（DH-HMAC-CHAP），Connect 数据区 hostid = `11111111-2222-3333-4444-555555555555`；
4. 认证通过后：`Identify` ×6、`Read` ×4、`GetLogPage` ×2、`SetFeatures` ×1，以及**全程 694 个 KeepAlive**——**706 个 RSP 全部 status=0**，无一失败。

### 3.5 数据面 IO 验证（38960 与 40728）

38960（iPXE IO 队列 qid1）：

- 命令流完整重组：ICReq（128）+ Connect（1096）+ 31101×Read（各 72 B）+ 33×Write（各 4168 B = 72 B 头 + 4096 B 数据一体，iPXE fused 风格），字节守恒精确成立：`128 + 1096 + 31101×72 + 33×4168 = 2,378,040`；
- Connect RSP `result=1`（cid=10）= IO 队列建立成功；
- 成功读 30771 块 ×4 KiB = **120.2 MiB**（GRUB 经 iPXE 的 EFI Block IO 读取内核与 initrd），对应 30985 个 C2H 数据 PDU；
- GRUB 在 5.37 s 后完成磁盘探测，此后至 270.32 s 全部 IO 成功。

40728（内核 IO 队列 qid1）：Connect `result=1`，1536 个 Read（6 MiB）绝大多数获 C2H 响应（捕获 1493 个，余 43 个因 slirp 大包截断未完整捕获），rootfs 侧 IO 正常。

### 3.6 KeepAlive / TBKAS

内核 admin 队列（40720）共 694 个 KeepAlive 命令，间隔实测 1.28–2.56 s（中位约 1.3 s，与 TBKAS 协商的 kato 分频一致），**全部返回 status=0**——连接全程健康，直至 QEMU 于 ~1196.6 s（timeout 1200 s）终止。

## 4. 证据解析方法与可信度

### 4.1 解析基准（均对照内核 nvme-tcp 头与实测包逐一核对）

- PDU 头 8 字节：`type(1) flags(1) hlen(1) pdo(1) plen(4 LE)`；RSP PDU 内 cqe 16 字节按标准 DW 布局：DW0 result@8–11、DW2 sq_head@16–17 + sq_id@18–19、DW3 cid@20–21 + status@22–23；
- Connect 数据区 `nvmf_connect_data` 标准布局：hostid@0–15、cntlid@16–17、subsysnqn@256–511、hostnqn@512–767；
- slirp `filter-dump` 特性：大包 IP totlen 被截断，纯 ACK 残留以 `plen<=0` 排除，大响应（4120 B 的 C2H）须用捕获尾而非 totlen 解析。

### 4.2 分析过程中的方法修正（影响最终结论的三处）

1. **cqe 偏移误读**：早期把 cid/status 放在 DW2（@16–19），曾把 363 个 0xC102 误读为 status=1 的伪影；对照 cqe 标准 DW3 布局（cid@20–21、status@22–23）后确认 **0xC102 为真实状态**，且 363 个全部能按 cid 匹配到具体命令（363/363）；
2. **手工 hex 误数**：一度把 Connect 头误读为 plen=4 的"异常"；改用程序化解析后确认 **plen=1096 完全正常**，命令流按 plen 步进可无缝走完 2,378,040 字节；
3. **C2H 计数缺口**：totlen 截断导致 C2H 大包漏计，改用捕获尾后计数稳定（38960：30985）。

### 4.3 可信度结论

- 认证证据全部来自**目标（nvmet）发出的 RSP 原始字节**，非日志转述；
- 两个 admin 连接独立复现同一认证序列（ATR → 4 个认证 PDU → 全成功），排除单次偶然；
- 认证后的控制面/数据面命令（706 个 RSP、694 个 KeepAlive、30771 块读）全部 status=0，构成认证成功的下游闭环。

## 5. 复现步骤

```bash
# 1. 认证凭据服务（宿主后台）
python3 diag/cred-server.py &

# 2. 目标侧：AUTH=1 建立 nvmet 子系统（输出 KEY OK / LISTENING on 4420 / DONE）
sudo env IMG=/path/to/debian_12.img AUTH=1 bash diag/nvmet-setup.sh

# 3. 生成 NBFT 表并启动 QEMU（timeout 1200 s；serial telnet 127.0.0.1:5555）
#    run-qemu-vmw12-612.sh 内部：内核工具生成 nbft-qemu.bin → -acpitable 注入 →
#    -object filter-dump,file=diag/netdump-vmw12-612.pcap

# 4. 证据检查（pcap 判据，四选一命中即认证成功）
#    a) 两个 admin 连接（51444/40720）各有 AuthSend×2 + AuthReceive×2；
#    b) Connect RSP result=0x00020001（ATR｜cntlid=1）；
#    c) 认证后命令（Identify/KeepAlive/Read）status 全部为 0；
#    d) IO 队列 Connect RSP result=1（cntlid），GRUB 读盘完成。
```

分析脚本：`diag/verify-io-traffic.py`（38960 连接命令流/RSP 全量校验，含失败 LBA 明细）。

## 6. 边界与遗留

### 6.1 363 个 RSP status=0xC102（语义未定位，不影响认证结论）

- 现象：38960 连接上 2.14–5.37 s（GRUB 早期磁盘探测窗口）出现 363 个失败 RSP：330 个对应 Read、33 个对应 Write，全部匹配命令（363/363）；
- 失败 Read 仅 3 个 LBA：`131328`（0x20100）、`4992768`（0x4C2F00）、`5242879`（0x4FFFFF，即最后一个逻辑块），且每个 LBA 的所有命令全部失败（132/132、132/132、66/66），33 个 Write（slba=0x4FFFFF、nlb=0）也全部失败；GRUB 通过重试完成读盘，引导未受影响；
- 状态字拆解：`0xC102` = DNR(bit15)｜SCT=4（保留）｜SC=0x102（保留），非标准 NVMe 状态；nvmet 源码中越界路径返回 `NVME_SC_CAP_EXCEEDED(0x81)|DNR` = 0x8100（`include/linux/nvme.h` 确认），**0xC102 在 nvmet 源码中无出处**，语义未定位；
- 结论：失败集中在认证完成后的数据面早期探测，认证本身（admin 队列）零失败，不影响"认证成功"结论。

### 6.2 C2H 计数缺口

38960 上成功读 30771 块 vs C2H 30985，差 214（疑似 cid 复用导致的重放计数边界，未定论）；40728 上 1536 Read vs 1493 C2H 捕获（slirp 截断可解释）。

### 6.3 其他未观测项

- 登录提示符未直接观测（本验证以 pcap 为准；serial telnet 5555 已配置，可复查）；
- 40728 于 469.91 s 断开而 admin 连接持续至 1196.56 s（QEMU timeout 终止），断开原因未查；
- 失败 LBA 的字节偏移解释依赖逻辑块大小假设（脚本按 4K 计）。

## 7. 参考资料

- 内核源码（6.12.102）：`drivers/nvme/target/core.c`（errno_to_nvme_status）、`drivers/nvme/target/io-cmd-file.c`（文件后端 IO）、`include/linux/nvme.h`（状态码定义）
- [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md)、[nbft-boot-verification.md](nbft-boot-verification.md)、[nvmeof-research.md](nvmeof-research.md)
- pcap 与脚本：`diag/netdump-vmw12-612.pcap`、`diag/verify-io-traffic.py`、`diag/nvmet-setup.sh`、`diag/run-qemu-vmw12-612.sh`

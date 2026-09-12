# NVMe-OF（NVMe over TCP）SAN 引导固件使用指南

> 本文档仅中文。适用范围：补丁链 `0001-0009`（基线 `e6e51ccb`）构建的固件。
> 实现细节见 [customizations.zh-CN.md](customizations.zh-CN.md)（补丁 0005）；认证排障历程见 [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md)。

## 1. 能力概述

固件内置自研 `nvmetcp` 驱动（补丁 0005），提供 NVMe over TCP 的 SAN 引导能力：

- **协议流程**：ICReq/ICResp 参数协商 → Connect（Admin 队列）→ Property Set（CC.EN=1）→ Identify（控制器/命名空间）→ I/O 队列 Connect → 块读写（R2T 流控）
- **认证**：DH-HMAC-CHAP（SHA-256，DH 群 0/2048/3072/4096，补丁 0005 内含认证完成时序与状态机竞态修复）
- **已验证环境**：客户端 QEMU/OVMF（x86_64 UEFI）+ 服务端 Ubuntu 26.04（内核 7.0.0-14）nvmet TCP target + GRUB 2.14 接力引导，全链路通过（wire 层全部命令 `status=0x0000`）

**边界**：仅支持 TCP 传输（无 RDMA/FC）；认证固定 DH-HMAC-CHAP；单控制器单命名空间的引导路径（Identify 解析 512B/4K 块）。

## 2. 固件产物与部署

`./build/build.sh` 构建产物输出到 `dist/`（完整清单见 `docs/build-artifacts.zh-CN.md`）：

| 产物 | 引导环境 | 典型部署 |
|---|---|---|
| `pxe-uefi/ipxe.efi` | UEFI + PXE | DHCP 菜单 `chain` 加载 |
| `pxe-uefi/snponly.efi` | UEFI + PXE/本地 | 同左；链加载失败时回退接管全部 SNP/NII/MNP 设备（补丁 0003） |
| `direct-uefi/ipxe.efi` | UEFI 本地 | 固件直接引导（如 ESP 下 `\EFI\BOOT\BOOTX64.EFI`）；内置 `embed/auto.ipxe` 自动引导链 |
| `grub-bios/ipxe.lkrn` | BIOS | GRUB2 `linux16 /boot/ipxe.lkrn` |
| `undionly.kpxe` | BIOS + PXE | DHCP 菜单（UNDI 驱动） |
| `usb/ipxe.usb` | 任意 | 写盘后 USB 启动 |
| `*-debug.efi` | 同上 | 仅含 realtek 调试输出（`DEBUG=realtek:3`）；需要 `nvmetcp` 调试日志时须以 `DEBUG=nvmetcp:3` 重新构建；需要认证模块日志（`authentication succeeded` 等）时须加 `nvmetcp_auth`，即 `DEBUG=nvmetcp,nvmetcp_auth:3`（`DEBUG=` 按源文件名生效） |

部署要点：

- **UEFI**：复制 `ipxe.efi` 到 ESP 的 `\EFI\ipxe\ipxe.efi`，在固件 Boot Manager 中添加启动项；或由 GRUB2 `chainloader /EFI/ipxe/ipxe.efi` 引导
- **PXE**：DHCP 下发 `next-server`/引导文件名，菜单中 `chain tftp://${next-server}/ipxe.efi`
- **自动引导链**（`direct-uefi`）：`dhcp` → `chain tftp://${next-server}/boot.ipxe` → 控制面脚本（脚本内可执行 `sanboot`，见第 4 节）

## 3. 服务器端：nvmet target 配置

### 3.1 前提

```bash
sudo modprobe nvmet
sudo modprobe nvmet_tcp
mount | grep configfs        # 需要 configfs 已挂载（一般默认 /sys/kernel/config）
```

backing 文件建议放在项目工作区（如 `diag/nvme-boot.img`），避免 `/tmp`（权限受限环境 root 也可能无法写入）。

### 3.2 无认证最小配置

```bash
NQN="nqn.2026-08.org.ipxe-stateless:test"     # 示例 NQN，可按需修改
IMG=/path/to/backing.img
SYS=/sys/kernel/config/nvmet/subsystems/$NQN
PORT=/sys/kernel/config/nvmet/ports/1

mkdir -p "$SYS"
echo 1 > "$SYS/attr_allow_any_host"           # 无认证：放行任意主机
mkdir -p "$SYS/namespaces/1"
echo -n "$IMG" > "$SYS/namespaces/1/device_path"
echo 1 > "$SYS/namespaces/1/enable"

mkdir -p "$PORT"
echo ipv4 > "$PORT/addr_adrfam"
echo tcp  > "$PORT/addr_trtype"
echo 127.0.0.1 > "$PORT/addr_traddr"
echo 4420 > "$PORT/addr_trsvcid"
ln -sf "$SYS" "$PORT/subsystems/$NQN"

ss -tln | grep 4420          # 确认 LISTENING
```

现成脚本：[test/nvmet-setup.sh](../test/nvmet-setup.sh)（幂等，可重复执行）。

### 3.3 DH-HMAC-CHAP 认证配置

**密钥格式**（NVMe 规范）：`DHHC-1:XX:<base64(key + CRC32)>`

- `XX` 必须为两位数字（`01` = SHA-256）；内核两侧硬编码跳过 10 字节前缀，`XX` 一位会截断首个 base64 字符导致 `base64 key decoding error -1`
- `CRC32` 必须是标准 CRC-32 **终值**（`zlib.crc32`），小端追加在 key 之后；漏掉 final XOR 会被 nvmet 以 `dhchap status 2` 拒绝

生成命令：

```bash
python3 -c 'import zlib,base64; k=b"0123456789abcdef0123456789abcdef"; \
print("DHHC-1:01:"+base64.b64encode(k+zlib.crc32(k).to_bytes(4,"little")).decode())'
```

**configfs 结构（内核 7.0+，与 6.x 的 `auth_ctrl/attr_authentication` 不同）**：

```bash
HOSTNQN="nqn.2014-08.org.ipxe:ipxe"           # 必须与客户端实际发送的 Host NQN 一致
HOST_DIR=/sys/kernel/config/nvmet/hosts/$HOSTNQN

echo 0 > "$SYS/attr_allow_any_host"           # =1 时内核直接跳过认证（重要！）
mkdir -p "$HOST_DIR"
echo -n "$KEY" > "$HOST_DIR/dhchap_key"
echo ffdhe4096 > "$HOST_DIR/dhchap_dhgroup"
ln -sf "$HOST_DIR" "$SYS/allowed_hosts/$HOSTNQN"   # 符号链接，不可 mkdir
```

**Host NQN 匹配**：iPXE 的 Host NQN 来自 SMBIOS UUID；QEMU+OVMF 不提供 UUID 时回退为固定 `nqn.2014-08.org.ipxe:ipxe`，服务端 `hosts/` 目录名必须一致。

现成脚本：`sudo AUTH=1 bash test/nvmet-setup.sh`（内置密钥自检 + 幂等清理）。

### 3.4 服务端配置错误速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `base64 key decoding error -1` | `DHHC-1:XX:` 前缀不足 10 字节（XX 一位数） | 保持两位：`DHHC-1:01:...` |
| `Failed to setup authentication, dhchap status 2` | 密钥 CRC32 不是终值 | 用 `zlib.crc32`（含 final XOR）重新生成 |
| 认证完全不生效（免认证直连） | `attr_allow_any_host=1` | 置 0 后重建子系统 |
| `Can't set allow_any_host when explicit hosts are set!` | 残留 `allowed_hosts/` 链接（旧配置未清理） | `rm -f $SYS/allowed_hosts/*` 后 rmdir |

## 4. 客户端：sanboot 用法

### 4.1 URI 语法

```text
sanboot nvme://<traddr>:<trsvcid>/<nqn>[?secret=<DHHC-1 key>]
```

- 无认证：`sanboot nvme://10.0.2.2:4420/nqn.2026-08.org.ipxe-stateless:test`
- 带认证：`sanboot nvme://10.0.2.2:4420/nqn.2026-08.org.ipxe-stateless:test?secret=DHHC-1:01:...`
- 成功标志（`DEBUG=nvmetcp,nvmetcp_auth:3` 日志）：`sending Property Set (CC)` → `namespace 1: N blocks of 4096 bytes` → `I/O queue established`，随后将控制权交给盘上引导程序（GRUB）

### 4.2 认证要求的两种触发形态

服务端要求认证时，iPXE 从 Connect 完成中识别（两种均支持）：

1. **ATR 位**：Connect 响应 `result` 字段 bit 17 置位（nvmet 7.0.0-14 实测路径：`status=0x0000, result=0x00020001`）
2. **状态码**：Connect 完成状态 `0x0c`（`NVME_SC_AUTH_REQUIRED`）且无 ATR 位（兼容路径，补丁 0005）

识别后若无 `secret` 参数，固件报 `authentication required but no secret` 并拒绝引导。

### 4.3 密钥注入模式（控制面下发，推荐）

密钥不固化在固件中，由控制面按客户端下发并注入 `${nbft-secret}` 变量：

```ipxe
#!ipxe
dhcp || goto failed
chain --autofree http://10.0.2.2:8000/boot-vars?mac=${mac}&hostname=${hostname} \
  || goto failed          # 响应体为 iPXE 脚本：set nbft-secret DHHC-1:01:...
sanboot nvme://10.0.2.2:4420/nqn.2026-08.org.ipxe-stateless:test?secret=${nbft-secret}
:failed
shell
```

> 安全说明：生产环境中该端点必须置于强认证之后（TLS/mTLS + 客户端身份校验）；[test/cred-server.py](../test/cred-server.py) 仅为验证用的测试端点。完整可嵌入脚本示例见 [test/nvmeof-auth-test.ipxe](../test/nvmeof-auth-test.ipxe)。

### 4.4 交互式 shell

任意 iPXE 构建（含 PXE 版）启动后可输入：

```ipxe
iPXE> sanboot nvme://10.0.2.2:4420/nqn.2026-08.org.ipxe-stateless:test?secret=...
```

## 5. 验证方法（QEMU 全链路）

### 5.1 前置

- 宿主机：KVM（`/dev/kvm`）、OVMF 固件（`/usr/share/OVMF/OVMF_CODE_4M.fd`）
- 服务端：nvmet 模块加载、4420 端口监听（第 3 节）

### 5.2 步骤

```bash
# 1. 服务端（含认证）
sudo AUTH=1 bash test/nvmet-setup.sh          # 输出 ==>> LISTENING on 4420

# 2. 凭证端点（默认 8000 端口）
python3 test/cred-server.py &

# 3. 构建含测试脚本与 nvmetcp 调试输出的固件，部署到 fat 镜像
#    （diag/tmp/EFI/BOOT/BOOTX64.EFI；测试脚本见 test/nvmeof-auth-test.ipxe）

# 4. 启动 QEMU（需在沙箱外，使用 KVM）
bash test/run-qemu-auth.sh                    # timeout 150s；日志 qemu-auth.log，抓包 netdump-auth.pcap
```

### 5.3 预期结果（证据链）

`qemu-auth.log` 关键序列：

```text
sending Connect (qid 0)
completion: cid 1 status 0x0          # Connect 完成，ATR 位已置位
authentication required
sending Property Set (CC)             # ← 认证成功 → 启用控制器（补丁 0005 修复点）
...
namespace 1: 131072 blocks of 4096 bytes
I/O queue established
... GNU GRUB 2.14 ... "NVMe/TCP SAN boot OK"
```

`netdump-auth.pcap` wire 序列（解析器 `test/parse-pcap-auth.py`）：ICREQ/ICRESP → `CMD cid=1 Connect` → `RSP status=0x0000 result=0x00020001`（ATR）→ AuthSend/AuthReceive 认证四消息 → `CMD cid=7 PropSet` → `RSP status=0x0000` → Identify → I/O 队列；全程 `0x8018` 出现 0 次。

### 5.4 客户端失败速查

| 现象 | 含义 | 处理 |
|---|---|---|
| `command failed: status 0x8018`（Identify 被拒） | Command Sequence Error：控制器未启用（`CC.EN==0`），**Property Set 被跳过** | 认证完成时序问题，见 [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md) Bug 3；确认固件含补丁 0005 |
| 日志始终无 `sending Property Set (CC)` | 认证未完成或 phase 竞态 | 同上；检查服务端认证配置与密钥 |
| 认证后 `Connection reset` | AuthReceive 被重复发送（固件不含补丁 0005 的发送幂等修复） | 重建含 0005 的固件 |
| `authentication required but no secret` | 服务端要求认证但未提供 secret | 检查 URI `?secret=` 参数与 `${nbft-secret}` 注入 |
| `waiting for window (...)` 后重试 | 瞬态发送失败（-EAGAIN），0005 修复后自动等待窗口恢复 | 正常路径，无需干预 |
| `command failed`（Connect 阶段） | 服务端拒绝连接（NQN/端口/认证不匹配） | 核对 3.2/3.3 配置；`ss -tln` 确认监听 |

## 6. 限制与注意事项

- 固件必须包含**完整补丁链 0001-0009**：认证修复代码已并入 `0005`（原独立补丁 0007），缺失或旧链构建时认证流程会跳过 Property Set 导致 0x8018
- `nvmetcp` 驱动无编译期默认调试输出；需要认证/状态机日志（含 `authentication succeeded`）时以 `DEBUG=nvmetcp,nvmetcp_auth:3` 手动构建（仅 `DEBUG=nvmetcp:3` 看不到 `nvmetcp_auth.c` 的打印）
- 认证仅支持 DH-HMAC-CHAP（SHA-256），DH 群支持 0/2048/3072/4096（服务端可配 `ffdhe4096`）
- Host NQN 依赖 SMBIOS UUID；无 UUID 平台（如 QEMU+OVMF）回退固定 NQN，服务端需按实际值配置
- 服务端密钥对 CRC32 校验严格（终值、小端），生成后可用 `test/nvmet-setup.sh` 的内置自检确认

## 7. 相关文档

| 文档 | 定位 |
|---|---|
| [customizations.zh-CN.md](customizations.zh-CN.md) | 补丁 0005 设计与实现（结果性文档） |
| [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md) | 认证排障全历程：三个 bug 时间线、0x8018 解码、验证证据（过程性文档） |
| [network-support.zh-CN.md](network-support.zh-CN.md) | 网卡支持矩阵与实测记录 |
| [build-artifacts.zh-CN.md](build-artifacts.zh-CN.md) | 构建产物列表与选用指南 |
| [patches/README.md](../patches/README.md) | 补丁链清单、基线、授权与升级流程 |

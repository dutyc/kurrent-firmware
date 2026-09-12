# NVMe-oF 固件测试流程（test/ 目录）

本文档描述 `test/` 目录下交付脚本的完整测试流程：从 nvmet 目标端配置、GRUB 引导盘制作、测试固件构建，到 QEMU 全链路验证与 pcap/日志分析。

## 1. 目录定位

| 目录 | 内容 | 是否入库 |
|---|---|---|
| `test/` | 可交付的测试流程脚本（本仓库跟踪） | 是 |
| `diag/` | 本地诊断工作区：运行产物（磁盘镜像、日志、pcap、OVMF_VARS.fd、FAT 临时盘） | 否（gitignore） |
| `docs/` | 文档（本流程文档、使用指南、排障日志） | 是 |

脚本全部以 `test/` 路径调用；脚本运行产物（`nvme-boot.img`、`qemu-*.log`、`netdump-*.pcap`、`tmp/` 等）统一输出到 `diag/`，不污染仓库。

## 2. 环境前提

- QEMU + OVMF（`/usr/share/OVMF/OVMF_CODE_4M.fd`、`OVMF_VARS_4M.fd`），`/dev/kvm` 可用（QEMU 步骤需在沙箱外执行）
- 内核模块 `nvmet`/`nvmet_tcp`（服务器端）
- 工具：`python3`、`mkfs.vfat`、`mcopy`（mtools）、`grub-mkimage`、`nvme-cli`（仅主机诊断）、`timeout`、`ss`
- **`test/nvmet-setup.sh` 与 `test/nvme-host-diagnose.sh` 需要 sudo**（configfs 写入、模块加载）；无 sudo 权限的环境需手动执行，其余步骤无需 root

## 3. 脚本清单

| 脚本 | 功能 | 依赖 | 权限 |
|---|---|---|---|
| `make-grub-bootdisk.sh` | 生成可引导的 NVMe/TCP 后端盘（GPT 4K 扇区 + FAT32 ESP + GRUB EFI），输出 `diag/nvme-boot.img` | `python3`/`mkfs.vfat`/`mcopy`/`grub-mkimage` | 无 |
| `nvmet-setup.sh` | nvmet 目标端配置（幂等，含 DHHC-1 密钥自检），`AUTH=1` 启用认证 | 内核模块 `nvmet_tcp` | sudo |
| `cred-server.py` | HTTP 凭据注入端点（`/boot-vars`），返回 `set nbft-secret ...` 脚本体 | 无 | 无 |
| `nvmeof-auth-test.ipxe` | 认证测试固件内嵌脚本（凭据注入 → sanboot） | `cred-server.py` | — |
| `nvmeof-test.ipxe` | 无认证测试固件内嵌脚本（HTTP 连通性 → sanboot） | 无 | — |
| `run-qemu-auth.sh` | 运行一轮 QEMU 验证，输出 `diag/qemu-<round>.log` + `diag/netdump-<round>.pcap` | 固件已放入 `diag/tmp/EFI/BOOT/`、OVMF | 无（需 KVM） |
| `parse-pcap-auth.py` | pcap 逐包 PDU 摘要（默认读 `diag/netdump-auth.pcap`） | 无 | 无 |
| `parse-pcap-stream.py` | pcap TCP 流重组解析（跨段 PDU） | 无 | 无 |
| `nvme-host-diagnose.sh` | 主机侧连接诊断（dyndbg + nvme-cli + dmesg delta） | `nvme-cli` | sudo |

依赖关系：`make-grub-bootdisk.sh` → `nvmet-setup.sh` → `run-qemu-auth.sh` → `parse-pcap-*.py`；认证链路另需 `cred-server.py`。

## 4. 测试流程

### 4.1 无认证链路

```bash
# 1. 制作 GRUB 引导后端盘（无 root）
bash test/make-grub-bootdisk.sh
#    输出：diag/nvme-boot.img（512 MiB，GRUB 菜单 "NVMe/TCP SAN boot OK"）

# 2. 配置 nvmet 目标（无认证，sudo）
sudo bash test/nvmet-setup.sh
#    期望输出末尾：==> LISTENING on 4420

# 3. 构建测试固件（内嵌无认证测试脚本）
bash build/build.sh    # 或仅构建测试目标：
#    make -C .cache/ipxe-upstream/src bin-x86_64-efi/ipxe.efi \
#      EMBED=test/nvmeof-test.ipxe DEBUG=nvmetcp:3

# 4. 放入 QEMU FAT 盘并运行（需沙箱外）
mkdir -p diag/tmp/EFI/BOOT
cp .cache/ipxe-upstream/src/bin-x86_64-efi/ipxe.efi diag/tmp/EFI/BOOT/BOOTX64.EFI
bash test/run-qemu-auth.sh basic    # 日志 diag/qemu-basic.log、抓包 diag/netdump-basic.pcap

# 5. 验证（见第 5 节）
grep -E "namespace 1:|I/O queue established|GRUB BOOTED" diag/qemu-basic.log
```

### 4.2 认证链路（DH-HMAC-CHAP）

```bash
# 1. 制作后端盘（同上）
bash test/make-grub-bootdisk.sh

# 2. 配置 nvmet 目标（启用认证，sudo）
sudo AUTH=1 bash test/nvmet-setup.sh
#    期望输出包含：dhchap_key / dhchap_dhgroup / allowed_hosts 已列出

# 3. 启动凭据注入端点（认证链路必需，secret 由它下发）
python3 test/cred-server.py &        # 默认 :8000，日志 cred-server.log

# 4. 构建认证测试固件（必须含 nvmetcp_auth 调试，否则看不到认证打印）
make -C .cache/ipxe-upstream/src bin-x86_64-efi/ipxe.efi \
  EMBED=test/nvmeof-auth-test.ipxe DEBUG=nvmetcp,nvmetcp_auth:3

# 5. 放入 FAT 盘并运行
cp .cache/ipxe-upstream/src/bin-x86_64-efi/ipxe.efi diag/tmp/EFI/BOOT/BOOTX64.EFI
bash test/run-qemu-auth.sh auth     # 默认输出 diag/qemu-auth.log + diag/netdump-auth.pcap

# 6. 验证（见第 5 节）
grep -E "CRED-FETCH|authentication succeeded|sending Property Set|GRUB BOOTED" diag/qemu-auth.log
python3 test/parse-pcap-auth.py     # 默认读 diag/netdump-auth.pcap
```

## 5. 验证方法

**日志证据链**（`DEBUG=nvmetcp,nvmetcp_auth:3` 固件）：

```
sending Connect (qid 0)          → Connect(admin) 完成
completion: cid 1 status 0x0     → Connect 成功（ATR 路径）
authentication required          → 服务端要求认证
sent Negotiate / authentication succeeded → 认证四消息完成
sending Property Set (CC)        → 认证阶段正确收尾（0005 修复核心）
namespace 1: N blocks of 4096 bytes → Identify 完成
I/O queue established            → I/O 连接就绪
== GRUB BOOTED FROM NVME/TCP SAN DISK == → 盘上引导成功
```

**pcap 证据链**（`parse-pcap-auth.py`）：

```
ICREQ/ICRESP → CMD cid=1 Connect → RSP status=0x0000 result=0x00020001 (ATR)
→ AuthSend/AuthReceive 认证四消息 → CMD cid=7 PropSet → RSP status=0x0000
→ Identify → I/O 队列；全程 status=0x0、无 0x8018
```

**单测**（回归护栏，无需环境）：

```bash
make -C .cache/ipxe-upstream/src bin-x86_64-linux/tests.linux
.cache/ipxe-upstream/src/bin-x86_64-linux/tests.linux   # 全量 11625 断言
```

## 6. 失败速查

| 现象 | 原因与处理 |
|---|---|
| `==> NOT LISTENING (check nvmet_tcp module)` | `nvmet_tcp` 未加载；`modprobe nvmet_tcp` 后重跑 `nvmet-setup.sh` |
| `ERROR: subsystem dir still present (live controller?)` | 控制器仍连接中；断开（`nvme disconnect-all`）或卸载 nvmet 后重跑 |
| `base64 key decoding error -1` | DHHC-1 前缀非 `DHHC-1:XX:` 两位类型（内核按 10 字节前缀跳过）；密钥自检在 `nvmet-setup.sh` 内 |
| `Failed to setup authentication, dhchap status 2` | CRC32 非 zlib 终值小端；用脚本内 `python3 -c '...'` 行重新生成 |
| 日志无 `authentication succeeded` | 固件未含 `nvmetcp_auth` 调试（`DEBUG=nvmetcp,nvmetcp_auth:3` 而非仅 `nvmetcp`） |
| 日志出现 `command failed: status 0x8018` | 认证阶段被跳过（Property Set 未发）——固件缺 0005 补丁或使用旧固件 |
| 解析器把 Identify 标成 PropSet | 使用旧版解析器；`test/` 版本已按 opcode==0x7f 判断 |
| QEMU 未启动（KVM 错误） | 需在沙箱外执行（/dev/kvm 不可见） |

## 7. 密钥一致性说明

DHHC-1 密钥（`DHHC-1:01:...`）在三个脚本中各自硬编码，**必须保持完全一致**：

- `test/nvmet-setup.sh`（`DHHCP_KEY`，写入 configfs）
- `test/cred-server.py`（`SECRET`，注入给 iPXE）
- `test/nvme-host-diagnose.sh`（`KEY`，主机侧直连验证）

每个脚本均内置密钥自检（前缀长度 + CRC32 终值校验），写错会在配置阶段立即失败而非运行时才暴露。修改密钥时三处同步更新。

## 8. 相关文档

- [nbft-boot-verification.md](nbft-boot-verification.md) — NBFT 整机引导六环链路验证（NBFT 消费 → rootfs 挂载 → 登录提示符）
- [nvmeof-usage.md](nvmeof-usage.md) — 固件 NVMe-OF 端到端用法（部署、sanboot、验证方法）
- [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md) — 认证排障历程（0x8018 根因、状态机修复、遗留项状态）
- [customizations.md](customizations.md) — 定制清单（0005 补丁说明）

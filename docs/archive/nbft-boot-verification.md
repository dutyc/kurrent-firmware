# NBFT 整机引导链路验证记录（QEMU + nvmet，六环全链路）

> 本文档仅中文。状态：**验证通过**（2026-08-21）。六环链路——iPXE sanboot（NVMe/TCP）→ GRUB → 内核 → initramfs NBFT 消费（`nvme connect-all --nbft`）→ rootfs 挂载 → 系统启动到登录提示符——在 QEMU 全链路跑通（`diag/qemu-nbft9.log`）；宿主侧 `nvme connect-all --nbft` 同步复现成功。
>
> 关联文档：[nbft-consumption-research.md](nbft-consumption-research.md)（内核侧 NBFT 消费前置研究）、[nvmeof-san-boot-verification.md](nvmeof-san-boot-verification.md)（前三环：sanboot → GRUB）、[nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md)（DH-HMAC-CHAP 认证链路）、[nvmeof-test-procedure.md](../guides/nvmeof-test-procedure.md)（`test/` 脚本用法）。

## 1. 目标与链路

验证从 NVMe/TCP target 到完整系统启动（登录提示符）的引导链路，其中第 4 环的 NBFT 消费是重点：initramfs 从 ACPI NBFT 表读取 HFI（网卡 MAC/IP）与 SSNS（子系统/传输地址）信息建立连接。

```
宿主 nvmet (127.0.0.1:4420, AUTH=0, 文件后端)
  → slirp 10.0.2.2:4420 → iPXE nvmetcp 驱动 sanboot（环1）
  → OVMF PartitionDxe/FatDxe 识别 4K GPT → LoadImage ESP \EFI\BOOT\BOOTX64.EFI（GRUB 2.14，环2）
  → GRUB 加载内核 + initrd（root=PARTUUID=... nbft_auto，环3）
  → initramfs 读 ACPI NBFT 表 → nvme connect-all --nbft → 内核建立 nvme0（环4）
  → rootfs 挂载（PARTUUID 命中 nvme0n1p2，环5）
  → systemd 启动 → 登录提示符（环6）
```

NBFT 表由 `test/gen-nbft-table.py` 生成，QEMU 以 `-acpitable` 注入（模拟"固件预生成表"阶段；iPXE 运行时经 EFI_ACPI_TABLE_PROTOCOL 安装表为后续实现，见 §7）。

## 2. 环境与工具

| 项 | 值 |
|---|---|
| 虚拟化 | QEMU q35 + KVM（10.2），OVMF 4M，1024M 内存，串口日志 `diag/qemu-<round>.log`（`run-qemu-nbft.sh`，timeout 300s） |
| 网络 | slirp user 模式：guest 10.0.2.15，宿主回环经 10.0.2.2 可达；e1000 MAC `52:54:00:12:34:56`（与 NBFT HFI 记录一致） |
| target | Linux nvmet：127.0.0.1:4420，`nqn.2026-08.org.ipxe-stateless:test`，AUTH=0，文件后端 `diag/nvme-boot.img`（4K 逻辑块） |
| NBFT 表 | `gen-nbft-table.py` 默认参数：traddr 10.0.2.2 / trsvcid 4420 / hfi-ip 10.0.2.15 / host_id `12345678-9abc-def0-1234-56789abcdef0` / hostnqn `nqn.2014-08.org.ipxe:ipxe` |
| 盘镜像 | 2048M，GPT 4K 扇区：ESP 300M@8M（FAT32 4K 簇）+ rootfs@308M（ext4，PARTUUID `a1b2c3d4-1111-2222-3333-444455556666`，fs UUID `0f1e2d3c-4b5a-6789-abcd-ef0123456789`） |
| 引导栈 | iPXE（`nvmetcp` 驱动）→ GRUB 2.14 → 内核 6.12.94+deb13-amd64 + initramfs（`initramfs-nbft` 种子模块）→ Debian 13（trixie）rootfs |
| 宿主 | Ubuntu 26.04（内核 7.0），nvme-cli 2.16，nvmet configfs |

## 3. 迭代根因链（四关）

### 3.1 宿主复现失败：hostid 首字节 gate（nvme-cli 解析器）

- 现象：`nvme connect-all --nbft --nbft-path=diag/nbft-local` 输出 `SSNS 1: no controller found`（静默失败）；dmesg 末尾是 `nvme_fabrics: found same hostid 5c0aefaf-... but different hostnqn nqn.2014-08.org.ipxe:ipxe`
- 根因：nvme-cli 的 NBFT 解析器以 `*nbft->host.id`（host_id 十六字节的**首字节**）作为 gate 判断是否携带 hostid。旧表 host_id 首字节 0x00 → 被当作"无 hostid"→ 内核回落 default_host 随机 id，与 nvmf_default_host（同 hostid、不同 hostnqn）冲突 → `-EINVAL`
- 修复：host_id 首字节非零（`12345678-...`，flags 0x07 = VALID | HOSTID_CONFIGURED | HOSTNQN_CONFIGURED）
- 验证：宿主复现成功（§4.1），dmesg 无冲突行

### 3.2 HFI ip_address 的 IPv4-mapped 格式

- 根因：HFI_TRINFO 的 `ip_address` 是 16 字节 IPv6 格式地址；libnvme 直接对 16 字节做 `inet_ntop`，IPv4 必须以 IPv4-mapped（`::ffff:a.b.c.d`，即 10×0x00 + 0xffff + IPv4）存储。全零地址会被当作 host_traddr 传给内核绑定 `::`，报 `EAFNOSUPPORT`
- 修复：`hfi_trinfo()` 写入 `b[20:36] = 0x00*10 + 0xffff + inet_aton(ip)`；SSNS 的 traddr heap 对象同样用 IPv4-mapped 二进制（非 ASCII 字符串）
- 验证：表字节级 hexdump/cmp 核对（qemu 表 10.0.2.2/10.0.2.15、local 表 127.0.0.1）

### 3.3 rootfs 挂载失败：GPT GUID 字节序

- 现象：QEMU 前一轮验证中 initramfs 报 `ALERT! PARTUUID=... does not exist`；内核按结构解析分区正常（能建 p1/p2），但字符串形式的 PARTUUID 永不匹配
- 根因：GPT 的 GUID 前三分量（Data1 u32、Data2/3 u16）按 EFI 规范以小端存储，其余字节大端。脚本把 UUID 明文十六进制写入分区条目，磁盘读回即字节序颠倒：期望 `a1b2c3d4-1111-2222-3333-444455556666`，实际读回 `d4c3b2a1-1111-2222-3333-444455556666`；ESP type GUID 同理读回 `c12a7328-1ff8-d211-...`
- 修复：`guid_bytes()` 混合端序转换（`b[3::-1] + b[5:3:-1] + b[7:5:-1] + b[8:]`），ESP type GUID 改用规范串 `c12a7328f81f11d2ba4b00a0c93ec93b`；`make-debian-san-disk.sh` 与 `make-grub-bootdisk.sh` 同步修复
- 验证：Python 按 GPT 结构解析重建镜像，rootfs uuid 读回 `a1b2c3d4-1111-2222-3333-444455556666`，与 grub.cfg 的 `root=PARTUUID=` 一致；nbft9 内核 PARTUUID 命中（§4.2）

### 3.4 rootfs 挂载失败（第二关）：ext4 镜像尺寸越界

- 现象：nbft8 到达挂载环时 `EXT4-fs (nvme0n1p2): bad geometry: block count 445440 exceeds size of device (445406 blocks)` → `Failed to mount /dev/nvme0n1p2 as root file system`
- 根因：ext4 staging 镜像按 MiB 取整为 1740 MiB（= 445440 块），而 GPT 分区只到 `last_usable`（比整盘小 35 扇区，为备份 GPT 预留）→ 分区仅 445406 块。ext4 元数据声明的块数超出分区 → 内核几何检查拒绝；且 dd 尾部越过 `last_usable` 把磁盘末尾的备份 GPT 表/头一并覆盖
- 修复：staging 镜像精确截断为 `(last_usable - root_start + 1) × 4096`（= 445406 × 4096 字节），dd 落位 `bs=4096 seek=78848`（分区起始 LBA）
- 验证：重建后 ext4 `s_blocks_count=445406` 与分区精确相等；备份 GPT 头签名 `EFI PART`、CRC（92 字节头）校验通过——之前被覆盖的备份表已恢复

## 4. 最终验证证据

### 4.1 宿主复现（真实内核 + nvme-cli，local 表 traddr/hfi-ip=127.0.0.1）

```
# sudo nvme connect-all --nbft --nbft-path=diag/nbft-local -v
nvme1: nqn.2026-08.org.ipxe-stateless:test connected
# nvme list：/dev/nvme1n1（Linux，2.15 GB，4 KiB + 0 B）
# dmesg：
[ 1580.776526] nvmet: Created nvm controller 1 for subsystem nqn.2026-08.org.ipxe-stateless:test for NQN nqn.2014-08.org.ipxe:ipxe.
[ 1580.780126] nvme nvme1: new ctrl: NQN "nqn.2026-08.org.ipxe-stateless:test", addr 127.0.0.1:4420, hostnqn: nqn.2014-08.org.ipxe:ipxe
[ 1580.781854]  nvme1n1: p1 p2
```

无 `found same hostid` 冲突行——3.1/3.2 修复在真实环境生效。

### 4.2 QEMU 六环（nbft9，`diag/qemu-nbft9.log`）

```
Booting from SAN device 0x80                                    ← 环1：iPXE sanboot
HANDLE ... DiskIo opened 1x (C) by Partition Driver ... for
  Uri(...)/HD(1,GPT,00A0C9E1-933E-4B88-B8D1-E2A90D1C2E3F,...)   ← 环2：GPT 分区识别（GUID 正确）
  Booting `Debian 13 (trixie) NVMe/TCP SAN'                     ← 环3：GRUB → 内核
[    0.000000] Command line: ... root=PARTUUID=a1b2c3d4-1111-2222-3333-444455556666
              ip=dhcp ipv6.disable=1 nbft_auto rootwait console=ttyS0,115200
[    3.500652] nvme nvme0: new ctrl: NQN "nqn.2026-08.org.ipxe-stateless:test",
              addr 10.0.2.2:4420, hostnqn: nqn.2014-08.org.ipxe:ipxe
[    3.516599]  nvme0n1: p1 p2                                     ← 环4：initramfs NBFT 消费
[    3.779176] EXT4-fs (nvme0n1p2): orphan cleanup on readonly fs
[    3.780507] EXT4-fs (nvme0n1p2): mounted filesystem 0f1e2d3c-4b5a-6789-abcd-ef0123456789
              ro with ordered data mode. Quota mode: none.        ← 环5：rootfs 挂载（PARTUUID 命中）
Welcome to Debian GNU/Linux 13 (trixie)!
[    4.678152] EXT4-fs (nvme0n1p2): re-mounted 0f1e2d3c-4b5a-6789-abcd-ef0123456789 r/w.

Debian GNU/Linux 13 ROG-Z15 ttyS0

ROG-Z15 login:                                                   ← 环6：登录提示符
```

## 5. 修复清单

| 修复 | 文件 | 要点 |
|---|---|---|
| hostid 首字节 gate | `test/gen-nbft-table.py` | host_id 首字节非零（0x12）；flags 0x07；注释记录 nvme-cli gate 行为 |
| hfi-ip IPv4-mapped | `test/gen-nbft-table.py` | `b[20:36]` 与 traddr heap 对象按 `::ffff:a.b.c.d` 存储 |
| GPT GUID 字节序 | `test/make-debian-san-disk.sh`、`test/make-grub-bootdisk.sh` | `guid_bytes()` 混合端序；ESP type 规范串 |
| ext4 精确尺寸 | `test/make-debian-san-disk.sh` | `last_usable - root_start + 1` 精确块数 ×4096；dd `bs=4096 seek=78848`；不再覆盖备份 GPT |
| DONE 显示行 | `test/make-debian-san-disk.sh` | 移除已删除的 `ROOTFS_OFF_M` 引用，内联计算 rootfs 偏移 |

## 6. 复现步骤

```bash
# 1. NBFT 表（QEMU 用 + 宿主复现用）
python3 test/gen-nbft-table.py                                          # → diag/nbft-qemu.bin
python3 test/gen-nbft-table.py --traddr 127.0.0.1 --hfi-ip 127.0.0.1 \
    --out diag/nbft-local.bin

# 2. SAN 盘镜像（GPT 4K 双分区 + ext4 rootfs + ESP BOOTX64.EFI + grub.cfg）
sudo bash test/make-debian-san-disk.sh                                  # → diag/nvme-boot.img

# 3. nvmet 目标（幂等；重建磁盘后必须重跑以重开文件后端）
sudo bash test/nvmet-setup.sh                                           # → LISTENING on 4420

# 4. 宿主复现（可选；与 QEMU 互斥，见 §7）
sudo nvme connect-all --nbft --nbft-path=diag/nbft-local -v             # 预期 nvme1 connected
sudo nvme list; sudo dmesg | grep -i nvme | tail -8
sudo nvme disconnect -n nqn.2026-08.org.ipxe-stateless:test

# 5. QEMU 六环验证（需沙箱外 /dev/kvm）
bash test/run-qemu-nbft.sh nbft9                                        # → diag/qemu-nbft9.log

# 6. 证据检查
grep -E "Booting from SAN|new ctrl|mounted filesystem|re-mounted|login:" diag/qemu-nbft9.log
```

## 7. 边界与遗留

- **NBFT 表来源**：当前由 `-acpitable` 预注入，模拟"固件已生成表"阶段；iPXE 运行时经 `EFI_ACPI_TABLE_PROTOCOL` 生成并安装 NBFT（含 DHCP 后回填 hfi-ip 等运行时字段）是后续实现
- **认证**：本链路 AUTH=0；DH-HMAC-CHAP 认证链路已单独验证闭环（[nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md)），KD 子表无明文密钥的现状见 [nbft-consumption-research.md](nbft-consumption-research.md)
- **宿主与 QEMU 互斥**：表内 hostnqn+hostid 固定，宿主 nvme1 与 QEMU guest 同时连接会触发 nvmet 重复 LIVE 控制器拒绝；跑 QEMU 前先 `nvme disconnect`
- **libnvme 结构偏移差异**：`nbft_hfi_info_tcp` 在 flags 后无 reserved 字节，各字段比规范偏移表早 1 字节——`gen-nbft-table.py` 注释已记录，并与 `nvme nbft show` 输出对照验证
- **脚本现状**：`make-debian-san-disk.sh` 在 dd 之后才用 debugfs 把 grub.cfg 写入 rootfs staging 镜像，因此磁盘内 rootfs 的 `/boot/grub/grub.cfg` 副本实际不存在；GRUB 2.14 从 ESP 读取 grub.cfg，链路不受影响
- 验证产物（`diag/qemu-nbft*.log`、`diag/nvme-boot.img` 等）均在 gitignore 内，不入库

## 8. 参考资料

- [nvmeof-san-boot-verification.md](nvmeof-san-boot-verification.md) — 前三环（sanboot → GRUB）迭代记录
- [nbft-consumption-research.md](nbft-consumption-research.md) — 内核侧 NBFT 消费生态研究（libnvme/nvme-cli/dracut）
- [nvmeof-test-procedure.md](../guides/nvmeof-test-procedure.md) — `test/` 脚本清单与验证方法
- [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md) — 认证状态机排障（0x8018 根因）
- NVMe Boot Specification（NBFT 表结构与 HFI/SSNS 描述符语义）

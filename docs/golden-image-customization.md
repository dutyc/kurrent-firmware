# 母盘定制指南（NVMe-oF SAN 引导：一次定制，克隆即用）

> 状态：基于生产引导链全链路验证（2026-08-25，[production-boot-verification.md](production-boot-verification.md)）的实测操作清单。本文档仅中文。
>
> 适用范围：刚刚新装完成 Debian 12 的母盘（虚拟机或物理机镜像），定制后可作为无状态引导母盘克隆分发——客户端零本地介质、盘内零身份硬编码，身份与凭据由引导链外部注入。
>
> 关联文档：[initramfs-nbft/README.md](../initramfs-nbft/README.md)（种子模块组件说明）、[production-boot-verification.md](production-boot-verification.md)（全链路验证记录）、[customizations.md](customizations.md)（固件补丁设计）。
>
> **支持基线（2026-08-27 裁定）**：Debian 12（+backports 6.12）及以上、Ubuntu 24.04 LTS 及以上、RHEL 9 及以上、SLES 15 及以上、openSUSE Leap 16 及以上、Fedora 44 及以上、Arch rolling。**低于基线的发行版不做适配**（明细见第 10 节）。
>
> **自动化（2026-09-02 起）**：A–F 六阶段已封装为一键脚本 [test/golden-image-setup-debian12.sh](../test/golden-image-setup-debian12.sh)，在母盘系统内 `sudo bash test/golden-image-setup-debian12.sh` 即可全自动定制（幂等，可重跑）；下方各节保留手工步骤与原理说明，作为脚本行为的参照。验证状态：A–D+F 经 chroot 实测通过（2026-09-02），本地可引导性经 QEMU 实测通过（2026-09-02，见 8.1）。

## 1. 定制总览

```
新装 Debian 12
  → A. 系统与内核（6.12 backports，含 NVMe 认证）
  → B. initramfs 种子模块（initramfs-nbft：NBFT/NBCT 消费）
  → C. 系统配置（fstab / 网络 / hostname）
  → D. GRUB 启动参数（完整 cmdline）
  → E. 磁盘格式（4K 原生 GPT + 4K FAT32 ESP）
  → F. 无状态校验（盘内零身份硬编码）
  → 克隆分发
```

每个阶段标注了"为什么"——三个历史阻塞点（`0x7f22208e`、`ret=401`、断链）全部对应具体步骤，缺一步即复现。

### 1.1 一键脚本（推荐）

A–F 全部阶段已自动化，**在母盘系统内以 root 运行**：

```bash
# 脚本与 initramfs-nbft 组件需位于同一仓库目录（默认取脚本上一级的 initramfs-nbft）
sudo bash test/golden-image-setup-debian12.sh          # 全流程（E 阶段交互确认）
sudo bash test/golden-image-setup-debian12.sh --yes    # E 阶段不交互
sudo bash test/golden-image-setup-debian12.sh --skip-disk --yes  # 跳过 E（仅 A-D+F）
sudo bash test/golden-image-setup-debian12.sh -d /path/to/initramfs-nbft -k 6.12.95+deb12-amd64
```

脚本行为与下方手工步骤一一对应，另含两类自动处理：

- 注释安装器残留的 `deb cdrom:` apt 源（无光驱环境 `apt-get update` 硬失败）；
- `GRUB_CMDLINE_LINUX_DEFAULT` 追加 SAN 参数时**同步移除 `quiet`**（见第 5 节）。

验证边界：脚本 A–D+F 已在 chroot 环境实测通过（幂等重跑安全）；**E 阶段（磁盘格式）必须在真实目标盘上运行**，chroot/容器内不可执行，其转换逻辑经离线单测验证。

## 2. A. 系统与内核

```bash
# Debian 12 最小安装后：
sudo apt install nvme-cli jq initramfs-tools

# bookworm-backports 6.12 内核（必须，理由见下）
sudo apt install -t bookworm-backports linux-image-6.12.95+deb12-amd64
```

- **为什么 6.12**：6.1 内核 `CONFIG_NVME_AUTH is not set`，对 nvmet `AUTH=1` 的 ATR 置位响应返回 `-EOPNOTSUPP` → 内核段认证失败 `ret=401`（0x191）。6.12 起 `CONFIG_NVME_AUTH=m`，内核段 DH-HMAC-CHAP 协商正常。
- 验证：`grep CONFIG_NVME_AUTH /boot/config-$(uname -r)` 应为 `=m`。

## 3. B. initramfs 种子模块（initramfs-nbft）

组件来自 `initramfs-nbft/`（nbft-connect 核心脚本 + initramfs-tools hook/local-top）：

```bash
# local-top 目录可能不存在，先确保存在
sudo mkdir -p /usr/share/initramfs-tools/scripts/local-top

sudo install -m 0755 nbft-connect /usr/local/sbin/
sudo install -m 0755 initramfs/hooks/nbft /usr/share/initramfs-tools/hooks/
sudo install -m 0755 initramfs/scripts/local-top/nbft \
    /usr/share/initramfs-tools/scripts/local-top/

sudo update-initramfs -u
# 验证组件在位
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'nbft|local-top'
```

### 3.1 hostid 修复（实测必需）

内核 nvme-fabrics host tracking 拒绝 DMI 默认 hostid 下的自定义 hostnqn（`found same hostid but different hostnqn`）。`nbft-connect` 必须：

1. 默认值兜底：`HOSTID="${HOSTID:-11111111-2222-3333-4444-555555555555}"`
2. 显式注入：`[ -n "$HOSTID" ] && cmd="${cmd} --hostid '${HOSTID}'"`

### 3.2 运行约束

- `nbft-connect` 须以 **dash/ash** 运行（initramfs 默认 `/bin/sh`）：NBCT 字段提取依赖命令替换在首个 NUL 字节截断的语义，bash 4.4+ 保留 NUL 导致空字段误判；
- 可选：`/etc/initramfs-tools/conf.d/nvme-cli` 写 `NO_NBFT_IN_INITRAMFS=yes` 可在打包时禁用（对齐 open-iscsi 的 `NO_ISCSI_IN_INITRAMFS`）。

## 4. C. 系统配置

### 4.1 fstab：固定 root UUID + 注释 /boot/efi

- root 分区在 fstab 中写死 **UUID**（克隆后静态可写），示例：
  ```
  UUID=d0a8ebeb-202b-4481-9f52-9eae81af44be / ext4 defaults 0 1
  ```
- **注释 `/boot/efi` 行**（`#UUID=855B-91DF /boot/efi vfat umask=0077 0 1`）：
  - 为什么：SAN 场景 ESP 由固件（iPXE/GRUB）独占读取，系统内挂载无意义；不注释则 systemd 挂载 4K FAT ESP 失败 → `local-fs.target` 失败 → **emergency mode**（第 11 轮实测教训，引导链本身不受影响但无法登录）。

### 4.2 网络：全链路 DHCP，禁止二次 HTTP 取凭证

```ini
# /etc/systemd/network/10-dhcp.network
[Match]
Name=e*

[Network]
DHCP=yes
```

- 为什么：initramfs 阶段 `configure_networking` 需要与系统阶段一致的 DHCP 行为；凭据经 NBCT 表**带内传递**（固件 → 内核），禁止内核侧二次 HTTP 取凭证；
- 内核 cmdline 侧配套 `ip=dhcp`（见 D 节）。

### 4.3 hostname：不硬编码

- 母盘内 hostname 仅为占位（如 `debian`），生产 hostname 由控制面下发，不属于母盘职责。

## 5. D. GRUB 启动参数（完整版，缺一不可）

```bash
# /etc/default/grub，追加到 GRUB_CMDLINE_LINUX_DEFAULT：
# 同时移除默认的 quiet：quiet 把 console 日志压到 WARNING，会抑制 info 级内核打印
# （含 nvme 认证成功日志）——第 8 节验收判据 1 要求串口可见内核段 authenticated
GRUB_CMDLINE_LINUX_DEFAULT="net.ifnames=0 biosdevname=0 ip=dhcp nbft_auto \
systemd.mask=NetworkManager.service systemd.mask=systemd-networkd.service"
sudo update-grub
```

| 参数 | 作用 |
|---|---|
| `net.ifnames=0 biosdevname=0` | 稳定网卡命名（initramfs 与 systemd 阶段接口名一致） |
| `ip=dhcp` | initramfs 网络配置入口（对齐 `configure_networking`） |
| `nbft_auto` | 启用 NBFT 自动消费（对齐 iSCSI 的 `iscsi_auto` 语义） |
| `systemd.mask=NetworkManager.service` `systemd.mask=systemd-networkd.service` | **防断链**：networkd 接管网卡会重置 TCP → keep-alive 超时 → `no usable path` 断链循环（第 10 轮实测教训）。mask 后 `systemd-networkd-wait-online` Dependency failed 为无害预期 |

## 6. E. 磁盘格式（SAN 形态，最关键）

nvmet file backend 以 **4096 B 逻辑块**导出（`i_blkbits`），盘必须是 4K 语义：

### 6.1 4K 原生 GPT

- 为什么：512 扇区 GPT 的备份头/分区表在 4K 块语义下错位 → EDK2 PartitionDxe 找不到 GPT → ESP 不枚举 → sanboot `0x7f22208e`（EFI_NOT_FOUND）；
- 布局：GPT 头 @4096、分区表 @8192、备份头 @盘尾，分区字节范围零改动；
- 转换：参考实现 `diag/convert-gpt-4k.sh`（python 重写 GPT，转换前自动备份旧 GPT 到 `.gpt-512.bak`，完成后 verify 签名/CRC + spot-check FAT32 BPB / ext4 magic / SWAPSPACE2）。

### 6.2 4K FAT32 ESP（p1）

- volid `855B-91DF`（fstab 引用值），内容：
  - `vmlinuz-6.12.95+deb12-amd64`（6.12 内核，对应 B 节）
  - `initrd.img-6.12.95+deb12-amd64`（**hostid 修复版**；initrd 为多段结构：前 148480 B 微码段 + zstd 压缩 cpio 段，拼接公式 `段1偏移 + 段2长度`，替换段 2 时用 `cat 段1 zstd > 新initrd` 而非 `>>` 追加）
  - `EFI/BOOT/BOOTX64.EFI`（GRUB 2.14，`grub-mkimage` 定制）
  - `EFI/BOOT/grub.cfg`（SAN 引导菜单，见下）

- **为什么必须是 `EFI/BOOT/BOOTX64.EFI`**：Debian 安装器只写 `EFI/debian/`（shim/grub），不创建 `EFI/BOOT/` 可移动介质 fallback。固件侧若没有持久化的引导项（全新 NVRAM、清 CMOS 后、或 iPXE `sanboot` 完成后固件重扫盘），只按标准 fallback 路径 `\EFI\BOOT\BOOTX64.EFI` 找引导器——找不到即跳过该盘（实测：OVMF 报 `BdsDxe: failed to load Boot0002 ... Not Found` 后转入 PXE）。E 阶段重建 ESP 时用 `grub-mkimage` 写 `EFI/BOOT/BOOTX64.EFI`，既是 SAN 冷启动的入口，也让母盘在任意 UEFI 机器上可直接本地引导（2026-09-02 本地引导验证即依赖此文件）。
```cfg
# EFI/BOOT/grub.cfg 参考
set default=0
set timeout=5
menuentry 'Debian GNU/Linux 12 (SAN, 6.12.95+deb12-amd64)' {
    search --no-floppy --fs-uuid --set=root 855B-91DF
    linux /vmlinuz-6.12.95+deb12-amd64 root=UUID=d0a8ebeb-202b-4481-9f52-9eae81af44be ro console=ttyS0,115200 net.ifnames=0 biosdevname=0 ip=dhcp nbft_auto systemd.mask=NetworkManager.service systemd.mask=systemd-networkd.service
    initrd /initrd.img-6.12.95+deb12-amd64
}
```

- 注意：GRUB 走 `search --fs-uuid 855B-91DF` 定位 ESP——4K FAT 的卷标/UUID 必须与 fstab 注释行、grub.cfg 三者一致。

## 7. F. 无状态校验（验收）

```bash
# 盘内零身份硬编码：以下 grep 应无命中
grep -rn "hostnqn\|dhchap\|secret\|kurrent:host" /etc /usr/local/sbin /usr/share/initramfs-tools 2>/dev/null
grep -n "HOSTNAME\|hostname" /etc/hostname /etc/hosts   # 仅占位值
```

- 身份（hostnqn / 密钥 / hostid）由引导链外部注入：控制面 boot-vars 下发 → iPXE 固件消费 → NBCT 表带内传递 → 内核复用；
- hostid 例外：`nbft-connect` 内置默认 hostid 兜底（B 节 3.1），属固件侧契约，不落盘身份文件。

## 8. 克隆即用验证

### 8.1 本地引导预检（定制后、转 4K 前可选）

镜像仍是 512 GPT 时可在 QEMU/VMware 本地引导一轮，先确认定制本身无问题（降低 SAN 验收的变量）：

- 前提：ESP 存在 `EFI/BOOT/BOOTX64.EFI`（6.2 节；安装器原始 ESP 需手工补一份，或直接进入 E 阶段后不再需要本地预检）；
- 判据：GRUB 菜单出现 → 6.12 内核引导 → 系统启动（VGA 出现 `debian login:`，`Ctrl+Alt+F2` 可确认 tty2 登录提示）；
- 注意：cmdline 的 `systemd.mask=NetworkManager/networkd` 生效后，本地引导场景网络不会自动配置（SAN 场景由 initramfs NBFT 流程接管，不受影响）；tty1 可能被模板遗留程序占用，不影响系统。

2026-09-02 已对 chroot 定制后的 VMware Debian 12 镜像执行过一轮：引导链完整（OVMF → GRUB → 6.12 → initramfs → systemd → getty），随后 cmdline 刷新（移除 quiet）后再未复测引导。

### 8.2 SAN 冷启动验收（交付主项目前的最后一轮）

母盘写回磁盘后，QEMU + nvmet 冷启动一轮（复现步骤与判据见 [production-boot-verification.md](production-boot-verification.md) §5）：

- 判据 1：串口出现 `qid 0: authenticated with hash hmac(sha256) dhgroup ffdhe4096`（固件段 + 内核段各一次）；
- 判据 2：`nvme0n1: p1 p2 p3` → rootfs 挂载 → `Welcome to Debian` → `debian login:`；
- 判据 3：无 keep-alive 错误、无 emergency mode；
- pcap 级判据：双 ATR（Connect RSP result bit17 `0x20000`）+ 两轮 AuthSend/AuthReceive 各 4 PDU，全部 status=0。

**给主项目使用的交付前置**：定制（A–F）完成、且 8.2 这轮 SAN 冷启动验收通过后，母盘即可克隆分发交主项目使用。其中 E 阶段（4K 转换 + ESP 重建）是 SAN 可引导的必要步骤，且需在真实目标盘上执行——截至 2026-09-02，脚本 A–D+F 已实测，E 尚未在真实盘端到端运行（离线单测已过），首次真机执行建议伴随 8.2 验收一并完成。

## 9. 常见问题速查（对应三个历史阻塞点）

| 现象 | 根因 | 修复 |
|---|---|---|
| sanboot `0x7f22208e`（EFI_NOT_FOUND） | GPT 512 扇区 vs nvmet 4096B 块 | 6.1 节 4K 原生 GPT |
| 内核段 `ret=401`（AUTH_REQUIRED） | 内核无 CONFIG_NVME_AUTH | 2 节 6.12 backports |
| 登录后 keep-alive 断链 `-101` 循环 | systemd 网络接管重置 TCP | 5 节 cmdline mask |
| boot-efi.mount 失败 → emergency | fstab 未注释 /boot/efi | 4.1 节注释 |
| OVMF 报 `failed to load Boot0002 ... Not Found` 后转 PXE | ESP 无 `EFI/BOOT/BOOTX64.EFI` fallback（安装器只写 `EFI/debian/`，2026-09-02 本地引导验证确认） | 6.2 节 E 阶段重建 ESP 写入 BOOTX64.EFI |
| 串口看不到内核段 `authenticated`（仅固件段一次） | cmdline 带 `quiet`（console 日志压到 WARNING） | 5 节 D 段移除 quiet |

## 10. 跨发行版支持现状（支持基线）

> **裁定（2026-08-27）**：低于下表各行基线的发行版不做适配。已有验证结果保留，但不投入新的适配工作；发行版升大版本后基线随之上移。

| 发行版 | 支持基线 | 内核 | 内核段认证（NVME_AUTH） | NBFT/initramfs 引导 | 母盘结论 |
|---|---|---|---|---|---|
| **Debian** 12 bookworm | 12.x | 6.1（需 backports 6.12） | ✗ 6.1 未启用（实测 `ret=401`），6.12 起启用 | ✗ initramfs-tools 无 NBFT | 需 backports 6.12 + 种子模块（本项目实测路径） |
| **Debian** 13 trixie | 13.x | 6.12.69+（已有 6.17 系列） | ✓ `nvme_auth` 模块实证 | ✗ 同上 | **免换内核**，仅需种子模块 |
| **Ubuntu** 24.04 LTS | 24.04.x | 6.8 | ✓ | ✗ 需种子模块 | 需种子模块 |
| **Ubuntu** 26.04 LTS | 26.04 | **7.0** | ✓（宿主本地 `lsmod` 实证） | ✗ | 需种子模块 |
| **RHEL** 9 | 9.x | 5.14 | ✓ 官方文档含认证配置章节 | dracut 95nvmf 传统引导 | 依赖官方组件 |
| **RHEL** 10 | 10.x | **6.12** | ✓ 官方专章（12.3 节"配置 NVMe 主机身份验证"） | 同上 | 依赖官方组件 |
| **SLES** 15 | SP5–SP7 | 6.4 | ✓ | ✓ 官方文档：装好即自动引导（nvme-stas 2.3+ NBFT 配置源） | **开箱即用** |
| **SLES** 16 | 16.x | **6.16** | ✓ | ✓ 同源 | **开箱即用** |
| **openSUSE** Leap 16 | 16.x | 6.16（可更新至 7.0） | ✓ | ✓ 与 SLES 同源 | **开箱即用** |
| **openSUSE** Tumbleweed | rolling | 7.x | ✓ | ✓ | **开箱即用** |
| **Fedora** | 44+ | **7.0.9** | ✓ | dracut 95nvmf 存在 | 部分 |
| **Arch** | rolling | 7.x | ✓ | nvme-cli 2.16 `nvmf-autoconnect` | 部分 |

### 生态层事实（2026-08 时点）

- **内核认证**：主线自 6.0 内置 `CONFIG_NVME_AUTH`；全部 LTS（5.10/5.15/6.1/6.6/6.12）2023-09 起 backport——**发行版是否启用才是变量**（Debian 12 的 6.1 即未启用的反例）；
- **NBFT 消费生态**：SUSE 主导（nvme-stas 2.3 起把 NBFT 作为配置源；dracut 95nvmf 含 NBFT 解析）；nvme-cli 2.5+ 提供 `nvme nbft show`；systemd initrd 的 NBFT 支持仍是未合并的 RFE（systemd #36443）；
- **对本项目**：种子模块（initramfs-nbft）在**所有非 SUSE 系**上都是必需件；Debian 13 / Ubuntu 26.04 可直接复用现有 `nbft-connect`，无需 6.12 backports 环节。

## 11. 参考资料

- `diag/convert-gpt-4k.sh`（4K GPT 转换参考实现）、`diag/esp4k-prod.img`（4K FAT32 ESP 参考产物）、`diag/grub-prod.cfg`（GRUB 菜单参考）、`diag/initrd-612-hostid.img`（hostid 修复 initrd 参考）
- [production-boot-verification.md](production-boot-verification.md)（全链路验证证据）
- [initramfs-nbft/README.md](../initramfs-nbft/README.md)（种子组件安装与测试）

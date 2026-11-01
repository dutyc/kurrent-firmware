# 母盘定制发行版矩阵

本仓库的母盘（golden image）资产按发行版组织：每个发行版一个自包含一键脚本，共享同一套
A-F 六阶段定制流程（流程原理与手工步骤见
[golden-image-customization-debian12.md](golden-image-customization-debian12.md)）；
宿主侧辅助脚本与打包器统一在 `test/shared/`。

所有 `golden-image-setup-*.sh` 均已内嵌 initramfs-nbft 三组件与 GRUB 2.14 产物
（base64），单文件即可拷入母盘运行；组件或 GRUB 产物更新后重跑
`python3 test/shared/embed-components.py` 重新内嵌（幂等）。

## 目录布局

```
test/
├── debian12/golden-image-setup-debian12.sh
├── debian13/golden-image-setup-debian13.sh
├── ubuntu2404/golden-image-setup-ubuntu2404.sh
├── ubuntu2604/golden-image-setup-ubuntu2604.sh
├── fedora44/golden-image-setup-fedora44.sh
├── almalinux10/                 # RHEL 系
│   ├── almalinux10.ks.in        # kickstart 模板（注入公钥）
│   ├── run-almalinux10-install.sh
│   └── golden-image-setup-almalinux10.sh
├── opensuse-leap16/             # SUSE 系
│   ├── leap16-profile.json      # Agama profile 模板（注入公钥）
│   ├── run-leap16-install.sh
│   └── golden-image-setup-leap16.sh
└── shared/                      # 各发行版通用
    ├── embed-components.py      # 单文件打包器（组件 + GRUB 产物内嵌）
    ├── golden-vm-run.sh         # 定制阶段 VM 启动（OVMF + slirp + SSH 2222 + QMP）
    ├── golden-ubuntu-vm-run.sh  # Ubuntu 定制 VM（seed 挂载 + 自动扩容 + SSH 2222）
    ├── golden-vm-sendkey.py     # QMP→HMP 键盘注入（无 sshd 时的交互通道）
    ├── golden-net-rebuild.sh    # 宿主重启后网络重建（br0/tap0 + NAT）
    ├── golden-nvmet-enable.sh   # nvmet namespace 启用（必须宿主 mount ns）
    ├── golden-esp-verify.sh     # 4K ESP 内容校验（512 逻辑扇区 + 偏移 loop）
    ├── fwtest-net.sh            # 隔离验收网桥 br-fwtest + tap0fw（root）
    ├── fwtest-nvmet-tls.sh      # 验收靶：DH-HMAC-CHAP host + TLS1.3/required 端口 + PSK
    ├── fwtest-boot.sh           # 隔离 PXE 冷启动（dnsmasq 容器 + QEMU/OVMF + 抓包）
    ├── pcap-flows.py            # 抓包判据：流首字节 0x16 / 明文凭据 / :4420 计数
    └── assets/BOOTX64-2.14-generic.EFI   # GRUB 2.14 产物（实测引导基线）
```

## 适配状态总览

| 发行版 | 版本 | 安装介质 | 无人值守 | 定制脚本 | 软件源 | 内核 | 验收状态 |
|---|---|---|---|---|---|---|---|
| Debian 12 | bookworm | netinst ISO | preseed（d-i） | `test/debian12/` | 阿里云（bookworm + backports） | 6.12.95+deb12-amd64（backports） | ✅ 2026-09-08 PXE 认证冷启动 → GDM |
| Debian 13 | 13.6.0 | netinst ISO | preseed（d-i） | `test/debian13/` | 阿里云（trixie，免 backports） | 6.12.94+deb13（自带） | ✅ 2026-09-10 PXE 认证冷启动 → login |
| Ubuntu 24.04 | 24.04.4 LTS | live-server ISO | autoinstall（subiquity） | `test/ubuntu2404/` | noble（deb822 ubuntu.sources） | 6.8 系（GA） | ✅ 2026-09-10 PXE 认证冷启动 → login |
| Ubuntu 26.04 | 26.04.1 LTS | live-server ISO | autoinstall（subiquity） | `test/ubuntu2604/` | suite 运行时检测（deb822） | 7.0.0-31-generic | ✅ 2026-09-11 PXE 认证冷启动 → login |
| Fedora 44 | 44（Server DVD 1.7） | DVD ISO | kickstart（Anaconda） | `test/fedora44/` | dnf：阿里云（fedora + updates） | 6.19.10-300.fc44（自带） | ✅ 2026-09-12 PXE 认证冷启动 → login |
| AlmaLinux 10.2 | 10.2（minimal ISO） | minimal ISO | kickstart（Anaconda，HTTP） | `test/almalinux10/` | dnf：华为云（BaseOS/AppStream/CRB/Extras） | 6.12.0-211.7.3.el10_2（自带，`CONFIG_NVME_TCP_TLS=y`） | ✅ 2026-10-31 PXE TLS 冷启动 → login（两轮） |
| openSUSE Leap 16.0 | 16.0（online installer） | online ISO（Agama） | Agama profile（`inst.auto=`） | `test/opensuse-leap16/` | zypper：TUNA OSS | 6.12.0-160000（自带，`CONFIG_NVME_TCP_TLS=y`） | ✅ 2026-10-31 PXE TLS 冷启动 → login |

验收判据（各发行版一致）：target 端出现 **两条**控制器记录——固件段与内核段各一次；
认证/加密按控制面下发的路径记录：DH-HMAC-CHAP 路径为 `..., DH-HMAC-CHAP`，
TLS 1.3 路径为 `..., TLS.`。串口出现登录提示。
TLS 路径另加抓包判据：到数据端口（4422/4421）的每条客户端 TCP 流首字节为 `0x16`，
PSK / DH-HMAC-CHAP 密钥不出现在明文载荷中，到明文端口 4420 的包数为 0
（`test/shared/pcap-flows.py` 自动判定）。

> 原生 NBFT 消费 ≠ 原生认证：RHEL 的 `nm-initrd-generator`/`95nvmf` 与 SUSE 的
> dracut `nvmf` 都能从 NBFT 自动建链，但 **NBFT 标准表不含 DH-HMAC-CHAP 密钥与
> TLS-PSK**，其代码路径是无凭据的 `nvme connect-all --nbft`。本仓库的
> `95nbft` 消费自定义 **NBCT** 表（携带凭据）并逐条 `nvme connect --dhchap-secret/--tls`；
> 构建时显式 `--omit nvmf`，避免原生模块抢先做无认证连接。

## 发行版差异对照

| 差异点 | Debian 系（12 / 13） | Ubuntu 系（24.04 / 26.04） |
|---|---|---|
| 安装器 | debian-installer | subiquity |
| 无人值守数据 | preseed.cfg（HTTP 提供） | autoinstall user-data + meta-data（nocloud-net HTTP） |
| APT 配置格式 | `/etc/apt/sources.list`（三行） | deb822（`ubuntu.sources` 覆写，原文件备份 `.golden-bak`） |
| 内核策略 | 12 用 backports（新版内核 + NVMe-oF 修复）；13 用自带 | 发行版自带内核即满足要求 |
| 版本适配方式 | 独立变体（trixie 源、免 backports 等） | suite 运行时检测（`VERSION_CODENAME`，免逐版硬编码） |
| 安装介质内核提取 | ISO 内 install.amd/vmlinuz（preseed 直启） | casper/vmlinuz + casper/initrd（26.04.1 的 initrd 无 `.gz` 后缀） |
| 其他要点 | volid 0x43 修复；4K ESP 重建（953 MiB FAT32） | 24.04 原 ESP 106 MiB → 重建 953 MiB；26.04 安装默认 953 MiB（仅 4K 化） |

### RHEL 系 / SUSE 系差异（相对前五者）

| 差异点 | RHEL 系（AlmaLinux 10.2） | SUSE 系（openSUSE Leap 16.0） |
|---|---|---|
| 安装器 / 无人值守 | Anaconda + kickstart（`inst.ks=http://…`） | Agama + JSON profile（`inst.auto=http://…`，`inst.finish=poweroff`） |
| 包管理 / 源 | dnf；BaseOS/AppStream/CRB/Extras 四段映射（镜像目录为 CamelCase） | zypper；保留 `$releasever`，覆写 OSS 到 TUNA |
| initrd 网络 | dracut-107 无 systemd-networkd → `35network-manager` + `nm-initrd-generator` + `ip=dhcp` | dracut 059+suse 同走 `35network-manager`（NetworkManager） |
| 原生 NBFT 模块 | `95nvmf` + `nm-initrd-generator`（NBFT ≈ Technology Preview） | dracut `95nvmf`（SUSE 扩展） |
| 原生模块的认证 | 无：`nvme connect-all --nbft`（不读 DH-HMAC-CHAP/TLS-PSK） | 无：同为 `connect-all --nbft` |
| 本仓库做法 | `--omit nvmf`，装 `95nbft`（NBCT → `connect --dhchap-secret/--tls`） | 同左 |
| 内核段 TLS 组件 | `keyutils` + `ktls-utils`（tlshd 1.2.1）；配置文件 `/etc/tlshd.conf` | `keyutils` + `ktls-utils`；`/etc/tlshd.conf` |
| GnuTLS 系统策略 | **必须把 `/etc/crypto-policies/back-ends/gnutls.config` 装进 initrd**，否则 tlshd 启动即 `gnutls -50` 退出 | 同左（文件存在时安装，缺失不阻断） |
| initrd 路径 | `/boot/initramfs-<KVER>.img` | `/boot/initrd-<KVER>`（拷入 ESP 改名 `initramfs-<KVER>`） |
| GRUB 工具 | `grub2-mkimage` / `grub2-mkconfig` | 同左 |
| 布局约束 | XFS（安装介质须 4K 逻辑块盘）；本变体为普通分区（非 LVM） | XFS；Agama 目标盘须为空白盘（残留 GPT 会让默认 `spacePolicy=keep` 与显式布局冲突） |

## 各发行版适配要点

### Debian 12（首个闭环版本，基线）
- 介质：netinst + preseed 自动安装；backports 内核（6.12 系，NVMe-oF 认证所需）
- 源切换：bookworm + bookworm-backports + security（阿里云，ForceIPv4）
- 验收轨迹：2026-09-08 单文件形态 A-F 实测（含 E）→ 同日 PXE 冷启动验收至 GDM

### Debian 13（netinst + 独立变体脚本）
- 介质：netinst 13.6.0 + preseed；内核用发行版自带（trixie 6.12 已满足）
- 与 debian12 变体差异：trixie 三行源、免 backports 步骤、`KVER=$(uname -r)`

### Ubuntu 24.04（cloud 形态弃用 → 标准安装）
- 介质：live-server ISO + autoinstall（标准安装形态，与手工安装一致）
- 源切换：deb822 `ubuntu.sources` 覆写（noble + noble-security）
- E 阶段：原 106 MiB ESP 重建为 953 MiB 4K FAT32

### Ubuntu 26.04（autoinstall 数据源与 subiquity 变化适配）
- 介质：live-server 26.04.1 ISO + autoinstall
- 26.04 三处变化（安装脚本必须适配，详见 `.cache/run-ubuntu2604-install.sh` 注释）：
  1. subiquity 新增 `source` section（可交互）——autoinstall 必须显式提供
     `source: {id: ubuntu-server}`，否则停在"安装类型选择"交互屏；
  2. QEMU `-kernel/-append` 直启（无 GRUB 层）时 `ds` 参数不能带 `\;` 转义——
     用裸分号 `ds=nocloud-net;s=http://<网关>:<端口>/`；
  3. 双 cdrom 枚举顺序可能反转（sr0=cidata / sr1=ISO）——`ds=nocloud;s=/dev/srN`
     按设备名不可靠，HTTP 方式与设备名无关。
- 源切换：suite 运行时检测（deb822），免逐版硬编码代号

### Fedora 44（首个 dracut / XFS / LVM 发行版）
- 介质：Server DVD + kickstart（HTTP，`inst.ks=`）；**安装须在 4K 逻辑块虚拟盘上进行**——
  XFS 扇区大小固定于 mkfs（跟随当时设备逻辑块），512 扇区 XFS 无法在 4096 逻辑块设备
  （SAN 4K 导出）上挂载（`XFS: device supports 4096 byte sectors (not 512)`）；
- 布局：XFS on LVM（anaconda 默认）→ 内核参数需 `rd.lvm.lv=<VG>/<LV>`；
- initramfs：dracut 95nbft 模块（`module-setup.sh` + `nbft.sh` 双挂载
  `initqueue/settled` 与 `pre-mount`，`/run/nbft-done` 去重）；依赖 `dracut-network`
  与 `systemd-networkd` 包（基础 dracut 无 initrd 网络模块），initrd 内配网用
  `09-nbft.network`（networkd，DHCP + KeepConfiguration）；
- LVM 激活：dracut 的 64-lvm.rules 挂在 `initqueue --settled`（本场景不执行）→
  钩子在连接后显式 `lvm vgchange -ay`；initrd 工具链需含 `dd`（nbft-connect 字段
  提取器依赖，`--no-hostonly` 默认不含）；
- 工具名差异：`grub2-mkimage` / `grub2-mkconfig`，initrd 文件名为
  `initramfs-<KVER>.img`。

### AlmaLinux 10.2（首个 RHEL 系）
- 介质：AlmaLinux 10.2 minimal ISO + kickstart（HTTP 提供）；目标盘 4K 逻辑块
  virtio-blk（XFS 安装约束同 Fedora 44）。
- kickstart 与 minimal ISO 的边界：10.2 minimal 仓库**不含 ktls-utils**，kickstart 用
  `%packages --ignoremissing` 且不列该包；A 阶段再从完整镜像安装 `keyutils ktls-utils`。
- initrd：dracut-107 **无 systemd-networkd** → `--add "nbft network network-manager"`，
  `nm-initrd-generator` 读 `ip=dhcp` 配网；**`--omit nvmf`** 关闭原生无凭据连接；
  `95nbft` 在 `initqueue/settled` 与 `pre-mount` 双挂载、`/run/nbft-done` 去重。
- **crypto-policies 是 initrd 的硬依赖**：GnuTLS 的 `@SYSTEM` 默认优先级来自
  `/etc/crypto-policies/back-ends/gnutls.config`；dracut 默认不打包该文件，缺失时
  tlshd 启动即报 `gnutls: The request is invalid. (-50)` 并退出，随后
  `nvme connect --tls` 以 `failed to start TLS: -3` 失败、进入 emergency mode。
  `95nbft` 的 `module-setup.sh` 现以 `readlink -f` 解析符号链接后装机（实测 3384 B）。
- 源切换：`/etc/yum.repos.d/almalinux*.repo` 的段落名为小写（baseos/appstream/crb/extras），
  镜像目录为 CamelCase（BaseOS/AppStream/CRB/extras）——脚本用显式映射改写，
  并禁用其余仓库（含 debuginfo）。
- `nbft-connect` 的 shell 可移植性：RHEL 无 dash，A 阶段把脚本安装为
  `/usr/libexec/nbft-connect` 并由 **bash** 调用；NBCT 固定宽度字段提取改为
  `dd | tr -d '\000'`（不依赖特定 shell 的 NUL 截断语义），dash 下单测同样通过。
- 验收轨迹（2026-10-31，QEMU/OVMF + 隔离网桥 `br-fwtest`，target `192.168.81.1:4422`
  tls1.3/required）：两轮 PXE 冷启动均到 `login:`；每轮 target 端两条
  `nvmet: Created nvm controller … , TLS.`（固件段 + 内核段）；抓包 4 条客户端流
  首字节均为 `0x16`、无 PSK/DHHC 明文、`:4420` 包数 0。
  第 2 轮先用 `--skip-disk --yes` 重跑定制（验证 ESP 内容刷新路径）。
  证据（worktree `diag/`，凭据字段已脱敏）：`alma10-boot.serial`、
  `alma10-tls-handshake.pcap`、`target-dmesg.txt`。
- 版本边界：代表版本选 10.x（6.12 内核，实测 `CONFIG_NVME_TCP_TLS=y`）。RHEL 9.7
  **未纳入实测**——其内核为 5.14 系，NVMe/TCP TLS 是上游 6.7+ 特性，是否由 Red Hat
  回移未验证；若要在 9.x 落地，先核对 `CONFIG_NVME_TCP_TLS` 与 ktls-utils 版本。

### openSUSE Leap 16.0（首个 SUSE 系）
- 介质：Leap 16.0 online installer（Agama）+ JSON profile；目标盘 4K 逻辑块、**空白盘**。
- Agama 边界：`inst.auto=<URL>` 载入 profile（`inst.finish=poweroff`）；
  profile 通过 JSON Schema（`agama config validate`）≠ 存储方案可计算——目标盘若残留
  旧 GPT 分区，默认 `spacePolicy=keep` 与显式 ESP/`/` 布局冲突，报
  `Cannot calculate a valid storage setup`；母盘安装前须清空磁盘。
- initrd：dracut `059+suse` 同走 `35network-manager`；**`--omit nvmf`**、
  `95nbft` 逐条带凭据连接；`/etc/tlshd.conf` 与 crypto-policies 文件进 initrd；
  dracut 产物为 `/boot/initrd-<KVER>`，拷入 ESP 时改名 `initramfs-<KVER>`
  （与 `grub.cfg` 的 `initrd` 行一致）。
- 验收轨迹（2026-10-31，QEMU/OVMF + 隔离网桥，target `192.168.81.1:4423`
  tls1.3/required）：Agama 无人值守安装 → 本地 `-kernel/-initrd` 启动母盘跑 A-F
  （ESP 重建 4K FAT32 953 MiB）→ PXE 冷启动到 `login:`；target 两条
  `nvmet: Created nvm controller … , TLS.`（固件段 + 内核段）；抓包 4 条客户端流
  首字节均 `0x16`、无凭据明文、`:4420` 包数 0。内核段 tlshd 为 SUSE 的
  ktls-utils 1.0.0-pre，日志 `Handshake … was successful`。
  证据（worktree `diag/`，凭据字段已脱敏）：`leap16-boot.serial`、
  `leap16-tls-handshake.pcap`、`target-dmesg.txt`。

## 新增发行版适配流程（速查）

1. 从最接近的现存变体派生脚本（`test/<distro>/golden-image-setup-<distro>.sh`），
   逐参数核对：介质内核/initrd 文件名、preseed/autoinstall/kickstart 引导参数与
   包管理器源格式；**目标盘用 4K 逻辑块虚拟盘**（XFS 安装约束）；
2. 准备安装 VM 与目标 raw 盘（SUSE 系须空白盘）；跑通无人值守安装至自动关机；
3. `test/shared/golden-vm-run.sh`（或 `golden-ubuntu-vm-run.sh`）启动定制 VM，
   scp 脚本后执行 A-F；`--skip-disk --yes` 只跳过 GPT/ESP 重建，**仍刷新 ESP 内容**
   （内核/initrd/BOOTX64/grub.cfg），保证新 initrd 一定进入 ESP；
4. 宿主隔离验收（不动生产 br0/4421）：
   ```bash
   sudo bash test/shared/fwtest-net.sh setup          # br-fwtest + tap0fw
   sudo bash test/shared/fwtest-nvmet-tls.sh setup <raw> <subnqn> <hostnqn> <DHHC> \
        192.168.81.1 4422 3                          # tls1.3 / treq=required
   TRSVCID=4422 bash test/shared/fwtest-boot.sh --nqn <subnqn> \
        --secret '<DHHC-1:..>' --psk <hex> --serial diag/x.serial --pcap diag/x.pcap
   python3 test/shared/pcap-flows.py diag/x.pcap --port 4422 --secret '<DHHC-1:..>' --psk <hex>
   ```
   判据：串口 `login:`；宿主 dmesg 两条 `nvmet: Created nvm controller … , TLS.`；
   脚本输出 `ALL_TLS_HANDSHAKE`、`plaintext_markers=none`、`packets_to_4420=0`。
   抓包体积大时可加 `PCAP_MAXLEN=160`（只留首部与握手前缀）；
5. 组件变更后重跑 `test/shared/embed-components.py` 刷新内嵌段，再跑
   `test/test-nbft-connect-nbct.sh`（默认 dash；`SHELL_UNDER_TEST=bash` 覆盖 bash）。

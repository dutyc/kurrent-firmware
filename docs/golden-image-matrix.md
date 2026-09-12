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
└── shared/                      # 各发行版通用
    ├── embed-components.py      # 单文件打包器（组件 + GRUB 产物内嵌）
    ├── golden-vm-run.sh         # 定制阶段 VM 启动（OVMF + slirp + SSH 2222 + QMP）
    ├── golden-ubuntu-vm-run.sh  # Ubuntu 定制 VM（seed 挂载 + 自动扩容 + SSH 2222）
    ├── golden-vm-sendkey.py     # QMP→HMP 键盘注入（无 sshd 时的交互通道）
    ├── golden-net-rebuild.sh    # 宿主重启后网络重建（br0/tap0 + NAT）
    ├── golden-nvmet-enable.sh   # nvmet namespace 启用（必须宿主 mount ns）
    ├── golden-esp-verify.sh     # 4K ESP 内容校验（512 逻辑扇区 + 偏移 loop）
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

验收判据（各发行版一致）：target 端
`nvmet: Created nvm controller N ... with DH-HMAC-CHAP` 双记录（固件段 + 内核段各一次），
串口出现登录提示。

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

## 新增发行版适配流程（速查）

1. 从最接近的现存变体派生脚本（`test/<distro>/golden-image-setup-<distro>.sh`），
   逐参数核对：介质内核/initrd 文件名、preseed/autoinstall 引导参数、APT 源格式与代号；
2. 准备安装 VM 与目标 raw 盘；跑通无人值守安装至自动关机；
3. `test/shared/golden-vm-run.sh`（或 `golden-ubuntu-vm-run.sh`）启动定制 VM，
   scp 脚本（+ `BOOTX64-2.14-generic.EFI`）后执行 A-F；
4. 宿主侧：`golden-nvmet-enable.sh` 指盘启用 target → 复用全链路验收脚本
   （`.cache/run-kurrent-e2e.sh`）冷启动，核对双认证记录与登录提示；
5. 组件变更后重跑 `test/shared/embed-components.py` 刷新内嵌段。

# 真实重装与 TLS 冷启动验收排障记录（Debian 13 / Ubuntu 26.04）

> 状态：**通过**（2026-11-27）。两台样本均从 ISO 真实安装、在盘内执行 A–F 定制，并经 QEMU + OVMF 从 iPXE 冷启动到 `login:`，目标端各出现固件段与内核段两条 `..., TLS.` 控制器记录。
>
> 关联文档：[golden-image-matrix.md](../golden-image-matrix.md)（发行版矩阵与验收判据）、[golden-image-customization-debian12.md](../golden-image-customization-debian12.md)（A–F 手工步骤）、[nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md)（认证状态机排障）。

## 1. 范围与环境

本轮样本为 Debian 13 与 Ubuntu 26.04；AlmaLinux 10.2 与 openSUSE Leap 16.0 按计划暂停，ISO 保留未运行。原定的 Debian 12 样本由 Debian 13 替换，Debian 12 的失败证据保留（见 3.1）。

| 项 | Debian 13 | Ubuntu 26.04 |
|---|---|---|
| ISO | `debian-13.6.0-amd64-netinst.iso` | `ubuntu-26.04.1-live-server-amd64.iso` |
| 安装方式 | preseed（d-i） | autoinstall（subiquity，nocloud-net） |
| 内核 | 6.12.94+deb13-amd64 | 7.0.0-44-generic |
| 定制脚本 | `test/debian13/golden-image-setup-debian13.sh` | `test/ubuntu2604/golden-image-setup-ubuntu2604.sh` |
| 根文件系统 | ext4（直连分区） | ext4（LVM） |
| 安装盘 | 10 GiB raw，UEFI | 10 GiB raw，UEFI |

冷启动靶场使用 `test/shared/fwtest-net.sh`（`br-fwtest` 192.168.81.1/24 + `tap0fw`）、`test/shared/fwtest-nvmet-tls.sh`（nvmet 4K 文件后端，`tls1.3`、`treq=required`，host NQN 进入 `allowed_hosts`）与 `test/shared/fwtest-boot.sh`（iPXE 固件、串口日志、`filter-dump` 抓包）。判据按矩阵执行：

- 串口出现 `login:`；
- 目标端 dmesg 出现两条 `nvmet: Created nvm controller ... , TLS.`（固件段与内核段各一条）；
- 到数据端口的每个客户端 TCP 连接首载荷为 `0x16`；
- 到明文端口 4420 的包数为 0；
- DH-HMAC-CHAP 密钥与 TLS PSK 不出现在 TCP 明文载荷中。

## 2. 验收结果

| 样本 | `login:` | 控制器记录 | 抓包 | 结论 |
|---|---|---|---|---|
| Debian 13 | 通过 | 控制器 1（固件段）、控制器 2（内核段），均 `, TLS.` | 4 条客户端连接首载荷均为 `0x16`；`:4420` 为 0；TCP 载荷中无密钥 | 通过 |
| Ubuntu 26.04 | 通过 | 控制器 1（固件段）、控制器 2（内核段），均 `, TLS.` | 4 条客户端连接首载荷均为 `0x16`；`:4420` 为 0；TCP 载荷中无密钥 | 通过 |

抓包工具 `test/shared/pcap-flows.py` 对两份抓包输出了 `NON_TLS_STREAM_PRESENT`，原因是该工具按“序号连续”聚合流：抓包 snaplen 为 1500 字节、存在截断与重组空洞时，同一连接中段的应用数据会被重新起算成一条新“流”，首字节显示为 `0x17`。按 TCP SYN 重新统计，两台各 4 条连接（源端口分别为 33278/55279/55274/55282 与 17350/27215/38568/38570），每条连接的首个载荷均为 `0x16`。`0x17` 记录与所属握手连接同源端口，属于已建立 TLS 连接上的应用数据。该差异属于分析工具的口径问题，不影响“连接建立即 TLS”的事实；工具修正列入残留事项。

另有残留明文面：两份抓包各命中一条 TFTP 数据包（Debian 为 UDP 30480→48180），内容为 iPXE 引导脚本，携带 `secret=<redacted>` 与 `tls_psk=<redacted>`。该明文位于引导器投递通道，不在 4422 的 NVMe/TCP 会话内；本轮未改动投递方式。

## 3. 问题链

### 3.1 Debian 12：内核镜像缺少 ktls-utils

- 现象：hostnqn 对齐后固件段 TLS 正常，内核段在 initramfs 报 `nbft: WARNING: tlshd not found, TLS sessions will fail`，随后 `failed to start TLS: -3`，无法挂载远端根。
- 根因：bookworm 软件源不提供 ktls-utils，initramfs 内没有 `tlshd`，内核的 TLS 握手 upcall 无监听者。
- 处理：该样本按裁定替换为 Debian 13；原始失败证据保留在 `.local/reports/real-reinstall-2026-11-26/debian12/`。同一轮还暴露 Debian 12 安装器未写 `\EFI\BOOT\BOOTX64.EFI`，需以 mtools 从 `grubx64.efi` 补写；Debian 13 安装器已自带该回退文件。

### 3.2 Debian 13：tlshd 默认配置路径与钩子不一致

- 现象：`nbft: WARNING: tlshd exited, TLS sessions will fail`，随后 `failed to start TLS: -3`。
- 排查：解包 initrd 后用 `chroot` 直接运行 tlshd——带 `-c /etc/tlshd/config` 可常驻，裸运行立即报 `Failed to load config file: No such file or directory` 并退出。initrd 中只有 `/etc/tlshd/config`（钩子创建），没有 tlshd 默认查找的 `/etc/tlshd.conf`。
- 根因：`initramfs-nbft/initramfs/scripts/local-top/nbft` 以裸 `tlshd` 启动，ktls-utils 1.0.0 的默认配置路径是 `/etc/tlshd.conf`。
- 修复：`local-top` 改为 `tlshd -c /etc/tlshd/config`，与钩子投递的文件一致（提交 `158f4c8`）。

### 3.3 Debian 13：initramfs 缺少 kTLS 加密模块

- 现象：tlshd 常驻后握手推进到服务端成功，但内核侧报 `nvme nvme0: queue 0: TLS handshake complete, error -5`，随后 `could not add new controller`。
- 排查：
  - 在已运行的 Debian 13 系统内手动注入同一 PSK 并执行 `nvme connect --tls`，连接成功，说明 tlshd 1.0.0 与内核本身可用；
  - 解包 initrd 检查模块树，`tls.ko`、`nvme-keyring.ko` 存在，但 `gcm.ko`、`ccm.ko`、`chacha20poly1305.ko`、`ghash*.ko`、`aesni-intel.ko` 均不存在；
  - 运行系统在连接时加载了 `aesni_intel`、`ghash_clmulni_intel`、`crypto_simd` 等模块。
- 根因：TLS 握手结束后，kTLS 通过内核 crypto API 安装协商出的 AEAD 密钥。initramfs 阶段根文件系统尚未挂载，内核无法从盘上自动加载这些模块，安装密钥返回 EIO，内核以 `-5` 上报；握手本身已成功，因此服务端日志显示成功而客户端失败。
- 修复：`initramfs-nbft/initramfs/hooks/nbft` 增加 `gcm`、`ccm`、`chacha20poly1305`、`ghash-generic`、`aesni-intel`、`ghash-clmulni-intel`；`test/shared/golden-common.sh` 的 dracut 钩子同步增加同样模块；重新生成各发行版脚本的内嵌副本（提交 `158f4c8`）。

### 3.4 Ubuntu 26.04：LVM 根导致 E 阶段无法定位整盘

- 现象：A–D 完成后，E 阶段报 `ERROR: cannot locate the disk holding root ()`。
- 原因：26.04 的 subiquity 默认创建 LVM 根，`/` 为 `/dev/mapper/ubuntu--vg-ubuntu--lv`，`lsblk` 的 `PKNAME` 为空，`root_disk` 无法回溯到 `/dev/vda`。
- 修复：`test/ubuntu2604/golden-image-setup-ubuntu2604.sh` 启用共享库已有的 ESP 所在盘回退（`PHASE_E_LVM_FALLBACK=1`），提交 `501b1c7`。重跑后 E 阶段输出 `root: /dev/mapper/ubuntu--vg-ubuntu--lv  disk: /dev/vda  ESP: /dev/vda1 (538 MiB)`，GPT 512→4K 转换与 4K FAT32 ESP 重建完成。

### 3.5 Ubuntu 安装器在更新阶段长时间无输出

- 现象：首次 autoinstall 在 `run_unattended_upgrades` 阶段长时间没有串口输出，无法在预定时间内完成。
- 处理：删除 autoinstall 中不被该版本 subiquity schema 接受的 `updates: none`（该字段只接受 `security`/`all`），并显式指定镜像源后重装。最终安装日志完整，`subiquity/Install/install` 正常结束并关机。

### 3.6 操作与靶场陷阱

- **hostnqn 必须与目标端 PSK 身份一致**：服务端按 `NVMe0R01 <hostnqn> <subnqn>` 查找 PSK。Debian 12 首轮把目标端 hostnqn 设为 `host.test`，而 iPXE 使用默认 `nqn.2014-08.org.ipxe:ipxe`，客户端身份在服务端无对应密钥，连接无法建立；改用默认 hostnqn 后固件段 TLS 通过，内核段仍因缺少 tlshd 失败。
- **同一镜像不可同时被本地 VM 与 nvmet 导出访问**：调试内核段时用 4K virtio 本地启动 Debian 13，同时又从该盘经 nvmet 导出并连接，ext4 出现 `bad block bitmap checksum` 并被重挂为只读；`e2fsck -f -y` 修复后重跑。该问题由并发访问引起，不是母盘脚本缺陷。
- **`mkswap --check` 会重写交换分区头**：修复文件系统后该命令改写了交换分区 UUID，与 fstab 记录不一致；用 `mkswap -U <原 UUID>` 恢复。
- **安装器控制台交互**：Debian 安装器的完成菜单在串口上无法输入，`finish-install/keep-consoles false` 仍保留菜单；安装完成并写入磁盘后直接停止安装器即可。Ubuntu subiquity 以串口日志判定阶段完成，不依赖交互。

### 3.7 抓包分析工具的中段重锚

见第 2 节。`pcap-flows.py` 以“源端口 + 序号衔接”判断连续流，抓包截断或空洞会把同一连接的后段应用数据当成新流，从而误报 `NON_TLS_STREAM_PRESENT`。验收现场以 SYN 为连接起点复核：两台各 4 条连接，首载荷全部为 `0x16`。该工具后续宜改为按 SYN 建立连接表，并对中段数据沿用所属连接。

## 4. 修复提交与静态验证

在 `refactor/governance-full` 分支（未 push，`main` 未动）：

| 提交 | 内容 |
|---|---|
| `158f4c8` | `fix(initramfs)`: tlshd 显式使用 `/etc/tlshd/config`；initramfs-tools 与 dracut 钩子补齐 kTLS AEAD/加速模块；重生成内嵌副本 |
| `501b1c7` | `fix(ubuntu2604)`: LVM 根时以 ESP 所在盘解析引导盘 |
| `4bf6f75` | `ci`: 新增 `test/ci-gates.sh boot` 门禁并在 CI 执行，检查 tlshd 配置路径与 kTLS 模块清单 |

静态门禁：`syntax`、`embed`、`boot` 通过。`shellcheck` 门禁本机未安装 shellcheck，未在本机执行，由 CI 安装后执行。本轮未重跑 `replay` 与 `build`：改动不涉及补丁链与固件构建输入。两台真实验收均为冷启动端到端，未使用替身。

## 5. 证据

证据目录：`.local/reports/real-reinstall-2026-11-26/`（不随仓库提交）。

| 内容 | 路径 |
|---|---|
| Debian 13 安装串口日志 | `debian13/install.serial` |
| Debian 13 A–F 定制日志 | `debian13/customize.log` |
| Debian 13 冷启动串口与抓包 | `debian13/final-coldboot.serial`、`debian13/final-coldboot.pcap` |
| Debian 13 目标端 dmesg | `debian13/target-dmesg.txt` |
| Debian 13 排障中间记录 | `debian13/round1..round6-coldboot.serial`、`debian13/tlshd-*.txt` |
| Debian 12 失败证据 | `debian12/` |
| Ubuntu 26.04 安装串口日志 | `ubuntu2604/install.serial` |
| Ubuntu 26.04 A–F 定制日志 | `ubuntu2604/customize.log` |
| Ubuntu 26.04 冷启动串口与抓包 | `ubuntu2604/coldboot.serial`、`ubuntu2604/coldboot.pcap` |
| Ubuntu 26.04 目标端 dmesg | `ubuntu2604/target-dmesg.txt` |
| 安装输入 | `debian13/preseed.cfg`、`ubuntu2604/user-data` |

安装盘镜像保留在 `/windows-c/test/real-reinstall-2026-11-26/{debian13,ubuntu2604}/raw.img`，可复跑冷启动。

## 6. 残留事项

- AlmaLinux 10.2 与 openSUSE Leap 16.0 未运行；两台的 kTLS 模块清单已随 dracut 钩子补齐，但未做真实冷启动验证。
- iPXE 引导脚本在靶场中经 TFTP 明文投递，携带 `secret=<redacted>` 与 `tls_psk=<redacted>`；生产投递方式与加固策略需单独确定。
- `pcap-flows.py` 的流划分应按 SYN 建表，避免抓包空洞导致的误报。

# 真实重装与 TLS 冷启动验收排障记录（Debian 13 / Ubuntu 26.04）

> 状态：**通过**（2026-11-27）。两台样本均从 ISO 真实安装、在盘内执行 A–F 定制，并经 QEMU + OVMF 从 iPXE 冷启动到 `login:`，目标端各出现固件段与内核段两条 `..., TLS.` 控制器记录。
>
> 关联文档：[golden-image-matrix.md](../golden-image-matrix.md)（发行版矩阵与验收判据）、[golden-image-customization-debian12.md](../guides/golden-image-customization-debian12.md)（A–F 手工步骤）、[nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md)（认证状态机排障）。

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

初版验收时使用的 `pcap-flows.py` 按“源端口 + 序号连续”聚合，抓包 snaplen 截断造成序号空洞后，同一 TCP 连接中段的应用数据被另算成新“流”，因此初版输出为 `NON_TLS_STREAM_PRESENT`（首字节 `0x17`）。该工具已改为按 TCP 连接聚合（提交 `a621283`，见 3.7）：连接以客户端 SYN 为起点，序号空洞、重传与 snaplen 截断后的载荷都归入原连接。用修正后的工具重跑本文两份抓包，均输出 `ALL_TLS_HANDSHAKE`：两台各 4 条连接（源端口分别为 33278/55279/55274/55282 与 17350/27215/38568/38570），每条连接的首个载荷均为 `0x16`。`0x17` 记录与所属握手连接同源端口，是同一连接上的 TLS 应用数据。

抓包中另有 TFTP 数据包命中 `secret`/`tls_psk` 字段值。这是隔离测试夹具的注入，不是生产引导链行为：`test/shared/fwtest-boot.sh` 自行生成 `boot.ipxe`，直接把 `secret=<redacted>` 与 `tls_psk=<redacted>` 写入脚本并经 TFTP 下发给被测固件。生产引导链的 TFTP `boot.ipxe` 只做 HTTPS 跳转，凭据经 HTTPS 的 `boot.ipxe.cfg` 与 TPM 证明后的 `/boot-vars` 下发，不经过 TFTP（见 3.8）。抓包文件不入库。

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

### 3.7 抓包分析工具的连接聚合修正（已修复）

初版 `pcap-flows.py` 以“源端口 + 序号衔接”判断连续流：一旦序号不连续（抓包截断、空洞或重传），同一 TCP 连接的后段载荷会被新建为另一条“流”，首字节记为 `0x17`/`0x30`，从而误报 `NON_TLS_STREAM_PRESENT`；截断包若无载荷还会在 `payload[0]` 处抛出异常。

修正（提交 `a621283`）改为按四元组建连接表：客户端 SYN 建立连接，同一四元组出现序号不同的新 SYN 视为端口复用后的新连接；缺少 SYN 的中途抓包以首个载荷建立连接；后续载荷不再依赖序号连续，空洞、重传与截断后的数据都归入当前连接。判据与退出码保持不变，连接计数字段改为 `client_connections_to_<port>`。

新增 `test/shared/test_pcap_flows.py`（仅标准库、自造抓包，覆盖序号空洞加 `0x17` 应用数据、真实首字节 `0x17`、四元组复用、SYN 重传、截断无载荷、无 SYN 中途抓包、marker 与 4420 计数），并通过 `test/ci-gates.sh pcap` 接入 CI（提交 `2108954`）。变异验证：同一组用例对修正前实现 6/7 失败（含截断包 `IndexError`），修正后全部通过。用修正后的工具重跑本文两份真实抓包，均输出 `ALL_TLS_HANDSHAKE`、`plaintext_markers=none`、`packets_to_4420=0`。

### 3.8 测试夹具的 TFTP 凭据注入

两份抓包中的 `secret`/`tls_psk` 命中来自隔离测试夹具，不是产品行为。`test/shared/fwtest-boot.sh` 为把凭据交给被测固件，自行生成 `boot.ipxe`，将 `secret=<redacted>` 与 `tls_psk=<redacted>` 直接写入脚本，并通过容器内 dnsmasq 的 TFTP 根目录下发。

生产引导链不同：TFTP 上的 `boot.ipxe` 只做 HTTPS 跳转，凭据经 HTTPS 的 `boot.ipxe.cfg` 与 TPM 证明后的 `/boot-vars` 下发，不经过 TFTP。该抓包命中仅反映隔离测试夹具的注入方式；归档文档不记录凭据值，抓包文件不入库。

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

# Debian 12 TLS-only 冷启动验收记录

> 状态：**通过**（2026-11-27）。从安装介质真实安装、在盘内执行 A–F 定制，并经 QEMU + OVMF 从 iPXE 冷启动到 `login:`；目标端出现固件段与内核段两条 `..., TLS.` 控制器记录。本轮不使用 trixie 软件源。
>
> 关联文档：[golden-image-matrix.md](../golden-image-matrix.md)（发行版矩阵与验收判据）、[golden-image-customization-debian12.md](../guides/golden-image-customization-debian12.md)（A–F 手工步骤）、[real-reinstall-tls-coldboot-verification.md](real-reinstall-tls-coldboot-verification.md)（上一轮 Debian 13 / Ubuntu 26.04 记录与靶场说明）。

## 代价与适用边界

> **结论先行**：Debian 12 的 TLS-only 引导是 **workaround**，不是 Debian 包管理路径。`ktls-utils`、`libnvme`、`nvme-cli` 三个组件由源码构建并直接写入 `/usr`，TLS-only 下的“支持”依赖这三个手工组件。

| 项 | 实测数据 |
|---|---|
| 源码 tarball 体积 | libnvme 561,412 B、nvme-cli 696,108 B、ktls-utils 42,156 B，合计 1,299,676 B（约 1.24 MiB）；构建时下载并逐项校验固定 SHA256 |
| 构建产物落盘体积 | `/usr/sbin/nvme` 5,448,592 B、`/usr/sbin/tlshd` 169,240 B、`libnvme.so.1.16.2` 733,088 B、`libnvme-mi.so.1.16.2` 170,992 B，合计 6,521,912 B（约 6.22 MiB），不含符号链接与 pkgconfig 文件 |
| 母盘保留的构建依赖 | 18 个显式包（meson、ninja-build、gcc、libc6-dev、autoconf、automake、libtool、pkg-config、build-essential、curl、xz-utils 及各 `-dev`）的 dpkg `Installed-Size` 合计 51,372 KiB（约 50.2 MiB）；其中部分为基础系统原有，脚本不卸载 |
| 构建耗时 | 未量化（定制日志没有逐命令时间戳） |
| 镜像增加量 | 未量化（没有未构建的基线镜像可对照；上述 tarball、产物与依赖给出了可核对的数量级） |

- 三个组件由源码构建后以 `make install` / `ninja install` 写入 `/usr`，不受 dpkg 管理：apt 不知道它们的版本，不会升级，也不会为它们打安全补丁。
- 母盘保留 meson、ninja、gcc、autotools 及各 `-dev` 构建依赖；脚本没有卸载这些包的步骤，移除需要逐包手工处理。
- 构建发生在母盘定制阶段：需要访问 Debian 源码池，下载并校验固定 SHA256 的 orig tarball，构建时间与镜像体积都增加。
- ABI 边界：Debian 若更新 glibc、gnutls、libnl 等被这些手工二进制链接的库，已安装的二进制需要重新构建。
- 适用边界：这是 workaround，不是 Debian 包管理路径；TLS-only 引导的可用性依赖上述三个手工组件。Debian 仓库现状（bookworm/backports 无 `ktls-utils`、自带 `nvme-cli 2.4` 无 `connect --tls`）是上游反馈依据。

## 1. 范围与环境

| 项 | 值 |
|---|---|
| 安装介质 | `debian-12.11.0-amd64-DVD-1.iso`（d-i preseed；安装完成后安装器禁用 cdrom 源） |
| 定制脚本 | `test/debian12/golden-image-setup-debian12.sh` |
| 内核 | 6.12.95+deb12-amd64（bookworm-backports） |
| 内核配置 | `CONFIG_NVME_TCP_TLS=y`、`CONFIG_NVME_AUTH=m` |
| 根文件系统 | ext4（`/dev/nvme0n1p2`，直连分区） |
| 安装盘 | 10 GiB raw，GPT + 4K FAT32 ESP |
| 软件源 | bookworm + bookworm-backports + security（阿里云，ForceIPv4） |

冷启动靶场与判据沿用上一轮记录：`br-fwtest`（192.168.81.1/24）+ `tap0fw`、nvmet 4K 文件后端、`tls1.3` 且 `treq=required`、数据端口 4422，iPXE 固件、串口日志与 `filter-dump` 抓包。判据为串口出现 `login:`；目标端 dmesg 出现两条 `nvmet: Created nvm controller ... , TLS.`；到 4422 的每个客户端 TCP 连接首载荷为 `0x16`；到 4420 的包数为 0；密钥不出现在明文载荷中。

## 2. 仓库现状与缺口

- bookworm 与 bookworm-backports 均不提供 `ktls-utils`，`apt-get install ktls-utils` 失败；initramfs 内因而没有 `tlshd`，内核的 TLS 握手 upcall 无监听者。
- bookworm 自带 `nvme-cli 2.4`（`2.4+really2.3-3`），`nvme connect --help` 不含 `--tls`，无法发起内核段 TLS 连接。
- bookworm-backports 的 6.12 内核已具备 TLS 相关配置：`CONFIG_NVME_TCP_TLS=y`、`CONFIG_NVME_AUTH=m`；缺口在用户态工具与 initramfs 接线，不在内核能力。
- 要求不引入 trixie 软件源，因此不能直接安装 trixie 的 `ktls-utils` 包。

## 3. 实现

### 3.1 源码构建用户态工具

脚本在源列表只含 bookworm（含 backports）的前提下，从 Debian 源码池取 orig tarball 在本机构建，并固定 SHA256：

| 组件 | 版本 | 源码 tarball | SHA256 |
|---|---|---|---|
| ktls-utils | 1.0.0 | `pool/main/k/ktls-utils/ktls-utils_1.0.0.orig.tar.xz` | `fff9af1639cb21437a3f5b73728aba8df6f165fe15b09eabd1f98be6d85e2783` |
| libnvme | 1.16.2 | `pool/main/libn/libnvme/libnvme_1.16.2.orig.tar.xz` | `cf5a71549f6f6bfd1965af21731a7f8d79b6cff30de536d1dc4998e53f9a264d` |
| nvme-cli | 2.16 | `pool/main/n/nvme-cli/nvme-cli_2.16.orig.tar.xz` | `6736153164634ddd16492aa68c5c5560e70f1c1c9edf009e20c182fcb3219af9` |

构建依赖全部取自 bookworm：

- libnvme / nvme-cli：`meson`、`ninja-build`、`pkg-config`、`gcc`、`libc6-dev`、`curl`、`xz-utils`、`libjson-c-dev`、`libkeyutils-dev`、`libssl-dev`；
- ktls-utils：`build-essential`、`autoconf`、`automake`、`libtool`、`pkg-config`、`curl`、`xz-utils`、`libgnutls28-dev`、`libkeyutils-dev`、`libglib2.0-dev`、`libnl-3-dev`、`libnl-genl-3-dev`。

构建方式：

- libnvme：`meson setup build -Ddocs=false -Dexamples=false -Dtests=false -Dpython=disabled --prefix=/usr`，`ninja -C build install`；
- nvme-cli：`meson setup build --prefix=/usr`，`ninja -C build install`；
- ktls-utils：`./autogen.sh`、`./configure --prefix=/usr --sysconfdir=/etc`、`make`、`make install`。该源码树不安装默认配置文件，脚本额外把 `src/tlshd/tlshd.conf` 安装为 `/etc/tlshd/config`，与 initramfs 钩子投递的路径一致。

安装后执行 `ldconfig`，并重新检查 `nvme connect --help`，仍缺 `--tls` 时构建失败。

### 3.2 新增的硬依赖检查

内核段 TLS 不再允许静默退化为明文。脚本在以下位置中止构建：

- `keyutils` 安装后 `command -v keyctl` 失败 → `ERROR: keyutils/keyctl not installed; TLS-PSK injection unavailable`；
- ktls-utils 处理完后 `/usr/sbin/tlshd` 不可执行 → `ERROR: tlshd not installed; kernel-stage TLS unavailable`；
- nvme-cli 源码构建后仍不支持 `connect --tls` → `ERROR: the built nvme-cli still lacks connect --tls`；
- 内核配置不含 `CONFIG_NVME_AUTH=m` → 构建失败；
- B 阶段校验 initrd 实际内容：必须包含 `tlshd`，以及 `tls`、`gcm`、`ccm`、`chacha20poly1305`、`ghash-generic`、`aesni-intel`、`ghash-clmulni-intel` 模块；模块若内建于内核（出现在 `modules.builtin`）则视为满足。

### 3.3 initramfs 运行时接线

- 钩子投递 `tlshd` 与 `/etc/tlshd/config`，并显式加入 `tls`、`nvme-keyring` 与上述 AEAD/加速模块；内核段握手结束后，kTLS 通过这些模块安装协商密钥。
- 钩子同时投递 `libnss_files.so.2`、`libnss_dns.so.2` 与最小 `nsswitch.conf`（`hosts: files dns`）。
- `local-top` 以 `tlshd -c /etc/tlshd/config` 启动守护进程，并在同一个 `keyctl session` 中执行 tlshd 与 `nbft-connect --connect`。initramfs 没有登录会话，裸 `keyctl` 调用会得到随进程销毁的临时会话，注入的 PSK 无法被 tlshd“占有”，内核随后交给 tlshd 的密钥序列号不可读。
- `nbft-connect` 从 `/proc/keys` 读出内核 `.nvme` 密钥环序列号，先把它链入会话，再以 `NVMe0R01 <hostnqn> <subsysnqn>` 身份把 PSK 写入 `.nvme`；连接前把目标地址固定进 `/etc/hosts`，供 tlshd 握手前的 `getnameinfo(NI_NAMEREQD)` 反查使用（initramfs 无 PTR 数据，反查失败会使 tlshd 放弃 upcall，内核以握手超时上报）。

## 4. 验收结果

| 项 | 结果 |
|---|---|
| 真实安装 | 通过（preseed，安装串口日志完整） |
| A–F 定制 | `A-F rc=0`；B 阶段输出 `nbft components (2 items), tlshd (3 items) and kTLS modules` |
| 冷启动 | 通过，串口出现 `localhost login:`；无 emergency、无 keep-alive 报错 |
| 控制器记录 | 目标端 dmesg：控制器 1（固件段）与控制器 2（内核段）均为 `..., TLS.` |
| 抓包 | 4 条客户端连接（源端口 41059/26572/35994/35998）首载荷均为 `0x16`；`:4420` 为 0；`plaintext_markers=none`（抓包 snaplen 截断，部分载荷未捕获） |
| 密钥 | 抓包中 PSK 原始字节 0 次命中；DH-HMAC-CHAP 字段命中 1 次，来自测试夹具经 TFTP 下发的 `boot.ipxe`（`secret=<redacted>`、`tls_psk=<redacted>`），非生产引导链行为；该命中是 UDP TFTP，不在 `pcap-flows.py` 的 TCP 明文判据内 |

F 阶段仅报告 nvme-cli 自带的 `/etc/nvme/discovery.conf`；调试期生成的 `/etc/nvme/hostnqn`、`/etc/nvme/hostid` 已删除并重跑定制，母盘不携带实例身份。

## 5. 证据

证据目录：`.local/reports/real-reinstall-2026-11-27/debian12/`（不随仓库提交，抓包不入库）。

| 内容 | 文件 |
|---|---|
| 安装串口日志 | `install.serial` |
| A–F 定制日志 | `customize.log` |
| 冷启动串口日志 | `coldboot.serial` |
| 冷启动抓包 | `coldboot.pcap` |
| 抓包判据输出 | `pcap-analysis.txt` |
| 目标端 dmesg | `target-dmesg.txt` |
| 安装与定制的驱动日志 | `install-run.log`、`customize-run.log`、`coldboot-pkexec.log` |

## 6. 相关提交

在 `refactor/governance-full` 分支（未 push，`main` 未动）：

| 提交 | 内容 |
|---|---|
| `5304af3` | `fix(debian12)`: 源码构建 libnvme 1.16.2、nvme-cli 2.16、ktls-utils 1.0.0；keyctl/tlshd 与 initrd 内容改为硬性校验 |
| `0dcc726` | `fix(initramfs)`: `.nvme` 密钥环链入会话；tlshd 与 connect 同会话运行；投递 NSS 模块并把目标地址固定进 `/etc/hosts` |

# 生产引导链验证记录（Kurrent 全栈：DHCP→TFTP→iPXE→控制面→NVMe/TCP 认证→GRUB→内核→rootfs）

> 状态：**验证通过**（2026-08-25）。本文档仅中文。
>
> 验证范围：Kurrent 生产栈（dnsmasq + TFTP + iPXE 固件 + 控制面 + storager/nvmeof + nvmet）下，QEMU 客户端从 PXE 冷启动到 Debian 12 `login:` 提示符的**全链路闭环**，含两段 DH-HMAC-CHAP 认证（固件段 iPXE 认证 + 内核段 6.12 认证）。
>
> 证据文件：`diag/prod-boot12.serial`（串口全量日志，75 KB）、`diag/prod-boot12.pcap`（tap0 filter-dump，586 MB）、`diag/prod-boot12-conn.txt`（pcap 连接汇总）。
>
> 关联文档：[debian12-nbft-auth-verification.md](debian12-nbft-auth-verification.md)（认证 PDU 级分析）、[nbft-boot-verification.md](nbft-boot-verification.md)（无认证六环链路）、[nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md)（认证调试记录）。

## 1. 目标与链路

在**完整生产栈**下验证无状态引导：客户端无任何本地介质，从 PXE 开始由控制面动态下发引导参数与凭据，最终登录 Debian 12。

```
OVMF PXE (DHCP 192.168.50.1) → TFTP snponly.efi → iPXE
  → https 控制面: report / challenge / boot-vars（凭据下发）
  → 菜单 1s 自动 Boot Debian（NVMe-oF）
  → sanboot nvme://192.168.50.1:4420（固件段认证①）
  → GRUB 2.14 → 6.12 内核（ip=dhcp nbft_auto）
  → initramfs: DHCP → NBCT 表探针 → nvme connect（内核段认证②）
  → rootfs 挂载 → systemd 完整启动 → login:
```

与 [debian12-nbft-auth-verification.md](debian12-nbft-auth-verification.md) 的差异：本次 NBFT 表**由 iPXE 固件消费控制面 boot-vars 生成**（生产路径），而非内核工具生成后 ACPI 注入；认证凭据经控制面 challenge 签名下发。

## 2. 环境与工具

| 项 | 值 |
|---|---|
| 客户端 | QEMU q35 + KVM，OVMF 4M（`OVMF_CODE_4M.fd` + `OVMF_VARS.fd`），2G 内存，`timeout 600s`，`-serial file:prod-boot12.serial`，e1000 MAC `52:54:00:50:00:01` 接 tap0/br0 |
| 网络 | 宿主 br0 192.168.50.1；dnsmasq（DHCP/TFTP）；`-object filter-dump` 输出 `prod-boot12.pcap` |
| 引导栈 | 固件 `snponly.efi`（iPXE 定制，含 nvmetcp 认证/NBCT）→ 控制面 https → `boot.ipxe` → `menu.ipxe` |
| 存储 | storager/nvmeof compose 内 nvmet：192.168.50.1:4420，`nqn.2026-07.com.kurrent:worker-01.debian`，DH-HMAC-CHAP，文件后端 worker-01.debian.img（4K 逻辑块） |
| 盘 | worker-01.debian.img（20 GiB）：4K 原生 GPT（convert-gpt-4k.sh 转换），p1 = 4K FAT32 ESP（esp4k-prod.img 内容），p2 = ext4 root（UUID d0a8ebeb-202b-4481-9f52-9eae81af44be），p3 = swap |
| 内核 | 6.12.95+deb12-amd64（bookworm-backports，CONFIG_NVME_AUTH=m） |

## 3. 修复历程（三个阻塞点，均在本次验证中解决）

### 3.1 sanboot 失败 `0x7f22208e`（EFI_NOT_FOUND）→ 4K 原生 GPT

- 现象：第 8 轮 `Boot from SAN device 0x80 failed: Error 0x7f22208e`（errfile `efi_block` + platform `0x8e` = EFI_NOT_FOUND，`LoadImage` 失败）；
- 根因：worker 盘为 **512 扇区 GPT**，nvmet file backend 以 **4096 B 块**导出（`i_blkbits`）→ EDK2 PartitionDxe 在 LBA1×4096 = 偏移 4096 找 GPT 头 → 找不到 → ESP 不枚举 → LoadImage 失败；
- 修复：`diag/convert-gpt-4k.sh` 将 GPT 重写为 **4K 原生布局**（头 @4096、表 @8192、备份 @盘尾），分区字节范围零改动；转换前自动备份旧 GPT 到 `.gpt-512.bak`（回滚命令由脚本输出）；
- 验证：转换后 verify（签名/CRC）+ spot-check（FAT32 BPB、ext4 magic、SWAPSPACE2）全部通过；第 9 轮 GRUB 2.06 启动成功。

### 3.2 内核认证失败 `ret=401` → 6.12 内核

- 现象：第 9 轮 GRUB 正常但内核侧 `qid 0: authentication setup failed`、`ret=401`（0x191）；
- 根因：盘内 6.1 内核 **`CONFIG_NVME_AUTH is not set`**（`nvme_auth_negotiate` 为 stub 返回 -EOPNOTSUPP），而 nvmet `AUTH=1` 的 Connect 响应 ATR 置位（`result=0x00020001`）→ 内核无法协商 → NVME_SC_AUTH_REQUIRED；
- 修复：更换 bookworm-backports **6.12.95+deb12-amd64**（CONFIG_NVME_AUTH=m）；
- 配套修复（hostid）：内核 nvme-fabrics host tracking 拒绝 DMI 默认 hostid 下的自定义 hostnqn（"found same hostid but different hostnqn"）→ nbft-connect 注入 `--hostid 11111111-2222-3333-4444-555555555555`（`diag/initrd-612-hostid.img` 为拼接微码段 + 修复版段 2 的完整 initrd）。

### 3.3 systemd 网络接管断链 → cmdline mask

- 现象：第 10 轮认证/挂载/systemd 全通，但 systemd-networkd 启动（25.3s）后 keep-alive 超时（33.8s），`no usable path - requeuing I/O`，重连 `-101` 循环——承载 SAN 的 TCP 连接被网络重新配置断开；
- 修复：GRUB cmdline 增加 `net.ifnames=0 biosdevname=0 systemd.mask=NetworkManager.service systemd.mask=systemd-networkd.service`，保留 initramfs 建立的连接（`systemd-networkd-wait-online` Dependency failed 为 mask 的无害预期）；
- 验证：第 12 轮全程无 keep-alive 错误，systemd 完整启动。

## 4. 验证证据（第 12 轮，prod-boot12.serial/pcap）

### 4.1 串口关键行（完整日志见 prod-boot12.serial）

```
Station IP address is 192.168.50.78
NBP filename is snponly.efi
NBP file downloaded successfully.
"identity: already provisioned"
https://192.168.50.1:443/devices/report... ok
https://192.168.50.1:443/devices/challenge... ok
https://192.168.50.1:443/boot-vars... ok
https://192.168.50.1:443/tftp/menu.ipxe... ok
Booting from SAN device 0x80
GNU GRUB  version 2.14
[    0.000000] Linux version 6.12.95+deb12-amd64 ...
[    0.000000] Command line: BOOT_IMAGE=/vmlinuz-6.12.95+deb12-amd64 root=UUID=d0a8ebeb-202b-4481-9f52-9eae81af44be ro console=ttyS0,115200 net.ifnames=0 biosdevname=0 ip=dhcp nbft_auto systemd.mask=NetworkManager.service systemd.mask=systemd-networkd.service
[    6.299088] nvme nvme0: qid 0: authenticated with hash hmac(sha256) dhgroup ffdhe4096
[    6.300909] nvme nvme0: qid 0: authenticated
nbft: dbg connect rc=0
[    6.318851]  nvme0n1: p1 p2 p3
[    6.670060] EXT4-fs (nvme0n1p2): mounted filesystem d0a8ebeb-202b-4481-9f52-9eae81af44be ro with ordered data mode. Quota mode: none.
Welcome to Debian GNU/Linux 12 (bookworm)!
debian login:
```

### 4.2 pcap 判据（prod-boot12-conn.txt，`diag/prod-conn-summary.py` 解析）

四个 TCP 连接（全部到 192.168.50.1:4420），**全部 RSP status=0，无一次失败**：

| 连接（发起端口） | 角色 | 时长 | 认证 PDU | 命令构成 | RSP |
|---|---|---|---|---|---|
| 38352 | 固件段 admin qid0 | 0.1s | AuthSend×2 + AuthReceive×2 | Connect→**ATR**(result=0x20004)→认证→PropSet | 8/8 status=0 |
| 54066 | iPXE IO qid1 | 18.0s | 无（IO 队列不认证） | Connect result=0x4 + Read×30842 | 30843/30843 status=0 |
| 60408 | 内核段 admin qid0 | 89.6s | AuthSend×2 + AuthReceive×2 | Connect→**ATR**(result=0x20005)→认证→PropSet/Get + KeepAlive×32 | 55/55 status=0 |
| 60424 | 内核 IO qid1 | 83.4s | 无 | Connect result=0x5 + Read×8346/Identify×859/Flush×47/Write×129 | 9253/9253 status=0 |

- 两段认证均为标准一轮 DH-HMAC-CHAP：`AuthSend(Negotiate) → AuthReceive → AuthSend(Challenge) → AuthReceive`，Connect 数据区 NQN 均为 `subsys=nqn.2026-07.com.kurrent:worker-01.debian`、`host=nqn.2026-07.com.kurrent:host.worker-01`；
- 数据面吞吐：GRUB 经 iPXE 读 **120.5 MiB**（C2H 126,328,832 B，内核 + initrd 加载）；systemd 启动后内核 IO 读 **380.8 MiB** + 写 **14.0 MiB**（Identify×859 = systemd-udevd 冷插拔枚举）；
- 解析器事件标签的已知伪影：IO 连接的 RSP 事件被标记为 `RSP[Connect]`（lastcmd 未随普通命令更新），但 **RSP 状态统计独立正确**（`RSP st: 0x0=N` 字段），不影响结论。

## 5. 复现步骤

```bash
# 1. 生产栈（宿主）
cd kurrent && docker compose up -d              # 根 compose（控制面 + dnsmasq/tftp 等）
cd kurrent/storager && docker compose up -d     # storager/nvmeof（nvmet 容器, 4420）

# 2. 盘就位（用户 sudo）
#    worker-01.debian.img: 4K GPT + p1(esp4k-prod.img 内容) + fstab 注释 /boot/efi
#    nvmet 容器 device_path=/srv/nvmet-disks/worker-01.debian.img（bind mount, enable=1）

# 3. 客户端（沙箱外）
bash diag/run-qemu-prod12.sh    # tap0/br0, serial file:prod-boot12.serial, pcap

# 4. 证据检查
grep -E 'authenticated|login:' diag/prod-boot12.serial
python3 diag/prod-conn-summary.py diag/prod-boot12.pcap   # 四连接全 status=0 + 双 ATR
```

## 6. 边界与遗留

- **ESP 挂载**：盘内 fstab 的 `/boot/efi`（UUID=855B-91DF）已注释（SAN 无状态场景无意义；注释前 4K FAT ESP 的 systemd 挂载失败落入 emergency，引导链本身不受影响）；
- **hostname**：systemd 显示 `debian`（母盘定制值），生产 hostname 由 Kurrent 控制面下发，不在本验证范围；
- **僵尸连接**：历史轮次残留 4 条 ESTAB（192.168.50.78:14058/15589/32459/33216）由 `ss -K` 清理失败遗留，不影响 nvmet 接受新连接；
- **登录交互**：验证止于 `login:` 提示符（serial file 后端无法交互），登录后行为不在本验证范围。

## 7. 参考资料

- `diag/prod-boot12.serial`、`diag/prod-boot12.pcap`、`diag/prod-boot12-conn.txt`
- `diag/prod-conn-summary.py`（iPXE PDU 解析，布局对照 `.cache/ipxe-upstream/src/include/ipxe/nvmetcp.h`）
- `diag/convert-gpt-4k.sh`、`diag/esp4k-prod.img`、`diag/initrd-612-hostid.img`、`diag/grub-prod.cfg`
- [debian12-nbft-auth-verification.md](debian12-nbft-auth-verification.md)、[nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md)

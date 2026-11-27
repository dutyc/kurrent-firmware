# NVMe/TCP SAN 引导验证记录（QEMU + nvmet + GRUB 2.14）

> 状态：**验证通过**（2026-08-18）
>
> 验证目标：iPXE `nvmetcp` 驱动在 UEFI 环境下的完整 SAN 引导链路。
> 关联文档：[nvmeof-research.md](nvmeof-research.md)（协议研究与设计；其中"无实机验证"表述已由本文档闭环更新）。

## 1. 验证目标与链路

验证从 NVMe/TCP target 到 GRUB 菜单执行的完整引导链路：

```
nvmet (host 127.0.0.1:4420)
  → slirp 10.0.2.2:4420 → iPXE nvmetcp 驱动（双 TCP 连接：Admin qid0 + I/O qid1）
  → efi_block_hook 安装 BlockIo + DevicePath 协议（URI 设备路径）
  → OVMF PartitionDxe 识别 4K GPT，创建分区 handle
  → OVMF FatDxe 绑定 ESP，安装 SimpleFileSystem
  → efi_block_boot 匹配 SAN 分区 → LoadImage \EFI\BOOT\BOOTX64.EFI（GRUB 2.14）
  → GRUB 菜单入口执行（echo/ls/sleep 验证）
```

## 2. 环境与工具

| 项 | 值 |
|---|---|
| 虚拟化 | QEMU q35 + KVM，OVMF 4M（`OVMF_CODE_4M.fd`），串口日志 |
| 网络 | slirp user 模式，guest 10.0.2.15，host 回环经 10.0.2.2 可达 |
| target | Linux nvmet（`diag/nvmet-setup.sh`，文件后端，幂等） |
| 盘镜像 | 512M GPT（4K 扇区）+ ESP 300MiB FAT32（4K 簇） |
| GRUB | 2.14（`grub-mkimage` 生成，efidisk 内建于 core） |
| iPXE 固件 | `DEBUG=nvmetcp,tcp,efi_block:3`，EMBED `diag/nvmeof-test.ipxe`（sanboot 入口） |

## 3. 三轮迭代根因链

### 3.1 第 1 轮：`0x7f31218e`（EFI_NOT_FOUND）← 512B/4K GPT 错位

- 现象：`sanboot` 返回 `0x7f31218e`，无驱动绑定。
- 解码：`platform = 0x80 | 0x0e = 0x8e`（EFI_NOT_FOUND）。
- 根因：nvmet 文件后端暴露 4096 字节逻辑块，EFI PartitionDxe 按 `BlockSize` 粒度读
  LBA1；初版盘用 512B 扇区工具格式化，GPT 头实际在文件偏移 4096 而非 512，设备路径
  校验失败。
- 修复：python 手工写入 4K 扇区 GPT（protective MBR + 头/表 + 备份 GPT 全 4K 对齐）。

### 3.2 第 2 轮：`0x3d222083`（ENOTTY）← FatDxe 拒绝绑定 ← FAT32 簇数不足

- 现象：connect 成功、有读盘（GPT 已识别），但 `sanboot` 报 `0x3d222083`。
- 解码：`posix 0x3d`（61 = ENOTTY）+ `ERRFILE_efi_block`（0x00222000）+ `platform
  0x83`（EFI_UNSUPPORTED），对应 `efi_block_match` 第 676 行 memcmp 前缀检查失败
  （DBGC2 "is not parent of"，2 级调试下静默）。
- 根因：64MiB ESP 在 4K 簇下仅 16320 簇，低于 FAT32 类型判定下限 65525 簇；EDK2
  FatDxe 按簇数判 FAT16，与 BPB 的 FAT32 结构矛盾，拒绝绑定 → 无 SimpleFileSystem
  可匹配。
- 佐证：`fsck.vfat` 警告 `16320 clusters < 65525 minimum`。
- 修复：ESP 扩至 300MiB（76800 簇），FatDxe 绑定成功（BPB/FAT/FSInfo 读盘可见）。

### 3.3 第 3 轮：GRUB 成功引导 ← echo 模块补齐

- 现象：GRUB 2.14 菜单出现、识别 `(hd1,gpt1)`，但入口首条命令失败
  `error: can't find command 'echo'`。
- 根因：GRUB 2.14 中 `echo` 是独立模块，`grub-mkimage` 模块列表未含。
- 修复：模块列表补 `echo`（注意 `grub-mkimage` 必须带 `-p` 前缀参数）。
- 结果：入口 `echo`/`ls`/`sleep` 全部执行成功，验证闭环。

## 4. 最终验证证据（DEBUG=efi_block:3 全量日志）

### 4.1 DBGLVL 位掩码语义（调试排障关键）

`include/compiler.h` 中 `DBGLVL_LOG=1`、`DBGLVL_EXTRA=2`，DBGC 由 `DBGLVL & 1`
门控、DBGC2 由 `DBGLVL & 2` 门控：

- `DEBUG=obj:2` 只开 DBGC2（EXTRA），**DBGC 关键流程静默**——曾导致误判
  "match 失败"；
- `DEBUG=obj:3` 同时开启 LOG + EXTRA，拿到完整证据链。

固件字符串可验证：`:2` 固件无 "attempting to boot"/"contains filesystem"，
`:3` 固件两者齐备。

### 4.2 完整证据链（qemu12.log，行号随版本浮动）

```
L187  EFIBLK 0x80 installed as SAN drive Uri(nvme://10.0.2.2:4420/...)
L375  HANDLE Uri(...) DiskIo opened by Partition Driver        ← OVMF DiskIoDxe
L395  HANDLE Uri(...) BlockIo opened by Generic Disk I/O Driver
L377  .../HD(1,GPT,E1C9A000-...,0x800,0x12C00)                 ← 分区 handle 创建
L189+ GPT 读（LBA 0/1/2/0x1ffff）+ BPB 读（LBA 0x800×3）      ← FatDxe 绑定
L537  EFIBLK 0x80 is SAN drive ...
L539  EFIBLK 0x80 attempting to boot
L703  EFIBLK 0x80 is not parent of ...Sata...HD(1,MBR,...)     ← 本地盘预期排除
L705  EFIBLK 0x80 contains filesystem .../HD(1,GPT,...)        ← SAN 分区命中
L911  EFIBLK 0x80 trying to load ...\EFI\BOOT\BOOTX64.EFI
      → LoadImage + StartImage（GRUB），至 QEMU 关闭未返回
```

### 4.3 GRUB 侧输出

```
== GRUB BOOTED FROM NVME/TCP SAN DISK ==     ← echo 模块生效
(hd1,gpt1) (cd0)                             ← GRUB 经 iPXE BlockIo 识别 SAN 盘分区
```

随后 `sleep --interruptible 60` 执行完毕，入口无真实内核可 `boot`，GRUB 按预期回退
菜单（`Failed to boot both default and fallback entries.` 属**预期收尾**，非错误），
菜单高亮入口 `*NVMe/TCP SAN boot OK`，直至 QEMU 150s 超时关闭。

## 5. 修复清单

| 修复项 | 现象 | 根因 | 修复 |
|---|---|---|---|
| 4K GPT 对齐 | `0x7f31218e` 无绑定 | 512B/4K 扇区错位 | python 4K 扇区 GPT（`make-grub-bootdisk.sh`） |
| ESP 容量 | `0x3d222083` ENOTTY | FAT32 簇数 < 65525 | ESP 64MiB → 300MiB（76800 簇） |
| echo 模块 | `can't find command 'echo'` | GRUB 2.14 echo 独立模块 | `grub-mkimage` 模块列表补 `echo` |
| 调试级别 | 关键流程无日志 | DBGLVL 位掩码语义 | `DEBUG=efi_block:2` → `:3` |

## 6. 复现步骤

```bash
# 1. 启动 nvmet target（幂等；重做盘后无需重跑——truncate 同 inode，fd 仍有效）
sudo bash diag/nvmet-setup.sh

# 2. 制作引导盘（512M GPT + ESP 300MiB + GRUB 2.14）
bash diag/make-grub-bootdisk.sh

# 3. 重建调试固件并部署（`:3` = LOG+EXTRA 全开）
make -C .cache/ipxe-upstream/src bin-x86_64-efi/ipxe.efi \
  EMBED=diag/nvmeof-test.ipxe DEBUG=nvmetcp,tcp,efi_block:3
cp .cache/ipxe-upstream/src/bin-x86_64-efi/ipxe.efi diag/tmp/EFI/BOOT/BOOTX64.EFI

# 4. 运行 QEMU（需 /dev/kvm，150s 超时，产物 qemu12.log + netdump15.pcap）
bash diag/run-qemu7.sh

# 5. 日志分析（OVMF/GRUB 输出用 \r，须先转换）
tr '\r' '\n' < diag/qemu12.log | grep -E "attempting to boot|contains filesystem|trying to load"
```

## 7. 边界与遗留

- **验证到菜单执行层**：GRUB 入口无真实内核（echo/ls/sleep 验证），未覆盖 Linux
  内核经 NVMe/TCP 盘启动的后续阶段。
- **虚拟环境**：链路经 slirp + QEMU e1000；真实网卡与真实 NVMe SSD 主机侧的
  nvmetcp 行为未验证，协议细节正确性仍依赖规范对照与代码审查。
- **上游跟踪**：持续关注 [ipxe/ipxe#556](https://github.com/ipxe/ipxe/issues/556)，
  若上游合入 NVMe 实现，评估替换方案。
- **串口日志**：QEMU 串口输出混用 `\r`/`\n`，grep 前须 `tr '\r' '\n'`。

## 8. 参考资料

- `src/interface/efi/efi_block.c`：`efi_block_hook`（协议安装）/ `efi_block_boot`
  （引导循环）/ `efi_block_scan`（SFS 匹配）/ `efi_block_exec`（LoadImage）
- `src/include/compiler.h`：DBGLVL 位掩码（LOG=1 / EXTRA=2）
- `src/include/errno.h`、`src/include/ipxe/errfile.h`：错误码编码
- `diag/make-grub-bootdisk.sh`、`diag/nvmet-setup.sh`、`diag/run-qemu7.sh`

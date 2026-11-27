# RTL8168/8111 native 驱动挂起研究日记（已终止）

> 状态：**已终止**（2026-08-09 决定）。结论：无法在该测试环境稳定复现修复效果，停止 8168 驱动研究，全力投入 RTL8125 等高性能网卡驱动工作。
>
> 本文件记录完整踩坑过程，供日后遇到类似问题（PCIe 设备 UEFI 下 MMIO 挂起）时参考。

## 背景与现象

- 固件：`direct-uefi/ipxe.efi`（全驱动 + 8125 定制补丁）
- 环境：AMI 固件主板，板载 Realtek 网卡位于 `PciRoot(0x0)/Pci(0x14,0x0)`（Realtek UEFI UNDI Driver / SNP Driver 均绑定）
- 现象：启动后卡死在设备连接阶段

```
iPXE initialising devices.

file:autoexec.ipxe...Not found (https://ipxe.org/err/7f4de18e)
file:/autoexec.ipxe...Not found (https://ipxe.org/err/7f4de18e)
```

（`Not found` 是 EMBED 加载的**正常**信息；banner 未出现 = 卡在 `efi_driver_connect_all` 设备连接阶段）

## 日志定位方法（关键经验）

`DEBUG=realtek:3,efi_driver:3` 构建诊断固件，卡点判定：

```
EFIDRV ... connecting new drivers
EFIDRV ... has driver PCI
EFIDRV ... DRIVER_START          ← 卡在此行之后
```

- `DRIVER_START` 是 `efi_driver_start()` 调用 PCI 驱动 start 前打印
- 卡住且无任何 `REALTEK` 行 → 挂点在 `realtek_probe` 第一条 DBGC 之前

## 踩坑时间线

### 第 1 轮：过滤块（SNP 兜底）——规避而非修复

- 做法：`realtek_probe` 对 `pci->device == 0x8168` 返回 `-ENODEV`，交固件 SNP 驱动
- 结果：用户环境仍卡（iPXE connect_all 会先 disconnect 固件驱动，SNP 兜底实际不可用/不可靠）
- 教训：**probe 里返回 -ENODEV 不是兜底，是自断后路**——固件驱动已被 disconnect，设备落空

### 第 2 轮：Linux r8169 对照分析

- Linux 在 `rtl_hw_start` 入口先 `rtl_hw_aspm_clkreq_enable(tp, false)`（"disable aspm and clock request before ephy access"），iPXE 无 ASPM 处理
- 结论（当时）：ASPM L1 低功耗链路下 MMIO 挂起是最大嫌疑
- 8168 全系（B~H）PCI ID 均为 0x8168，Linux 按 mac_version 分支处理；8168E+ 才有 ASPM 逻辑

### 第 3 轮：probe 全路径等待点审查

- `realtek_reset`（100ms 超时）、`realtek_detect`（RMS/CPCR MMIO）、`realtek_phy_reset`（PHYAR 500µs 超时）、`realtek_check_link`
- 结论：所有软件循环有超时，**唯一无保护的是 MMIO 直接访问**（readl/writel，PCIe 事务无限重试）

### 第 4 轮：诊断固件实锤卡点

- 构建去过滤 + 日志诊断固件 → 真机日志：`DRIVER_START` 后无 REALTEK 行
- **实锤：卡在 realtek_probe 第一条 DBGC 之前 = 第一个 MMIO 访问（realtek_reset 的 CR 写/读）死等**

### 第 5 轮：ASPM/D0 修复（config 空间唤醒）

- 实现 `realtek_prepare_pcie()`：MMIO 前经 PCI 配置空间清 LnkCtl ASPM 位（L0s/L1）+ D0 唤醒（PMCSR）
- 原理：config 事务与 MMIO 走同一条 PCIe 链路，但 config 访问在诊断中始终成功（`adjust_pci_device` 完成）
- **反汇编验证修复确实编入固件**（`realtek_probe` 内联 2 处 `call pci_find_capability`，参数 0x10/0x01）
- 结果：
  - 带 `realtek:3,efi_driver:3` 日志的诊断版：一次"通过"（**后证实不可靠**）
  - 正式版（无日志）：仍卡
  - 同配置等价重建（fix2）：仍卡 → **修复从未真正越过第一个 MMIO**

### 第 6 轮：延迟假设与状态诊断（终止轮）

- 假设：日志输出 = 隐式延迟，链路恢复需要时间 → 加 `mdelay(100)` 显式延迟
- 结果：正式版 + debug 版（仅 realtek:3）均仍卡
- 终极诊断：`prepare_pcie` 内加状态打印（LnkCtl 读写回、LnkSta/LTSSM、PMCSR 读写回，全部 config 读，MMIO 前）
- **结果：连这些打印都没有** → 卡点比 prepare_pcie 更早（`adjust_pci_device` 的 config 操作阶段就挂）
- **结论：该环境下 config 访问都可能死等，软件层已无对策**（需硬件复位/链路重新训练，iPXE 无此接口）→ 研究终止

## 最终结论

1. **该测试环境下 8168 挂起不是 ASPM/D0 层面问题**，卡点在 probe 早期 config 操作阶段，软件等待/唤醒均无效
2. **"日志版通过、正式版挂"是假象**：同配置等价重建固件同样挂 → 之前"通过"不可复现（环境/误判）
3. **UEFI 下 iPXE 对 PCIe 设备缺少复位/重新训练能力**（固件 SNP 驱动有完整序列所以固件路径可用）
4. 8125 native 驱动工作正常（现场验证），不受影响；8168 问题搁置

## 经验教训

- **日志诊断固件必须与正式版同配置验证**：DEBUG 日志输出会改变时序，可能掩盖真实卡点（"带日志过、无日志挂"是红旗信号，应立即用同配置重建复核）
- **probe 返回 -ENODEV 不是兜底**：iPXE connect_all 会 disconnect 固件驱动，无驱动认领的设备会落空
- **config 空间可访问 ≠ 设备可用**：D3hot/链路异常下 config 通而 MMIO 挂，两者是不同通路
- **验证修复是否编入固件**：static 函数会被内联，`nm` 看不到符号；用 `objdump -dr realtek.o | grep 调用目标` 验证
- **复现不稳定时先怀疑"上次通过"**：同配置重建对比是排除环境差异的基准动作

## 遗留

- `patches/0001` 已清理为纯 8125 适配（无 8168 过滤、无 prepare_pcie），8168 回归上游原生行为（8169 路径）。（2026-09 起 0001 同时含 RTL8126 适配，仍未含 8168 代码）
- 若未来重启 8168 工作，建议方向：probe 前经 EFI PCI_IO Protocol 的 `Reset()` 做设备复位，或研究 `efi_driver` 层先让固件驱动完成设备初始化再接管

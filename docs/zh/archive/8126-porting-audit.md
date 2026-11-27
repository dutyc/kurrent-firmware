# RTL8126 移植来源对照审计

**审计对象**：`patches/0001-realtek-adaptation.patch`（RTL8126A 适配部分；2026-09-12 由原 `0004-realtek-8126-adaptation.patch` 并入 `0001`）
**参考源码**：`thirdparty/kernel/rtl8126-official/`（Realtek 官方 r8126 驱动，OpenWrt 镜像）与 `thirdparty/kernel/linux-7.1.7/`（Linux r8169）
**审计日期**：2026-08-12
**审计方法**：函数级逐项对照 + 多重集（multiset）差异分析，忽略顺序干扰，精确到缺失/新增项

---

## 一、为什么是双来源

RTL8126 的移植**同时参考了 Linux 内核 r8169 与 rtl8126-official**，分工由固件依赖决定：

| 层次 | 参考来源 | 原因 |
|---|---|---|
| MAC 初始化（`realtek_hw_start_8126`） | Linux r8169 | 无固件依赖，实现简洁、已工程化 |
| PHY 初始化（三张静态表） | rtl8126-official | Linux 严重依赖固件，iPXE 无固件加载机制；官方驱动为纯 C 实现 |

**Linux 依赖固件的铁证**——`rtl8126a_hw_phy_config`（r8169_phy_config.c L1148）仅 5 行：

```c
r8169_apply_firmware(tp);          /* 8126 的约 240 项寄存器配置几乎全部打包在固件里 */
rtl8168g_enable_gphy_10m(phydev);
rtl8125_legacy_force_mode(phydev);
rtl8168g_disable_aldps(phydev);
rtl8125_common_config_eee_phy(phydev);
```

无 `rtl_nic/rtl8126a-2.fw / rtl8126a-3.fw` 时，Linux 侧 8126 PHY 几乎裸奔。

**官方纯 C 的铁证**——官方驱动把固件内容完整展开为 C 序列（`rtl8126_hw_phy_config_8126a_1/2/3`，合计 362 个 OCP 操作），且有明确的无固件路径：

```c
#ifndef ENABLE_USE_FIRMWARE_FILE
        if (!tp->rtl_fw)
                rtl8126_init_hw_phy_mcu(dev);
#endif
```

iPXE 无固件加载机制 → PHY 层必须以官方驱动为主参考。

## 二、来源分工明细

### 2.1 MAC 层 ← Linux r8169（逐行对应）

| 0004 移植（`realtek_hw_start_8126`） | Linux 7.1.7（`rtl_hw_start_8126a`，r8169_main.c L3975） |
|---|---|
| `realtek_csi_modify(0x0890, 0x00000001, 0)` | `rtl_disable_zrxdc_timeout()` |
| `realtek_csi_modify(0x070c, 0xff000000, 0x27000000)` | `rtl_set_def_aspm_entry_latency()` |
| `realtek_hw_start_8125()` | `rtl_hw_start_8125_common()` |

### 2.2 PHY 层 ← rtl8126-official（语义逐项对应）

0004 表项四元组 `{reg, clear, set, write}` 与官方调用的映射：

| 0004 表项 | 官方调用 |
|---|---|
| `write=1` | `rtl8126_mdio_direct_write_phy_ocp(tp, reg, set)` |
| `write=0` | `rtl8126_clear_and_set_eth_phy_ocp_bit(tp, reg, clear, set)` |
| `write=0, clear=0` | `rtl8126_set_eth_phy_ocp_bit(tp, reg, set)` |
| `write=0, set=0` | `rtl8126_clear_eth_phy_ocp_bit(tp, reg, clear)` |

### 2.3 公共尾部（三方一致）

0004 的 `realtek_gphy_ocp_modify(0xa5b4, 0x8000, 0)`（注释 "Force legacy power management mode"）=
官方分发函数 `rtl8126_hw_phy_config` 公共尾部 `rtl8126_clear_eth_phy_ocp_bit(tp, 0xA5B4, BIT_15)` =
Linux `rtl8125_legacy_force_mode()`。三处同源，0004 移植正确。

### 2.4 检测逻辑

0004 `realtek_detect_8126` 与官方 `rtl8126_get_mac_version`（r8126_n.c L6875）一致：

```c
/* 族检测 */
(txconfig & 0x7c800000) == 0x64800000
/* ICVerID (bit20-22) → mcfg */
icverid 0 → mcfg 1；icverid 1 → mcfg 2；icverid 2 → mcfg 3
```

`mac_ver = 70` 与 Linux `RTL_GIGA_MAC_VER_70` 编号一致。

## 三、OCP 访问机制对照

| 项目 | rtl8126-official | 0004 移植 | 结论 |
|---|---|---|---|
| 命令寄存器 | `PHYOCP = 0xB8` | `RTL_GPHY_OCP = 0xb8` | 一致 |
| 写标志/完成标志 | `OCPR_Write = OCPR_Flag = 0x80000000` | `RTL_OCPAR_FLAG = 0x80000000` | 一致 |
| 地址编码 | `(RegAddr/2) << 16` | `reg << 15` | 数学等价（RegAddr 为偶数，`RegAddr/2 << 16 ≡ reg << 15`） |
| 对齐检查 | `WARN_ON_ONCE(RegAddr % 2)` | `if (reg & 0xffff0001) return` | 一致（16 位 + 2 字节对齐） |
| 等待超时 | 20000 × 1us = 20ms | `RTL_GPHY_OCP_MAX_WAIT_US` = 20000 × 1us（2026-08-12 修复，原为复用 `RTL_MII_MAX_WAIT_US` 500us） | 已修复 ✓ |

## 四、PHY 表精确对照结果（多重集，2026-08-12 修订）

> 修订说明：初版审计解析器为单行正则，无法匹配官方的**多行参数**调用（`clear_and_set_eth_phy_ocp_bit(tp,` 换行后参数缩进），导致约 50 项漏解析，产生“缺 4 项、保留 BF90”的错误结论。修正为跨行匹配后重新审计，真实缺口为 **MCU patch 段全部 6 项**（已修复）。

| 表 | 官方操作数 | 0004 项数 | 官方独有（真实缺失） | 补丁独有（多写） | 状态 |
|---|---|---|---|---|---|
| `realtek_8126a_1_phy` | 1 | 1 | 0 | 0 | ✓ |
| `realtek_8126a_2_phy` | 235 | 242 | **0 项**（修复后） | 7 项 | ✓ |
| `realtek_8126a_3_phy` | 129 | 130 | **0 项** ✓ | 1 项 | ✓ |

### 4.1 已修复：8126a_2 MCU patch 段 6 项（2026-08-12）

初版审计（解析器 bug）误报“缺 4 项、保留 BF90×2”。跨行解析修正后确认：官方 `rtl8126_hw_phy_config_8126a_2`（r8126_n.c L10923-10934）中 **MCU patch 段 6 项全部缺失**（BD96/BF1C/BFBE/BF40/BF90×2，0004 表中该段一项都没有）：

```c
rtl8126_set_phy_mcu_patch_request(tp);   /* 置 0xB820.bit4 → 轮询 0xB800.bit6，≤100ms 握手（0004 省略握手，见 §五） */
clear_and_set 0xBD96, 0x1F00, 0x1000
clear_and_set 0xBF1C, 0x0007, 0x0007
clear 0xBFBE, BIT_15
clear_and_set 0xBF40, 0x0380, 0x0280
clear_and_set 0xBF90, BIT_7, BIT_6|BIT_5
clear_and_set 0xBF90, BIT_4, BIT_3|BIT_2
rtl8126_clear_phy_mcu_patch_request(tp);
```

**修复**：已在 `realtek_8126a_2_phy` 对应位置（0xb87c 0x83fa 序列之后、0xa436 0x843b 之前，即官方 patch 段位置）插入全部 6 项（`write=0` 语义），插入后对照审计**官方独有 0 项**。补丁版本以本次修订为准。

### 4.3 PHY MCU 微码缺口与轻量方案（2026-08-12 决策）

官方驱动**无论有无固件文件都会确保 PHY 微码（RAM code）为期望版本**（mcfg1=0x0023、mcfg2=0x0033、mcfg3=0x0060）：有固件时从 `.fw` 加载，无固件时用 C 数组直写（`rtl8126_init_hw_phy_mcu` → `set_phy_mcu_ram_code`，对偶数组 `{addr, val}` 循环 OCP 写）。微码数据规模：6 个数组合计 **9761 对 u16 ≈ 39KB**（8126a_1: 1877+139+120 对、8126a_2: 6990+185 对、8126a_3: 2450 对）。

写入前官方检查 `hw_ram_code_ver == sw_ram_code_ver`（OCP 写 0xA436=0x801E → 读 0xA438）——相等则跳过，**出厂芯片微码很可能已是最新版本**。`HwIcVerUnknown` 时官方不写微码也不写 patch。

**轻量方案（已实施）**：0004 移植版本检查逻辑（`realtek_hw_phy_config_8126` 开头，与官方 `rtl8126_get_hw_phy_mcu_code_ver` 同寄存器序列），出厂微码与期望版本不符时打印警告日志；39KB 微码数组**暂不移植**（若实机验证确认版本不匹配，再评估完整移植）。

**实机验证判定标准**：无警告日志 = 出厂微码匹配，方案成立；出现警告 = 需完整移植微码数组。

## 五、合理省略与有意差异

| 差异 | 官方行为 | 0004 处理 | 判定 |
|---|---|---|---|
| ALDPS | `if (aspm && HW_HAS_WRITE_PHY_MCU_RAM_CODE) rtl8126_enable_phy_aldps()` | 省略 | ✓ 合理（无固件写入能力 + iPXE 无 ASPM 管理） |
| MCU patch 握手 | `set/clear_phy_mcu_patch_request` 轮询 ≤100ms | 省略（patch 参数 6 项本身已补，见 4.1） | ✓ 合理（无 MCU 时纯等超时；官方握手失败时也照写参数，省略与之等价） |
| 恢复路径 | `if (tp->resume_not_chg_speed) return` | 无此场景 | ✓ 合理（iPXE 无电源管理恢复） |
| 未知 ICVerID | 默认 `mcfg=3` + `HwIcVerUnknown`（不写微码） | 默认 `mcfg=3`（2026-08-12 修复，原为 2） | 已修复 ✓ |
| 族检测失败 | `mcfg=CFG_METHOD_DEFAULT`（=4） | 返回 -ENODEV 走 8125 老式识别 | ✓ 合理（iPXE 多芯片共存必要设计） |
| PHY MCU 微码 | 无固件时 C 数组直写 39KB | 版本检查 + 警告（轻量方案，见 4.3） | 待实机验证（出厂版本匹配则成立） |

## 六、实机验证检查清单（2026-08-12 更新）

1. **微码版本（首要）**：启动日志确认无 “PHY MCU firmware version … does not match expected” 警告——无警告则轻量方案成立（见 4.3）；出现警告则需评估完整移植 39KB 微码数组
2. **检测映射**：确认 ICVerID 与 mcfg 对应正确（ICVerID 0/1/2 → mcfg 1/2/3），未知 ICVerID 默认 mcfg=3（与官方一致）
3. **OCP 超时**：观察是否出现 “timed out waiting for GPHY OCP” 日志（现上限 20ms，与官方一致）
4. **补丁独有项**：若 PHY 行为异常，可用二分法逐一注释 8 项验证是否引入问题（见 4.2）

## 七、复现方法（对照审计脚本）

对照逻辑（python3，heredoc 内联）：

1. **提取官方操作序列**：按行号切分 `r8126_n.c` 的 `rtl8126_hw_phy_config_8126a_2`（L10731-11201）与 `_8126a_3`（L11202-11479），正则提取四类调用转为 `{reg, clear, set, write}` 元组（注意 `set_eth_phy_ocp_bit` 需 `(?<!clear_and_)` 负向后顾防止误匹配 `clear_and_set_eth_phy_ocp_bit` 子串；`BIT_n` 掩码展开为 `1<<n`；**必须对函数体做整段拼接后跨行匹配**——官方 `clear_and_set_eth_phy_ocp_bit` 参数多为多行格式，单行逐行正则会漏解析约 50 项（2026-08-12 教训））
2. **提取 0004 表**：按数组名正则匹配至 `+};`（补丁行带 `+` 前缀），解析 `{ 0x.., 0x.., 0x.., 0/1 }` 行
3. **差异分析**：`collections.Counter` 多重集相减得到真实缺失/新增；`difflib.SequenceMatcher` 用于顺序分析（注意重复序列会造成匹配歧义，多重集为准）

已知脚本陷阱：`for kind, pat in pats` 若元组顺序写反（`(pattern, 'W')` 解包为 `kind, pat`）会把 'W' 当正则匹配，groups() 为空导致误报——务必按 `(pattern, kind)` 解包。

## 八、2026-08-12 修复记录

| 修复项 | 依据 | 状态 |
|---|---|---|
| 8126a_2 表补 MCU patch 段 6 项 | 官方 `rtl8126_hw_phy_config_8126a_2` L10923-10934 | 已修复（审计复跑：官方独有 0 项） |
| OCP 等待超时 500us → 20ms | 官方 `R8126_CHANNEL_WAIT_COUNT(20000) × R8126_CHANNEL_WAIT_TIME(1us)` | 已修复（新增 `RTL_GPHY_OCP_MAX_WAIT_US`） |
| 未知 ICVerID 默认 mcfg 2 → 3 | 官方 `rtl8126_get_mac_version` default → CFG_METHOD_3 | 已修复 |
| PHY MCU 微码 | 官方 `rtl8126_init_hw_phy_mcu` / `set_phy_mcu_ram_code` | 轻量方案：版本检查+警告（用户决策，39KB 数组暂不移植） |

---

*本文档为移植忠实度审计记录，随上游源码演进需重新运行 §七 脚本更新对照结果。*

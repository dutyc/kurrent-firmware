# 设备信息上报（固件采集变量与用法）

[English](device-info-reporting.md) | [中文](device-info-reporting.zh-CN.md)

## 定位

设备信息采集 = 身份（SMBIOS type 1/2/3）、CPU（CPUID）、内存（SMBIOS type 17）、网卡（netdev 设置）四组设置项，经 HTTP GET query string 上报。官方能力优先：身份、CPU、网卡（除芯片名）字段官方已有；内存参数与网卡芯片名为唯一缺口，由补丁 `0004` 补齐（见 [customizations.zh-CN.md](customizations.zh-CN.md)）。

## 设置项清单

### 身份字段（SMBIOS，官方已有）

| 设置 | 来源 | 格式 | 示例 |
|---|---|---|---|
| `${uuid}` | SMBIOS type 1 | hex | `4c4c4544-...` |
| `${manufacturer}` | SMBIOS type 1 | 字符串 | `ASUSTeK COMPUTER INC.` |
| `${product}` | SMBIOS type 1 | 字符串 | `ROG Zephyrus G15` |
| `${serial}` | SMBIOS type 1 | 字符串 | 整机序列号 |
| `${board-serial}` | SMBIOS type 2 | 字符串 | 主板序列号 |
| `${asset}` | SMBIOS type 3 | 字符串 | 机箱资产标签 |

### CPU 字段（CPUID，官方已有）

| 设置 | 来源 | 格式 | 示例 |
|---|---|---|---|
| `${cpuvendor}` | CPUID leaf 0 | 字符串 | `GenuineIntel` / `AuthenticAMD` |
| `${cpumodel}` | CPUID 0x80000002-4（48B 品牌串） | 字符串 | `Intel(R) Core(TM) Ultra 7 155H` |

### 内存字段（SMBIOS type 17，补丁 `0004` 新增）

| 设置 | 来源 | 格式 | 示例 |
|---|---|---|---|
| `${mem-total}` | type 17 全插槽聚合 | uint32（MB） | `0x8000`（=32768 MB） |
| `${mem-type}` | type 17 首槽 | 字符串映射 | `DDR5` / `DDR4` / `Unknown` |
| `${mem-speed}` | type 17 首槽 | uint16（MT/s） | `0x15e0`（=5600 MT/s） |

聚合规则：`0xFFFF`（未知）跳过；`0x7FFF` 且结构长度 ≥0x20 时读 Extended Size（>32GB 场景）；其余按 bit15 单位换算（0=MB，1=GB×1024）。`mem-type` 映射覆盖 SDRAM / DDR~DDR5 / LPDDR~LPDDR5X / HBM~HBM3 等 18 项，未知名回退 `Unknown`。

数值设置按 iPXE 统一约定以十六进制展开（带 `0x` 前缀，`${net0/mtu}` 同理）；服务端需同时兼容 hex 与十进制解析（如 PHP `intval($v, 0)`）。

### 网卡字段（netdev 设置；`chip` 由补丁 `0004` 启用）

| 设置 | 内容 | 格式 | 示例 |
|---|---|---|---|
| `${netX/mac}` | 活动网卡 MAC | hex 无分隔符 | `10ff...` |
| `${netX/chip}` | PCI 设备表芯片名 | 字符串 | `RTL8125` / `I225-V` / `snpnet` |
| `${netX/busid}` | 总线类型 + venid + devid 编码 | hex | `0110ec8125` |
| `${netX/bustype}` | 总线类型 | 字符串 | `PCI` / `EFI` / `USB` |
| `${netX/linktype}` | 链路层类型 | 字符串 | `Ethernet` |

`netX` 为活动网卡别名（`last_opened_netdev()`，引导中最后打开的网卡），多网卡时自动指向当前引导卡；指定某卡用 `${net0/...}`。

变量写法要点：

| 写法 | 结果 | 说明 |
|---|---|---|
| `${netX}` | 空串 | **不可用**——`netX` 只作为块名（`/` 左侧）生效，裸展开不匹配任何设置 |
| `${netX/linktype}` 等 | 对应值 | 正确写法，必须带子设置名 |
| `${netX/ifname}` | `net0` | 想要“网卡名”用这个 |
| `${mac}` | 首张网卡 MAC | 裸名可用（递归查找第一个匹配块），多网卡精确取值仍用 `${netX/mac}` |

## 使用方法

### 注册上报（完整指纹）

```ipxe
chain --autofree http://mgmt.example.com/register.php?mac=${netX/mac}&uuid=${uuid}&manufacturer=${manufacturer}&product=${product}&serial=${serial}&cpumodel=${cpumodel}&mem-total=${mem-total}&mem-type=${mem-type}&mem-speed=${mem-speed}&chip=${netX/chip}&busid=${netX/busid}
```

### 后续启动（仅身份字段）

```ipxe
chain --autofree http://mgmt.example.com/boot.php?mac=${netX/mac}&uuid=${uuid}
```

### 控制台调试（实施验证点）

```ipxe
echo ${mem-total} ${mem-type} ${mem-speed}
echo ${netX/chip} ${netX/busid}
echo ${manufacturer} ${product} ${cpumodel}
```

### 健壮性（无 SMBIOS 时兜底）

```ipxe
isset ${mem-total} || set mem-total 0
isset ${netX/chip} || set chip unknown
```

## 注意事项

1. **URL 编码**：`manufacturer` / `product` / `cpumodel` / `serial` 可能含空格与特殊字符，iPXE 无内置 urlencode——真机实测：拼接前用 `echo` 检查展开结果，确认空格在 HTTP 请求中的行为（服务端是否截断）。
2. **SNP 引导**：`${netX/chip}` 显示 `snpnet`（驱动名），原生驱动才显示芯片型号。
3. **空值**：无 SMBIOS type 17 的环境（如虚拟机）`${mem-total}` 取不到；未定义变量在字符串中展开为空串，URL 会出现 `&x=`，服务端需容忍空值。
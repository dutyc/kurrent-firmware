# Device Information Reporting (Firmware-Collected Variables and Usage)

[English](device-info-reporting.md) | [中文](device-info-reporting.zh-CN.md)

## Purpose

Device information collection = four categories of settings: identity (SMBIOS type 1/2/3), CPU (CPUID), memory (SMBIOS type 17), and network adapter (netdev settings), reported via HTTP GET query string. Official capabilities are prioritized: identity, CPU, and network adapter fields (except chip name) are already available officially; memory parameters and the network adapter chip name are the only gaps, filled by patch `0004` (see [customizations.zh-CN.md](customizations.zh-CN.md)).

## Settings List

### Identity Fields (SMBIOS, officially available)

| Setting | Source | Format | Example |
|---|---|---|---|
| `${uuid}` | SMBIOS type 1 | hex | `4c4c4544-...` |
| `${manufacturer}` | SMBIOS type 1 | string | `ASUSTeK COMPUTER INC.` |
| `${product}` | SMBIOS type 1 | string | `ROG Zephyrus G15` |
| `${serial}` | SMBIOS type 1 | string | Whole-unit serial number |
| `${board-serial}` | SMBIOS type 2 | string | Motherboard serial number |
| `${asset}` | SMBIOS type 3 | string | Chassis asset tag |

### CPU Fields (CPUID, officially available)

| Setting | Source | Format | Example |
|---|---|---|---|
| `${cpuvendor}` | CPUID leaf 0 | string | `GenuineIntel` / `AuthenticAMD` |
| `${cpumodel}` | CPUID 0x80000002-4 (48-byte brand string) | string | `Intel(R) Core(TM) Ultra 7 155H` |

### Memory Fields (SMBIOS type 17, added by patch `0004`)

| Setting | Source | Format | Example |
|---|---|---|---|
| `${mem-total}` | type 17 aggregation across all slots | uint32 (MB) | `0x8000` (=32768 MB) |
| `${mem-type}` | type 17 first slot | string mapping | `DDR5` / `DDR4` / `Unknown` |
| `${mem-speed}` | type 17 first slot | uint16 (MT/s) | `0x15e0` (=5600 MT/s) |

Numeric settings expand in hexadecimal with a `0x` prefix, following the uniform iPXE convention (the same applies to `${net0/mtu}`); servers must parse both hex and decimal (e.g. `intval($v, 0)` in PHP).

Aggregation rules: `0xFFFF` (unknown) is skipped; when `0x7FFF` and structure length ≥0x20, read Extended Size (for >32GB scenarios); otherwise, convert units based on bit15 (0=MB, 1=GB×1024). The `mem-type` mapping covers 18 items including SDRAM / DDR~DDR5 / LPDDR~LPDDR5X / HBM~HBM3; unknown names fall back to `Unknown`.

### Network Adapter Fields (netdev settings; `chip` enabled by patch `0004`)

| Setting | Content | Format | Example |
|---|---|---|---|
| `${netX/mac}` | Active NIC MAC | hex without separators | `10ff...` |
| `${netX/chip}` | PCI device table chip name | string | `RTL8125` / `I225-V` / `snpnet` |
| `${netX/busid}` | Bus type + venid + devid encoding | hex | `0110ec8125` |
| `${netX/bustype}` | Bus type | string | `PCI` / `EFI` / `USB` |
| `${netX/linktype}` | Link-layer type | string | `Ethernet` |

`netX` is the alias for the active NIC (`last_opened_netdev()`, the last NIC opened during boot). With multiple NICs, it automatically points to the current boot NIC; to target a specific NIC, use `${net0/...}`.

Variable syntax essentials:

| Syntax | Result | Notes |
|---|---|---|
| `${netX}` | empty string | **Not usable** — `netX` only takes effect as a block name (left of `/`); bare expansion matches no setting |
| `${netX/linktype}` etc. | corresponding value | Correct syntax; a sub-setting name is required |
| `${netX/ifname}` | `net0` | Use this when you want the NIC name |
| `${mac}` | first NIC's MAC | Bare name works (recursive lookup of the first matching block); for precise value with multiple NICs, still use `${netX/mac}` |

## Usage

### Registration Reporting (Full Fingerprint)

```ipxe
chain --autofree http://mgmt.example.com/register.php?mac=${netX/mac}&uuid=${uuid}&manufacturer=${manufacturer}&product=${product}&serial=${serial}&cpumodel=${cpumodel}&mem-total=${mem-total}&mem-type=${mem-type}&mem-speed=${mem-speed}&chip=${netX/chip}&busid=${netX/busid}
```

### Subsequent Boot (Identity Fields Only)

```ipxe
chain --autofree http://mgmt.example.com/boot.php?mac=${netX/mac}&uuid=${uuid}
```

### Console Debugging (Implementation Verification Points)

```ipxe
echo ${mem-total} ${mem-type} ${mem-speed}
echo ${netX/chip} ${netX/busid}
echo ${manufacturer} ${product} ${cpumodel}
```

### Robustness (Fallback when no SMBIOS)

```ipxe
isset ${mem-total} || set mem-total 0
isset ${netX/chip} || set chip unknown
```

## Notes

1. **URL encoding**: `manufacturer` / `product` / `cpumodel` / `serial` may contain spaces and special characters. iPXE has no built-in urlencode — real-machine testing shows: before concatenation, use `echo` to inspect the expanded result, and confirm the behavior of spaces in the HTTP request (whether the server truncates).
2. **SNP boot**: `${netX/chip}` shows `snpnet` (driver name). Only native drivers display the chip model.
3. **Empty values**: In environments without SMBIOS type 17 (e.g., virtual machines), `${mem-total}` cannot be obtained. Undefined variables expand to an empty string in strings, causing `&x=` to appear in the URL; the server must tolerate empty values.
4. **Implementation basis**: The type 17 field offsets were cross-verified against three dmidecode versions (2016/2018/2024) — Memory Type `0x12`, Speed `0x15`, Extended Size `0x1C`. The early draft's `0x10`/`0x13` were incorrect; implementation follows the verified offsets.
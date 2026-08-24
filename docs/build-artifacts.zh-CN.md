# 构建产物

[English](build-artifacts.md) | [中文](build-artifacts.zh-CN.md)

构建流水线（`build.sh`）产出 7 种 UEFI 固件形态，分类输出至 `dist/`：

| 产物 | 目标形态 | 说明 |
|---|---|---|
| `dist/pxe-uefi/ipxe.efi` | PXE 网络启动（UEFI） | 无 EMBED，脚本由 DHCP 下发 |
| `dist/pxe-uefi/ipxe-debug.efi` | 同上（debug 版） | `DEBUG=realtek:3`，故障定位用 |
| `dist/pxe-uefi/snponly.efi` | PXE 网络启动（SNP 专用，UEFI） | 无 EMBED；固件 PXE 链加载时仅接管链加载设备，链加载定位失败时回退接管全部 SNP 设备 |
| `dist/pxe-uefi/snponly-debug.efi` | 同上（debug 版） | `DEBUG=realtek:3`，故障定位用 |
| `dist/direct-uefi/ipxe.efi` | UEFI 直接引导（含 EMBED） | 内置 auto.ipxe，启动即走引导链 |
| `dist/direct-uefi/ipxe-debug.efi` | 同上（debug 版） | `DEBUG=realtek:3`，故障定位用 |
| `dist/direct-uefi/snponly.efi` | UEFI 直接引导（SNP 专用，含 EMBED） | 使用固件 SNP 协议；native 驱动不可用的机器兜底 |

## 校验

`dist/SHA256SUMS` 为全部产物的 SHA-256 校验清单，在 `dist/` 目录内执行 `sha256sum -c SHA256SUMS` 验证。

## 如何选用

- **PXE 网络引导环境**（DHCP + 引导服务器）：UEFI 客户端用 `pxe-uefi/`。
- **直接 / 内置引导**（启动即走，无需 DHCP 脚本）：UEFI 用 `direct-uefi/`。
- **native 驱动不可用**：`snponly` 系列回退到固件 SNP 接口。
- **故障定位**：`-debug` 系列启用 `DEBUG=realtek:3`。

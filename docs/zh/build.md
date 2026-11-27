# 构建与产物

[English](../en/build.md) | [中文](build.md)

固件从固定的上游 iPXE 基线（`e6e51ccb`）加补丁链 `patches/0001-0012` 构建。
`build/build.sh` 应用补丁、内嵌 `embed/auto.ipxe`、构建 UEFI 目标并写入 `dist/`，
附带校验清单。

## 产物

| 产物 | 引导环境 | 说明 |
|---|---|---|
| `dist/pxe-uefi/ipxe.efi` | UEFI PXE | 原生驱动；引导脚本经 DHCP/TFTP 下发 |
| `dist/pxe-uefi/snponly.efi` | UEFI PXE/本地 | 仅 SNP；链式加载失败时回退接管全部 SNP/NII/MNP 设备（补丁 0003） |
| `dist/pxe-uefi/ipxe-debug.efi` | UEFI PXE | 调试构建（`DEBUG=realtek:3`） |
| `dist/pxe-uefi/snponly-debug.efi` | UEFI PXE | 调试构建（`DEBUG=realtek:3`） |
| `dist/direct-uefi/ipxe.efi` | UEFI 本地 | 内嵌 `embed/auto.ipxe` |
| `dist/direct-uefi/snponly.efi` | UEFI 本地 | 内嵌、仅 SNP |
| `dist/direct-uefi/ipxe-debug.efi` | UEFI 本地 | 调试构建（`DEBUG=realtek:3`） |

`dist/SHA256SUMS` 列出各产物的 SHA-256 校验和，在 `dist/` 内用
`sha256sum -c SHA256SUMS` 校验。

查看 `nvmetcp` 驱动日志用 `DEBUG=nvmetcp:3` 重建；认证模块是独立源文件，
需用 `DEBUG=nvmetcp,nvmetcp_auth:3`。

## Secure Boot 形态

可选签名形态由 `build/build-sb.sh` 单独构建，不替换上面七个产物，也不应用
`patches/secureboot/` 之外的任何补丁。

| 变量 | 含义 |
|---|---|
| `SB_KEY`、`SB_CERT` | 产物签名密钥/证书（离线保存） |
| `SB_PK_KEY`、`SB_PK_CERT`、`SB_KEK_KEY`、`SB_KEK_CERT` | 平台密钥注册材料；只有证书与签名进入镜像 |
| `SB_MS_UEFI_CA_CERT` | 加入 `db` 的 Microsoft UEFI CA 2011 证书 |
| `BOOT_CA_CERT` | 引导 CA（PEM，`basicConstraints CA:TRUE`）；同时内嵌证书与指纹 |
| `BOOT_HTTPS_PORT` | 内嵌到镜像的引导端点端口（默认 4443） |
| `CONTROLLER_IP` | 固定控制面 IPv4；默认取 DHCP `next-server` |
| `KURRENT_SB_TARGET` | `snponly`（默认）或 `ipxe`（全驱动首跳） |
| `KURRENT_SB_OUT_DIR` | 输出目录；默认 `dist/secureboot` |

构建应用 `patches/secureboot/0001-no-tofu.patch` 覆盖层，使错误 CA 的握手被
拒绝，而不是在首次接触时被接受并固定。输出：

```
dist/secureboot/
  snponly-sb.efi
  pxe-uefi/snponly-sb.efi
  direct-uefi/snponly-sb.efi
  manifest.json
  SHA256SUMS
```

`KURRENT_SB_TARGET=ipxe` 产出 `ipxe-sb.efi`，布局相同；两个目录副本与根产物
逐字节一致。`tools/verify-sb.sh` 校验签名、校验清单、manifest，以及输出中没有
密钥或 PEM 文件。

签名镜像在 Setup Mode（或关闭 Secure Boot）下启动，平台注册窗口开启时运行
`sbenroll` 写入 PK/KEK/db 后重启进入验签引导。`sbenroll` / `/boot/phase` 契约与
设备身份流程见 [interface.md](interface.md)。

## 网卡支持

原生驱动适配高性能网卡（2.5G 及以上）；普通 100M/1G 网卡保持上游基线支持。

- **原生驱动**：Intel e1000e / I210 / I211 / I350 / I219 / I225 / I226、
  82599 / X540 / X550 / X710 / E810；Realtek RTL8136–8169、RTL8125（补丁 0001，
  已实测）、RTL8126（补丁 0001，构建验证，真机待测）；Marvell/Aquantia AQC；
  Broadcom tg3 / bnx2 / bnxt；virtio / vmxnet3 / ENA / GVE / netvsc；所列 USB
  网卡类别。
- **协议层**（`snponly.efi`）：自带 UEFI SNP 引导 ROM 的网卡无需原生移植——
  Mellanox ConnectX-4/5/6/7 与 Broadcom bnx2x。它们带有 SNP 的 iSCSI 挂起风险。
- **不支持**：Realtek USB RTL8152/8153/8156；现代 Wi-Fi。
- **有条件**：部分 Realtek RTL8168 版本原生初始化挂起（走 SNP 回退）。实测记录在
  归档中。

## 母盘辅助脚本

`test/*/golden-image-setup-*.sh` 内嵌运行期组件的 base64 副本（`initramfs-nbft`
文件、GRUB 2.14 镜像与共享库）。组件变更后重新内嵌并校验：

```bash
python3 test/shared/embed-components.py
python3 test/shared/verify-embed.py
```

`test/shared/assets/BOOTX64-2.14-generic.EFI` 是由未修改上游源码构建的
GNU GRUB 2.14 `x86_64-efi` 镜像。

# 固件接口契约

[English](../en/interface.md) | [中文](interface.md)

本页是固件与 Kurrent 控制面之间的唯一契约：列出固件发送与消费的内容。
实现细节在补丁链与归档中。

## 引导链

默认固件（`embed/auto.ipxe`）：

```
dhcp → chain tftp://${next-server}/boot.ipxe
```

`next-server` 由 DHCP 提供，同机部署时即控制面地址。`boot.ipxe` 之后的一切由
控制面下发，固件不内嵌业务脚本。

Secure Boot 固件（`embed/secureboot/`）：`auto.ipxe` 链接内嵌的
`sb-boot.ipxe.cfg`（平台密钥注册门 + TPM 证明流程）与 `sb-menu.ipxe`
（NVMe-oF 系统引导、shell、重启、退出）。

## 控制面端点

以下端点均匿名并限速，对注册只读（注册只在窗口期经 `/devices/report` 发生）。

| 端点 | 请求 | 响应 |
|---|---|---|
| `GET /boot/phase` | — | 平台注册窗口开启时返回运行 `sbenroll` 的 `#!ipxe` 体；否则空体 |
| `GET /devices/enroll-report` | `mac`、`result` | `sbenroll` 之后消费 |
| `GET /devices/report` | 见下 | 空 `#!ipxe` 体 |
| `GET /devices/challenge` | `mac` | `#!ipxe` 体 `set nonce <64 hex>` |
| `GET /boot-vars` | 见下 | 设置引导变量的 `#!ipxe` 体（`?format=json` 返回 JSON） |

### `GET /devices/report`

固件设备上报（补丁 0004 + TPM 身份）：

```
mac, uuid, manufacturer, product, serial, cpumodel,
mem-total, mem-type, mem-speed, chip, busid,
ak_public, ak_name, ak_type, sb
```

`mem-total` / `mem-type` / `mem-speed` 来自 SMBIOS type 17；`chip` 是 PCI 网卡
设备名（`${net0/chip}`）。`ak_public` / `ak_name` / `ak_type` 是 TPM 证明密钥
身份，`sb` 是 EFI Secure Boot 状态（`1`/`0`）。

### `GET /boot-vars`

```
mac, hostname, nonce, quote, quote_sig
```

识别链为 `mac → 设备台账 → 绑定 worker`；`hostname` 仅作回退查找，不作为数据面
身份。凭据变量只在所发 nonce 的 TPM quote 验签通过后下发；未验签时只返回菜单
变量。

响应体设置的变量：

| 变量 | 含义 |
|---|---|
| `disk-nqn` | 默认盘的完整 NVMe 子系统 NQN |
| `base-iqn` | 由盘 IQN 派生的 iSCSI base 前缀（供 `initiator-iqn`） |
| `storager-ip` | 存储节点数据面地址 |
| `iscsi-sep` | iSCSI root 连接符（stgt 为 `:::1:`，LIO 为 `::::`）；仅 nvmet 之外的后端 |
| `hostnqn` | 固件连接的 host NQN 覆盖值 |
| `nbft-secret` | DH-HMAC-CHAP 密钥（`DHHC-1:…`） |
| `nbft-tls-psk` | TLS 1.3 PSK（64 hex），由认证密钥派生 |
| `nbft-tls-port` | NVMe/TCP TLS 数据面端口 |
| `os`、`os-version` | 菜单默认系统标签 |
| `menu-default`、`menu-timeout` | 菜单行为 |

## TPM 证明

固件在 TPM 内创建证明密钥（`TPM2_CreatePrimary`，属性 `restricted | sign`，
持久化句柄 `0x81000001`；优先 ECC P-256，回退 RSA-2048）。无软件回退：没有
TPM 时命令以 `-ENODEV` / `-ENOENT` 失败。

| 命令 | 结果 |
|---|---|
| `akgen` | 创建或报告已有密钥 |
| `akpub` | 导出 `ak-public`、`ak-name`、`ak-type`、`sb` |
| `quote <nonce>` | 对 PCR 0/2/4/7 执行一次 `TPM2_Quote`，导出 `quote` 与 `quote-sig` |
| `nvclear` | 清除非易失存储中的 `server-fingerprint` 与 `trust` |

六个证明设置以 DHCP 标签 0x60-0x65 暴露，仅本次引导有效；`sbenroll` 以标签
0x66 发布 `sbenroll-result`。

## NVMe-oF 连接

URI 形态：

```
nvme://<traddr>:<trsvcid>/<nqn>[?secret=<DHHC-1 key>][&tls_psk=<hex>][&tls_trsvcid=<port>]
```

当 URI 端口等于 `tls_trsvcid` 时，固件对该连接执行 TLS 1.3 PSK 握手（身份
`NVMe0R01 <hostnqn> <subsysnqn>`）；否则为明文连接，仅用于本地测试目标。
生产使用单一 TLS 端口；端口或密钥缺失时控制面不下发引导变量，无明文回退。

## NBCT 凭据接力

认证引导时，固件安装一张内存中的 ACPI 表，签名 `NBCT`，按会话携带
`traddr` / `trsvcid` / `nqn` / `hostnqn` / `secret` / `tls_trsvcid` / `tls_psk`。
initramfs 种子模块（`initramfs-nbft/nbft-connect`）读取该表，以
`nvme connect --dhchap-secret` 或 `--tls` 重连，内核段不再二次从网络取凭据。

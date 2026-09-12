# NIC Support Matrix

[English](network-support.md) | [中文](network-support.zh-CN.md)

NIC support status of this repository's firmware (upstream baseline `e6e51ccb` + custom patches), based on the source driver device tables (`src/drivers/net/`) and this project's field-test records. Status may change after upstream upgrades or new patches.

## Focus

This repository focuses on **porting and adapting drivers for high-performance NICs at 2.5G / 5G and above** (e.g. the RTL8125 / RTL8126 series); ordinary 100M/1G NICs only keep their upstream baseline support and receive **no further adaptation or updates**.

Status legend:

- **Well covered** — mature driver or field-tested, safe to use
- **Conditional** — driver exists with known issues or limitations
- **Via protocol layer** — no native driver; runs on the NIC-shipped UEFI SNP / BIOS UNDI boot ROM (snponly.efi / undionly.kpxe); carries the SNP caveats listed under Conditional
- **Unsupported** — no driver in the baseline (including this project's patch scope)

## Well Covered

| NIC | Driver | Notes |
|---|---|---|
| Intel e1000e series (82540 → latest I219 stepping) | intel.c | **Field-tested** (direct-uefi ipxe.efi) |
| Intel I210 / I211 / I350 / 82576 | intel.c | Includes server-common I350 |
| **Intel I225 / I226** (2.5G, mainstream mainboards) | intel.c | Full stepping coverage: I225 (0x15f2/15f3/0d9f/5502), I226 (0x125b/125c/125d) |
| Intel 82599 / X540 / X550 / X553 / X552 (10G) | intelx.c | Includes X553-AT (10GBASE-T) |
| Intel X710 / XL710 (10G / 40G) | intelxl.c | Common on servers |
| Intel E810 / E823 (25G / 100G) | ice.c | Newer driver |
| Realtek RTL8136 / 8139 / 8129 / 8167 / 8168 / 8169 | realtek.c | Baseline native |
| **Realtek RTL8125 series** (2.5G) | realtek.c (patch 0001) | **Field-tested DHCP**; native driver adaptation |
| **Realtek RTL8126** (5G, 2024 NIC) | realtek.c (patch 0001) | **Build-verified** (GPHY OCP/CSI mechanisms, 3 PHY static configuration tables); hardware field test pending |
| Marvell/Aquantia AQC100 / 107 / 108 / 109 / 111 / 112 / 113 / 114 (10G / 5G / 2.5G) | aqc1xx.c | Full device-table coverage incl. AQC113 (Atlantic 2); common on high-end mainboards / industrial boards |
| Broadcom BCM57xx gigabit (tg3, 82 devices) | tg3 | Wide coverage |
| Broadcom BNX2 (BCM5706/5708 etc.) | bnx2 | Older 1G/10G family |
| Broadcom NetXtreme-E (BCM957xxx) | bnxt | Newer server family |
| Virtualisation: virtio / vmxnet3 / ENA(AWS) / GVE(GCP) / netvsc(Hyper-V) | — | Full cloud-native coverage |
| USB: AX88179 (axge), LAN7800 (lan78xx), SMSC95xx/75xx, DM96xx, CDC ECM/NCM | — | Only these USB NIC classes |

## Via Protocol Layer (No Native Driver)

Some server-grade NICs ship their own boot ROM (UEFI SNP / BIOS UNDI); these need no driver port — the protocol-layer firmware (snponly.efi / undionly.kpxe) runs on the NIC-shipped PXE stack and provides full iPXE capability. A native port is intentionally skipped when its cost (e.g. the mlx5 firmware-command architecture) is disproportionate to the benefit.

| NIC | Path | Notes |
|---|---|---|
| **Mellanox ConnectX-4 / 5 / 6 / 7** (25G / 40G / 100G, servers) | snponly.efi (UEFI) / undionly.kpxe (BIOS) | Zero adaptation; carries the SNP caveats under Conditional (iSCSI hang risk) |
| Broadcom bnx2x family (BCM57710/57711/57712/57800/57810/57840, 10G, NetXtreme II) | snponly.efi (UEFI) / undionly.kpxe (BIOS) | Server NICs ship official Broadcom boot ROM; zero adaptation; carries the SNP caveats under Conditional (iSCSI hang risk) |

## Unsupported (Key Risks)

| NIC | Scenario | Notes |
|---|---|---|
| **Realtek USB RTL8152 / 8153 / 8156** | Laptop USB-C to RJ45 (most common) | No driver in iPXE |
| Modern WiFi (Intel AX, Realtek 88 series) | Laptop | Only vintage prism2 / rtl818x |

## Conditional (Known Issues)

- **Realtek RTL8168, some versions**: native driver initialisation hangs (field-proven in this project; investigation terminated) — use the SNP fallback, see [8168-research-log.md](8168-research-log.md)
- **SNP driver iSCSI hang** (field-proven in this project): affects **every NIC without a native driver that must use the UEFI NIC driver** — i.e. NICs booted via SNP (Unsupported and Via Protocol Layer sections) carry the same risk
- **Intel I219 series**: special `INTEL_PBSIZE_RST` / `NO_PHY_RST` handling (historic bug fixes, low practical impact)
- **Marvell/Aquantia AQC series**: Marvell-official lightweight driver (~1/6 of Linux atlantic); link negotiation relies on hardware auto-negotiation (no rate management); dynamic firmware load for AQC113 not implemented (fails with `-ENOTSUP` if NIC firmware is blank); no field-test record in this project
- **82599 / X550 (SFP+)**: compatibility depends on transceiver quality

## Field-Test Records

| Date | NIC | Firmware | Result |
|---|---|---|---|
| 2026-08-07 | Realtek RTL8125 | SNP firmware | iSCSI mount hang (native driver takeover) |
| 2026-08-09 | Realtek RTL8168 | native driver | Initialisation hang on some versions (SNP fallback) |
| 2026-08-10 | Intel e1000 (82540EM etc.) | direct-uefi ipxe.efi | Passed |
| 2026-08-11 | Realtek RTL8125 | Custom firmware (patch 0001) | OK |

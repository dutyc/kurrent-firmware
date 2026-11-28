# Build and Artifacts

[English](build.md) | [中文](../zh/build.md)

The firmware is built from a pinned upstream iPXE baseline (`e6e51ccb`) plus the
patch chain `patches/0001-0012`. `build/build.sh` applies the patches, embeds
`embed/auto.ipxe`, builds the UEFI targets and writes them under `dist/` with a
checksum list.

## Artifacts

| Artifact | Boot environment | Notes |
|---|---|---|
| `dist/pxe-uefi/ipxe.efi` | UEFI PXE | Native drivers; boot script served over DHCP/TFTP |
| `dist/pxe-uefi/snponly.efi` | UEFI PXE/local | SNP-only; falls back to taking over all SNP/NII/MNP devices when chainloading fails (patch 0003) |
| `dist/pxe-uefi/ipxe-debug.efi` | UEFI PXE | Debug build (`DEBUG=realtek:3`) |
| `dist/pxe-uefi/snponly-debug.efi` | UEFI PXE | Debug build (`DEBUG=realtek:3`) |
| `dist/direct-uefi/ipxe.efi` | UEFI local | Embeds `embed/auto.ipxe` |
| `dist/direct-uefi/snponly.efi` | UEFI local | Embedded, SNP-only |
| `dist/direct-uefi/ipxe-debug.efi` | UEFI local | Debug build (`DEBUG=realtek:3`) |

`dist/SHA256SUMS` lists the SHA-256 checksums; verify with
`sha256sum -c SHA256SUMS` inside `dist/`.

To see `nvmetcp` driver logs, rebuild with `DEBUG=nvmetcp:3`; the authentication
module is a separate source file, so use `DEBUG=nvmetcp,nvmetcp_auth:3`.

## Secure Boot profile

An optional signed profile is built separately with `build/build-sb.sh`. It
does not replace the seven artifacts above and never applies anything from
`patches/secureboot/`.

| Variable | Meaning |
|---|---|
| `SB_KEY`, `SB_CERT` | Artifact signing key/certificate (offline) |
| `SB_PK_KEY`, `SB_PK_CERT`, `SB_KEK_KEY`, `SB_KEK_CERT` | Enrollment key material; only certificates and signatures reach the image |
| `SB_MS_UEFI_CA_CERT` | Microsoft UEFI CA 2011 certificate added to `db` |
| `BOOT_CA_CERT` | Boot CA (PEM, `basicConstraints CA:TRUE`); embedded as certificate and fingerprint |
| `BOOT_HTTPS_PORT` | Boot endpoint port baked into the image (default 4443) |
| `CONTROLLER_IP` | Fixed controller IPv4 address; default is DHCP `next-server` |
| `KURRENT_SB_TARGET` | `snponly` (default) or `ipxe` (all-drivers first hop) |
| `KURRENT_SB_OUT_DIR` | Output directory; default `dist/secureboot` |

The build applies the `patches/secureboot/0001-no-tofu.patch` overlay so that a
wrong-CA handshake is rejected instead of being accepted and pinned on first
contact. Output:

```
dist/secureboot/
  snponly-sb.efi
  pxe-uefi/snponly-sb.efi
  direct-uefi/snponly-sb.efi
  manifest.json
  SHA256SUMS
```

`KURRENT_SB_TARGET=ipxe` produces `ipxe-sb.efi` with the same layout. The two
directory copies are byte-identical to the root artifact. `tools/verify-sb.sh`
checks the signatures, the checksum list, the manifest and that no key or PEM
file ended up in the output.

The signed image boots in Setup Mode (or with Secure Boot off), and when a
registration window is open it runs `sbenroll` to install PK/KEK/db and reboot
into verified boot. See [interface.md](interface.md) for the `sbenroll` /
`/boot/phase` contract and the device-identity flow.

## NIC support

Native drivers are adapted for high-performance NICs (2.5G and above); ordinary
100M/1G NICs keep their upstream baseline support.

- **Native drivers**: Intel e1000e / I210 / I211 / I350 / I219 / I225 / I226,
  82599 / X540 / X550 / X710 / E810; Realtek RTL8136–8169, RTL8125 (patch 0001,
  field-tested) and RTL8126 (patch 0001, build-verified, hardware field test
  pending); Marvell/Aquantia AQC; Broadcom tg3 / bnx2 / bnxt; virtio / vmxnet3 /
  ENA / GVE / netvsc; the listed USB NIC classes.
- **Protocol layer** (`snponly.efi`): NICs that ship their own UEFI SNP boot ROM
  need no native port — Mellanox ConnectX-4/5/6/7 and Broadcom bnx2x. They carry
  the SNP iSCSI-hang risk.
- **Unsupported**: Realtek USB RTL8152/8153/8156; modern Wi-Fi.
- **Conditional**: some Realtek RTL8168 versions hang during native
  initialisation (use the SNP fallback). The field-test records are in the
  archive.

## Golden image helpers

`golden/*/golden-image-setup-*.sh` embed base64 copies of their runtime
components (the `initramfs-nbft` files, the GRUB 2.14 image and the shared
library). After changing a source, regenerate and verify them:

```bash
python3 golden/shared/embed-components.py
python3 test/shared/verify-embed.py
```

`golden/shared/assets/BOOTX64-2.14-generic.EFI` is a GNU GRUB 2.14 `x86_64-efi`
image built from unmodified upstream sources.

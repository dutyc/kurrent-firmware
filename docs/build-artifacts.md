# Build Artifacts

[English](build-artifacts.md) | [中文](build-artifacts.zh-CN.md)

The build pipeline (`build.sh`) compiles the firmware into 7 UEFI form factors, categorized and written to `dist/`:

| Artifact | Form factor | Description |
|---|---|---|
| `dist/pxe-uefi/ipxe.efi` | PXE boot (UEFI) | No EMBED; boot script served via DHCP |
| `dist/pxe-uefi/ipxe-debug.efi` | Same (debug build) | `DEBUG=realtek:3`, for fault diagnosis |
| `dist/pxe-uefi/snponly.efi` | PXE boot (SNP-only, UEFI) | No EMBED; with firmware PXE chainloading takes over only the chainloaded device; falls back to all SNP devices when chainload location fails |
| `dist/pxe-uefi/snponly-debug.efi` | Same (debug build) | `DEBUG=realtek:3`, for fault diagnosis |
| `dist/direct-uefi/ipxe.efi` | UEFI direct boot (EMBED) | Embeds `auto.ipxe`; boot-and-go boot chain |
| `dist/direct-uefi/ipxe-debug.efi` | Same (debug build) | `DEBUG=realtek:3`, for fault diagnosis |
| `dist/direct-uefi/snponly.efi` | UEFI direct boot (SNP-only, EMBED) | Uses firmware SNP protocol; fallback path for machines where native drivers fail |

## Checksums

`dist/SHA256SUMS` lists the SHA-256 checksums of all artifacts; verify with `sha256sum -c SHA256SUMS` inside `dist/`.

## Choosing an Artifact

- **PXE boot environments** (DHCP + boot server): `pxe-uefi/` for UEFI clients.
- **Direct / embedded boot** (boot-and-go, no DHCP script): `direct-uefi/`.
- **Native-driver failures**: `snponly` variants fall back to the firmware SNP interface.
- **Fault diagnosis**: `-debug` variants enable `DEBUG=realtek:3`.

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

## Secure Boot profile

`build-sb.sh` produces a separate signed set under `dist/secureboot/`
(`snponly-sb.efi`, `manifest.json`, `SHA256SUMS`). It does not replace or
modify the seven artifacts above. See [secureboot.md](../secureboot.md).

## Golden image helpers

The scripts under `test/*/golden-image-setup-*.sh` embed base64 copies of
their runtime components: the initramfs-nbft files, the GRUB image and the
shared library. Regenerate them after changing a source, then verify that
every copy matches:

```bash
python3 test/shared/embed-components.py
python3 test/shared/verify-embed.py
```

`test/shared/assets/BOOTX64-2.14-generic.EFI` is a GNU GRUB 2.14
`x86_64-efi` image built with `grub-mkimage` from unmodified upstream
sources; its module set is the superset of the minimal set recorded in
[golden-image-customization-debian12.md](golden-image-customization-debian12.md) §6.3.
GRUB is licensed under GPL-3.0-or-later; the corresponding source is
upstream GNU GRUB 2.14. The embedded copy has SHA-256
`d912bcd33be528f5520dbc0121a8197ebad9065c8329ee4afc710a8c2986b691`.

## Choosing an Artifact

- **PXE boot environments** (DHCP + boot server): `pxe-uefi/` for UEFI clients.
- **Direct / embedded boot** (boot-and-go, no DHCP script): `direct-uefi/`.
- **Native-driver failures**: `snponly` variants fall back to the firmware SNP interface.
- **Fault diagnosis**: `-debug` variants enable `DEBUG=realtek:3`.

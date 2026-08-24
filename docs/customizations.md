# Customizations

[English](customizations.md) | [中文](customizations.zh-CN.md)

Every customization in this repository, relative to the upstream iPXE baseline (default `e6e51ccb`), consists of **twelve patches** plus a **build-level EMBED customization** (`embed/auto.ipxe`, compiled into the firmware via `EMBED=`, not a patch).

| # | Patch | Scope |
|---|---|---|
| 0001 | `0001-realtek-8125-adaptation.patch` | RTL8125 (2.5G) series native driver adaptation |
| 0002 | `0002-makefile-ipxe-debug.patch` | Debug build fix |
| 0003 | `0003-snponly-local-boot.patch` | snponly local boot support |
| 0004 | `0004-realtek-8126-adaptation.patch` | RTL8126 (5G) native driver adaptation |
| 0005 | `0005-device-info-collection.patch` | Device info collection: SMBIOS type 17 memory settings (`mem-total` / `mem-type` / `mem-speed`) + PCI device-table name via `${net0/chip}` |
| 0006 | `0006-nvmeof-adaptation.patch` | NVMe-oF (NVMe over TCP) SAN protocol support |
| 0007 | `0007-nvmetcp-auth-fix.patch` | NVMe/TCP authentication and state-machine fixes |
| 0008 | `0008-efi-nvs-backend.patch` | EFI variable NVS backend (`device-key` / `server-fingerprint` persist across reboot) |
| 0009 | `0009-tofu-fingerprint.patch` | TOFU fingerprint chain (first-contact TLS acceptance, fingerprint storage) |
| 0010 | `0010-devicekey-commands.patch` | Device identity key commands (`keygen` / `pubkey` / `sign`) |
| 0011 | `0011-nvmetcp-hostnqn-setting.patch` | NVMe/TCP host NQN setting (per-MAC identity override for strict-mode authentication) |
| 0012 | `0012-nvmetcp-nbct-acpi-table.patch` | NVMe boot credentials table (NBCT ACPI handoff of DH-HMAC-CHAP secret + host NQN to the kernel side) |

## Design Rationale

Many mainboards have no PXE boot option, or make it painful to use (BIOS without a Network Boot entry, UEFI network stack disabled by default, per-machine BIOS configuration with Secure Boot restrictions). Instead of depending on mainboard PXE, this repository provides firmware that boots from local media (USB / disk / GRUB2 chainload) and automatically enters the network boot flow — `embed/auto.ipxe` (EMBED customization) and `0003` (SNP local boot adaptation) exist for this purpose.

Customizations are maintained as patches rather than a fork: a fork branch needs continuous merging on every upstream upgrade, which is too costly. This repository instead uses:

```
upstream ipxe source (pinned baseline commit)
    +
patches/ (diff files, single source of truth)
    +
embed/ (script assets)
    ↓ build/build.sh
dist/ (seven firmware artifacts + SHA256SUMS)
```

All patches are generated against the **same pinned upstream baseline**; upgrading upstream means regenerating the patches (see [patches/README.md](../patches/README.md)).

## Customization Details

### 1. RTL8125 series adaptation (`0001`)

- **Rationale**: RTL8125 (2.5G) NICs must be handled by the iPXE native driver — the firmware SNP driver hangs in iSCSI mount scenarios and cannot be used for diskless boot; upstream iPXE has incomplete support for some 8125 versions (XID 0x688 series).
- **Changes**: `src/drivers/net/realtek.c`, `realtek.h`
  - XID 0x688 version table and device identification
  - EPHY initialisation table (2.5G PHY configuration)
  - 32-bit interrupt status register
  - FETCH / PAUSE_SLOT configuration
  - BAR 0x4808 (2.5G-specific register window)
  - TPPOLL_8125 polling
- **Licence**: the 8125 adaptation is derived from the Linux kernel r8169 driver (GPL-2.0-only); it is licensed under GPL-2.0 only and may not be redistributed under UBDL (see the header of `patches/0001`).

### 2. Debug build fix (`0002`)

- **Rationale**: the `ipxe-debug.efi` target had no driver set defined, so the artifact was an empty shell (no NIC drivers at all) and useless for fault diagnosis.
- **Changes**: `src/Makefile` — added `DRIVERS_ipxe-debug += $(DRIVERS_ipxe)` so the debug target inherits the full driver set.

### 3. snponly local boot support (`0003`)

- **Rationale**: the official `snponly.efi` only supports firmware-PXE chainload scenarios (it takes over only the device that loaded iPXE); booting from local UEFI (USB / disk) finds no NIC and drops straight to the shell. This is the companion adaptation for the "mainboard has no PXE boot option" scenario — local-media boot also needs network takeover capability.
- **Changes**: `src/drivers/net/efi/snponly.c` — when chainload location fails, fall back to taking over all SNP/NII/MNP devices; PXE chainload behaviour is unchanged.
- **Effect**: machines where native drivers are unavailable (e.g. RTL8168 initialisation hangs on certain mainboards) still have an SNP fallback path for local boot.

### 4. RTL8126 5GbE adaptation (`0004`)

- **Rationale**: RTL8126 (5G) is a 2024 NIC with no `0x8126` device entry in the upstream iPXE baseline. Its GPHY must be initialised with one of three PHY configuration methods (static register tables) selected by ICVerID, and some PCIe configuration (ZRXDC timeout reporting, ASPM entry latency) requires the CSI mechanism to access extended configuration space — none of which the baseline driver has.
- **Changes**: `src/drivers/net/realtek.c`, `realtek.h`
  - `0x8126` device entry and `realtek_detect_8126` (TxConfig 0x64800000 family detection + ICVerID → mcfg 1/2/3 dispatch)
  - GPHY OCP interface functions (`realtek_gphy_ocp_read/write/modify`, refactored from the 0001 inlined MII access and reused)
  - CSI extended configuration space interface (`realtek_csi_read/write/modify`, same mechanism as Linux `rtl_csi_*`)
  - PHY static configuration tables x3 (`realtek_8126a_1/2/3_phy`, 367 entries in total, from the official r8126 driver; MCU microcode section excluded; direct-write vs read-modify-write semantics distinguished, corresponding to the official `rtl8126_mdio_direct_write_phy_ocp` and `rtl8126_clear_and_set_eth_phy_ocp_bit` respectively) and `realtek_hw_phy_config_8126`
  - `realtek_hw_start_8126`: ZRXDC disabled + default ASPM entry latency (CSI path) + 8125 common initialisation + PHY configuration
  - Mount points: `realtek_detect` / `realtek_open` / `realtek_probe` dispatch on `mac_ver == 70`
- **Verification**: full build passes all 10 artifacts (including the `DEBUG=realtek:3` debug target); field testing on physical hardware pending.
- **Audit**: the dual-source PHY table audit and the lightweight PHY MCU firmware version-check policy are documented in [8126-porting-audit.md](8126-porting-audit.md) (Chinese only).
- **Licence**: the 8126 adaptation is derived from the Realtek r8126 driver (GPL-2.0-only, Copyright 2025 Realtek Semiconductor Corp.) and the Linux kernel r8169 driver (GPL-2.0-only); it is licensed under GPL-2.0 only and may not be redistributed under UBDL (see the header of `patches/0004`).

### 5. Device information collection (`0005`)

- **Rationale**: firmware-side device info collection (identity / CPU / memory / NIC) for HTTP reporting. Identity (SMBIOS types 1-3) and CPU (CPUID) settings are already provided upstream, leaving two gaps: no named settings for SMBIOS type 17 (memory devices, one structure per slot), and PCI NICs never populate `driver_name`, so `${net0/chip}` was unusable on PCI.
- **Changes**: `src/include/ipxe/smbios.h`, `src/interface/smbios/smbios_settings.c`, `src/drivers/bus/pci.c`
  - `struct smbios_memory_device` (type 17 layout verified against three dmidecode versions: Memory Type `0x12`, Speed `0x15`, Extended Size `0x1C`) + `SMBIOS_TYPE_MEMORY_DEVICE 17`
  - `${mem-total}` (uint32 MB, aggregated over all modules: `0xFFFF` skipped, `0x7FFF` falls back to Extended Size, bit 15 = GB), `${mem-type}` (first module, mapped to strings such as `DDR5`), `${mem-speed}` (first module, MT/s) — custom fetches dispatched by name, reusing the existing SMBIOS settings scope
  - `pci_probe` now sets `driver_name` from the matching device-table entry, enabling `${net0/chip}` (e.g. `RTL8125`) for all PCI NICs
- **Usage**: settings reference and report URL templates in [device-info-reporting.md](device-info-reporting.md) / [device-info-reporting.zh-CN.md](device-info-reporting.zh-CN.md).
- **Verification**: full build passes all 10 artifacts; settings embedded (strings check); behaviour on real hardware pending (URL encoding of spaces / special characters).

### 6. NVMe-oF (NVMe over TCP) SAN support (`0006`)

- **Rationale**: upstream iPXE has no NVMe-oF transport support; SAN boot from NVMe/TCP targets (e.g. Linux `nvmet`) requires a full protocol driver plus a `SANBOOT_PROTO_NVME_TCP` config option.
- **Changes**: `src/config/config.c`, `src/config/general.h` (`SANBOOT_PROTO_NVME_TCP`), `src/include/ipxe/errfile.h`, `src/include/ipxe/nvmetcp.h`, `src/net/tcp/nvmetcp.c`, `src/net/tcp/nvmetcp_auth.c`, `src/tests/nvmetcp_test.c`, `src/tests/tests.c`
  - 8-phase state machine: ICReq/ICResp parameter negotiation → Connect (Admin) → Property Set (CC.EN=1) → Identify (controller/namespace) → Connect (I/O) → block read/write with R2T flow control
  - DH-HMAC-CHAP authentication (AuthSend/AuthReceive, DH groups 0/2048/3072/4096)
  - EFI device-path description and BlockIo hooking for `sanboot`; unit tests (structure layout + Identify NS parsing)
- **Usage**: end-to-end guide (nvmet target setup incl. auth, `sanboot` syntax, QEMU validation) in [nvmeof-usage.md](nvmeof-usage.md) (Chinese only).
- **Verification**: QEMU/OVMF + Ubuntu 26.04 kernel 7.0 nvmet target, GRUB 2.14 SAN boot chain passing (see [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md), Chinese only).
- **Licence**: original kurrent-firmware implementation, `FILE_LICENCE ( GPL2_ONLY )` — GPL-2.0 only, not redistributable under UBDL.

### 7. NVMe/TCP authentication and state-machine fixes (`0007`)

- **Rationale**: three bugs found while validating the 0006 auth path end-to-end against nvmet: transient `-EAGAIN` killed the session instead of waiting for the TCP window, AuthReceive could be sent twice, and the auth-complete race (phase switched before the final AuthReceive completion, so the Property Set was skipped and Identify was rejected).
- **Changes**: `src/include/ipxe/nvmetcp.h`, `src/net/tcp/nvmetcp.c`, `src/net/tcp/nvmetcp_auth.c`, `src/tests/nvmetcp_test.c`
  - Transient `-EAGAIN` handling (defer the process, resume on window) and idempotent AuthReceive send with unified step advancement
  - Auth phase completion gated by `completed`/`rx_complete` flags plus command-id matching (`rx_cid`), so the Property Set is never skipped (fixes Identify rejected with `0x8018`); `NVME_SC_AUTH_REQUIRED` status-only trigger for Connect (no ATR bit)
  - Identify NS LBAF offset fix (64→128)
- **Debug log**: full investigation timeline with wire-level evidence in [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md) (Chinese only).
- **Verification**: re-run of the full chain: `sending Property Set (CC)` present, all commands `status=0x0000` on the wire, `0x8018` zero occurrences, GRUB 2.14 SAN boot OK.

### 8. EFI variable NVS backend (`0008`)

- **Rationale**: the device trust-root scheme needs non-volatile storage for the device identity key and the server certificate fingerprint. iPXE's default NVS backends (PCI option ROM, SMBIOS) are absent or read-only in the EFI boot path, so a dedicated backend backed by an EFI NVRAM variable is required.
- **Changes**: `src/interface/efi/efi_nvs.c`, `src/config/config_efi.c`, `src/include/ipxe/dhcp.h` (`DHCP_EB_DEVICE_KEY` 0x5e, `DHCP_EB_SERVER_FINGERPRINT` 0x5f), `src/include/ipxe/errfile.h`
  - New `efi_nvs.c` settings backend: one EFI NVRAM variable (project namespace GUID) holds the whole options block; store/load/delete hooks wired into the EFI settings machinery
  - `device-key` and `server-fingerprint` therefore survive reboot
- **Verification**: QEMU/OVMF two-round test — round 2 (kept NVRAM) shows the key still present without regeneration; `keygen` refuses to overwrite.

### 9. TOFU fingerprint chain (`0009`)

- **Rationale**: the trust-root scheme must tolerate self-signed or otherwise-untrusted HTTPS servers on first contact (registration window), then pin the server thereafter. Upstream iPXE has no trust-on-first-use mechanism.
- **Changes**: `src/net/tofu.c`, `src/include/ipxe/tofu.h`, `src/net/tls.c`, `src/include/ipxe/errfile.h`
  - `tofu_fingerprint_present()` / `tofu_store()`: SHA-256 fingerprint of the TLS leaf certificate, mirrored into the `trust` setting
  - `tls_validator_done()`: on validation failure, if no fingerprint is stored yet, accept the handshake and record the fingerprint (TOFU); once a fingerprint exists, any later failure is fatal
- **Verification**: patch applies bidirectionally on the 0008-based tree.

### 10. Device identity key commands (`0010`)

- **Rationale**: the trust-root scheme requires device-side ECDSA P-256 key generation, public-key export and signing — the private key must never leave the device.
- **Changes**: `src/hci/commands/devicekey_cmd.c`, `src/config/general.h` (`DEVICEKEY_CMD`), `src/config/config.c` (`REQUIRE_OBJECT ( devicekey_cmd )`), `src/include/ipxe/dhcp.h` (`DHCP_EB_PUBKEY` 0x60, `DHCP_EB_SIG` 0x61), `src/include/ipxe/errfile.h`
  - `keygen`: DRBG (seeded from the EFI RNG entropy source) generates a 32-byte P-256 private key, stored into `device-key`; refuses to overwrite an existing key
  - `pubkey`: derives the uncompressed point (`0x04‖X‖Y`, 130 hex) via P-256 curve multiplication
  - `sign`: SHA-256 digest of the data (arguments concatenated) → ECDSA P-256 → base64(DER) signature, also stored in the `sig` setting for scripts
- **Verification**: QEMU/OVMF two rounds — round 1 (clean NVRAM): keygen/pubkey/sign all succeed; host-side independent verification (OpenSSL/python) of the printed public key and signature passes (PREHASHED and REHASH); round 2 (kept NVRAM): keygen refuses to overwrite, pubkey/sign output identical to round 1 (persistence proven).
- **Licence**: original kurrent-firmware implementation, `FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )`.

### 11. NVMe/TCP host NQN setting (`0011`)

- **Rationale**: strict-mode DH-HMAC-CHAP authentication requires the host NQN to match the nvmet `hosts/` registration; the UUID-derived default cannot be predicted by the boot server for an arbitrary client.
- **Changes**: `src/net/tcp/nvmetcp.c` — a registered `hostnqn` setting overrides the UUID-derived default in `nvmetcp_set_host_nqn()`; plain `nvme://` URIs without the setting keep the old fallback (`nqn.2014-08.org.ipxe:<uuid>`).
- **Verification**: host NQN injected per MAC via the credential endpoint; nvmet `hosts/` strict-mode acceptance (`test/nvmet-setup.sh` with `AUTH=1`).

### 12. NVMe boot credentials table (`0012`)

- **Rationale**: with authenticated boot the kernel-side reconnect must not fetch credentials over the network a second time — the firmware already holds the per-session DH-HMAC-CHAP secret and host NQN.
- **Changes**: `src/drivers/block/nbct.c` (new), `src/include/ipxe/nbct.h` (new), `src/include/ipxe/errfile.h`, `src/include/ipxe/nvmetcp.h`, `src/net/tcp/nvmetcp.c`
  - iBFT-style `acpi_model` registration (`nbct_model`); each authenticated NVMe/TCP session exposes an `acpi_describe` interface op
  - at sanboot description time (`efi_block_describe` → `acpi_install`) a custom ACPI table signed `NBCT` is installed: 36-byte ACPI header + entry count + N fixed 1024-byte records (traddr / trsvcid / nqn / hostnqn / secret)
  - the table lives in memory only (no NVRAM) and dies with the boot session
- **Consumption**: `initramfs-nbft/nbft-connect --connect` detects `/sys/firmware/acpi/tables/NBCT*` and connects each record with `--dhchap-secret` / `--hostnqn`, falling back to `connect-all --nbft` when the table is absent (see `../initramfs-nbft/README.md`)
- **Verification**: `nbft-connect --selftest` (synthetic-table parsing) + `test/test-nbft-connect-nbct.sh` (mock-nvme scenarios); full QEMU `AUTH=1` six-stage boot in the repository verification records.
- **Licence**: original kurrent-firmware implementation, `FILE_LICENCE ( BSD2 )`.

## EMBED Auto-Boot Script

`embed/auto.ipxe` is a configuration asset (not a source patch): changes do not require regenerating patches — modify the file and rebuild. See [patches/README.md](../patches/README.md) for details.

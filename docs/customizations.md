# Customizations

[English](customizations.md) | [中文](customizations.zh-CN.md)

Every customization in this repository, relative to the upstream iPXE baseline (default `e6e51ccb`), consists of **twelve patches** plus a **build-level EMBED customization** (`embed/auto.ipxe`, compiled into the firmware via `EMBED=`, not a patch).

| # | Patch | Scope |
|---|---|---|
| 0001 | `0001-realtek-adaptation.patch` | Realtek NIC adaptation: RTL8125 (2.5G) series + RTL8126 (5G) |
| 0002 | `0002-makefile-ipxe-debug.patch` | Debug build fix |
| 0003 | `0003-snponly-local-boot.patch` | snponly local boot support |
| 0004 | `0004-device-info-collection.patch` | Device info collection: SMBIOS type 17 memory settings (`mem-total` / `mem-type` / `mem-speed`) + PCI device-table name via `${net0/chip}` |
| 0005 | `0005-nvmeof-adaptation.patch` | NVMe-oF (NVMe over TCP) SAN protocol support (incl. authentication/state-machine fixes and the `hostnqn` setting override) |
| 0006 | `0006-efi-nvs-backend.patch` | EFI variable NVS backend (`server-fingerprint` persists across reboot; an emptied options block is persisted too, as a variable deletion) |
| 0007 | `0007-tofu-fingerprint.patch` | TOFU fingerprint chain (first-contact TLS acceptance, fingerprint storage) |
| 0008 | `0008-nvclear-command.patch` | `nvclear`: clears `server-fingerprint` and `trust` from non-volatile storage |
| 0009 | `0009-nvmetcp-nbct-acpi-table.patch` | NVMe boot credentials table (NBCT ACPI handoff of DH-HMAC-CHAP secret + host NQN to the kernel side) |
| 0010 | `0010-tls13-psk.patch` | TLS 1.3 (RFC 8446) PSK client: handshake primitives + `add_tls13_psk()` filter connection + `nvmetcp` wiring, with an RFC 8448 self-test |
| 0011 | `0011-tpm-attestation.patch` | TPM 2.0 attestation key (`akgen` / `akpub` / `quote`) and PCR quote sent as the device proof |
| 0012 | `0012-sbenroll.patch` | Secure Boot key enrollment (`sbenroll`, build-time PK/KEK/db descriptors) |

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

### 1. Realtek NIC adaptation (`0001`)

RTL8125 (2.5G) series:

- **Rationale**: RTL8125 (2.5G) NICs must be handled by the iPXE native driver — the firmware SNP driver hangs in iSCSI mount scenarios and cannot be used for diskless boot; upstream iPXE has incomplete support for some 8125 versions (XID 0x688 series).
- **Changes**: `src/drivers/net/realtek.c`, `realtek.h`
  - XID 0x688 version table and device identification
  - EPHY initialisation table (2.5G PHY configuration)
  - 32-bit interrupt status register
  - FETCH / PAUSE_SLOT configuration
  - BAR 0x4808 (2.5G-specific register window)
  - TPPOLL_8125 polling
- **Licence**: the 8125 adaptation is derived from the Linux kernel r8169 driver (GPL-2.0-only); it is licensed under GPL-2.0 only and may not be redistributed under UBDL (see the header of `patches/0001`).

RTL8126 5GbE:

- **Rationale**: RTL8126 (5G) is a 2024 NIC with no `0x8126` device entry in the upstream iPXE baseline. Its GPHY must be initialised with one of three PHY configuration methods (static register tables) selected by ICVerID, and some PCIe configuration (ZRXDC timeout reporting, ASPM entry latency) requires the CSI mechanism to access extended configuration space — none of which the baseline driver has.
- **Changes**: `src/drivers/net/realtek.c`, `realtek.h`
  - `0x8126` device entry and `realtek_detect_8126` (TxConfig 0x64800000 family detection + ICVerID → mcfg 1/2/3 dispatch)
  - GPHY OCP interface functions (`realtek_gphy_ocp_read/write/modify`, refactored from the 8125 inlined MII access and reused)
  - CSI extended configuration space interface (`realtek_csi_read/write/modify`, same mechanism as Linux `rtl_csi_*`)
  - PHY static configuration tables x3 (`realtek_8126a_1/2/3_phy`, 367 entries in total, from the official r8126 driver; MCU microcode section excluded; direct-write vs read-modify-write semantics distinguished, corresponding to the official `rtl8126_mdio_direct_write_phy_ocp` and `rtl8126_clear_and_set_eth_phy_ocp_bit` respectively) and `realtek_hw_phy_config_8126`
  - `realtek_hw_start_8126`: ZRXDC disabled + default ASPM entry latency (CSI path) + 8125 common initialisation + PHY configuration
  - Mount points: `realtek_detect` / `realtek_open` / `realtek_probe` dispatch on `mac_ver == 70`
- **Verification**: full build passes all 10 artifacts (including the `DEBUG=realtek:3` debug target); field testing on physical hardware pending.
- **Audit**: the dual-source PHY table audit and the lightweight PHY MCU firmware version-check policy are documented in [8126-porting-audit.md](8126-porting-audit.md) (Chinese only).
- **Licence**: the 8126 adaptation is derived from the Realtek r8126 driver (GPL-2.0-only, Copyright 2025 Realtek Semiconductor Corp.) and the Linux kernel r8169 driver (GPL-2.0-only); it is licensed under GPL-2.0 only and may not be redistributed under UBDL (see the header of `patches/0001`).

### 2. Debug build fix (`0002`)

- **Rationale**: the `ipxe-debug.efi` target had no driver set defined, so the artifact was an empty shell (no NIC drivers at all) and useless for fault diagnosis.
- **Changes**: `src/Makefile` — added `DRIVERS_ipxe-debug += $(DRIVERS_ipxe)` so the debug target inherits the full driver set.

### 3. snponly local boot support (`0003`)

- **Rationale**: the official `snponly.efi` only supports firmware-PXE chainload scenarios (it takes over only the device that loaded iPXE); booting from local UEFI (USB / disk) finds no NIC and drops straight to the shell. This is the companion adaptation for the "mainboard has no PXE boot option" scenario — local-media boot also needs network takeover capability.
- **Changes**: `src/drivers/net/efi/snponly.c` — when chainload location fails, fall back to taking over all SNP/NII/MNP devices **except SNP handles installed by iPXE itself**; PXE chainload behaviour is unchanged.
- **Effect**: machines where native drivers are unavailable (e.g. RTL8168 initialisation hangs on certain mainboards) still have an SNP fallback path for local boot. The self-installed-handle exclusion is essential: without it the fallback binds to the SNP handle that `efi_snp_probe()` has just installed for our own net device, recursively producing `net0..netN` until the 4 MB heap is exhausted — after which every HTTPS/TLS allocation (8 KB menu records, TLS 1.3 sanboot) fails with `ENOMEM`.

### 4. Device information collection (`0004`)

- **Rationale**: firmware-side device info collection (identity / CPU / memory / NIC) for HTTP reporting. Identity (SMBIOS types 1-3) and CPU (CPUID) settings are already provided upstream, leaving two gaps: no named settings for SMBIOS type 17 (memory devices, one structure per slot), and PCI NICs never populate `driver_name`, so `${net0/chip}` was unusable on PCI.
- **Changes**: `src/include/ipxe/smbios.h`, `src/interface/smbios/smbios_settings.c`, `src/drivers/bus/pci.c`
  - `struct smbios_memory_device` (type 17 layout verified against three dmidecode versions: Memory Type `0x12`, Speed `0x15`, Extended Size `0x1C`) + `SMBIOS_TYPE_MEMORY_DEVICE 17`
  - `${mem-total}` (uint32 MB, aggregated over all modules: `0xFFFF` skipped, `0x7FFF` falls back to Extended Size, bit 15 = GB), `${mem-type}` (first module, mapped to strings such as `DDR5`), `${mem-speed}` (first module, MT/s) — custom fetches dispatched by name, reusing the existing SMBIOS settings scope
  - `pci_probe` now sets `driver_name` from the matching device-table entry, enabling `${net0/chip}` (e.g. `RTL8125`) for all PCI NICs
- **Usage**: settings reference and report URL templates in [device-info-reporting.md](device-info-reporting.md) / [device-info-reporting.zh-CN.md](device-info-reporting.zh-CN.md).
- **Verification**: full build passes all 10 artifacts; settings embedded (strings check); behaviour on real hardware pending (URL encoding of spaces / special characters).

### 5. NVMe-oF (NVMe over TCP) SAN support (`0005`)

- **Rationale**: upstream iPXE has no NVMe-oF transport support; SAN boot from NVMe/TCP targets (e.g. Linux `nvmet`) requires a full protocol driver plus a `SANBOOT_PROTO_NVME_TCP` config option. Three bugs found while validating the auth path end-to-end against nvmet were fixed in place: transient `-EAGAIN` killed the session instead of waiting for the TCP window, AuthReceive could be sent twice, and the auth-complete race (phase switched before the final AuthReceive completion, so the Property Set was skipped and Identify was rejected). Strict-mode DH-HMAC-CHAP authentication additionally requires the host NQN to match the nvmet `hosts/` registration, which the UUID-derived default cannot guarantee for an arbitrary client.
- **Changes**: `src/config/config.c`, `src/config/general.h` (`SANBOOT_PROTO_NVME_TCP`), `src/include/ipxe/errfile.h`, `src/include/ipxe/nvmetcp.h`, `src/net/tcp/nvmetcp.c`, `src/net/tcp/nvmetcp_auth.c`, `src/tests/nvmetcp_test.c`, `src/tests/tests.c`
  - 8-phase state machine: ICReq/ICResp parameter negotiation → Connect (Admin) → Property Set (CC.EN=1) → Identify (controller/namespace) → Connect (I/O) → block read/write with R2T flow control
  - DH-HMAC-CHAP authentication (AuthSend/AuthReceive, DH groups 0/2048/3072/4096)
  - EFI device-path description and BlockIo hooking for `sanboot`; unit tests (structure layout + Identify NS parsing)
  - Transient `-EAGAIN` handling (defer the process, resume on window) and idempotent AuthReceive send with unified step advancement
  - Auth phase completion gated by `completed`/`rx_complete` flags plus command-id matching (`rx_cid`), so the Property Set is never skipped (fixes Identify rejected with `0x8018`); `NVME_SC_AUTH_REQUIRED` status-only trigger for Connect (no ATR bit)
  - Identify NS LBAF offset fix (64→128)
  - A registered `hostnqn` setting overrides the UUID-derived default in `nvmetcp_set_host_nqn()`; plain `nvme://` URIs without the setting keep the old fallback (`nqn.2014-08.org.ipxe:<uuid>`)
- **Usage**: end-to-end guide (nvmet target setup incl. auth, `sanboot` syntax, QEMU validation) in [nvmeof-usage.md](nvmeof-usage.md) (Chinese only).
- **Debug log**: full authentication investigation timeline with wire-level evidence in [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md) (Chinese only).
- **Verification**: QEMU/OVMF + Ubuntu 26.04 kernel 7.0 nvmet target, GRUB 2.14 SAN boot chain passing; full-chain re-runs show `sending Property Set (CC)` present, all commands `status=0x0000` on the wire, `0x8018` zero occurrences. Host NQN injection per MAC accepted by nvmet `hosts/` strict mode (`test/nvmet-setup.sh` with `AUTH=1`).
- **Licence**: original kurrent-firmware implementation, `FILE_LICENCE ( GPL2_ONLY )` — GPL-2.0 only, not redistributable under UBDL.

### 6. EFI variable NVS backend (`0006`)

- **Rationale**: the trust-root scheme needs non-volatile storage for the TOFU server fingerprint. iPXE's default NVS backends (PCI option ROM, SMBIOS) are absent or read-only in the EFI boot path, so a dedicated backend backed by an EFI NVRAM variable is required.
- **Changes**: `src/interface/efi/efi_nvs.c`, `src/core/nvo.c`, `src/config/config_efi.c`, `src/include/ipxe/dhcp.h` (`DHCP_EB_SERVER_FINGERPRINT` 0x5f), `src/include/ipxe/errfile.h`
  - New `efi_nvs.c` settings backend: one EFI NVRAM variable (project namespace GUID) holds the whole options block; store/load/delete hooks wired into the EFI settings machinery
  - `server-fingerprint` (and the mirrored `trust` anchor) therefore survive reboot
  - `src/core/nvo.c`: `nvo_save()` issues a zero-length write when the options block becomes empty. `nvs_write()` is a `while (len)` loop and performs no device write at all for a zero length, so saving an empty block used to be a silent no-op — the EFI variable kept its previous contents and the "deleted" settings reappeared on the next boot. The EFI backend implements a zero-length write as a variable deletion.
- **Verification**: QEMU/OVMF rounds — a TOFU pin stored on the first boot is still present on the next boot with the variable store kept. Emptying the whole options block is verified across three rounds by `test/run-qemu-nvclear.sh` (the last boot finds the cleared settings absent); without the `nvo.c` change that round re-enters the clear branch, the last deleted setting (`trust`) having been resurrected from the stale variable. The acceptance was carried out while the software device key still existed; the scripts now cover the two remaining settings.

### 7. TOFU fingerprint chain (`0007`)

- **Rationale**: the trust-root scheme must tolerate self-signed or otherwise-untrusted HTTPS servers on first contact (registration window), then pin the server thereafter. Upstream iPXE has no trust-on-first-use mechanism.
- **Changes**: `src/net/tofu.c`, `src/include/ipxe/tofu.h`, `src/net/tls.c`, `src/include/ipxe/errfile.h`
  - `tofu_fingerprint_present()` / `tofu_store()`: SHA-256 fingerprint of the TLS leaf certificate, mirrored into the `trust` setting
  - `tls_validator_done()`: on validation failure, if no fingerprint is stored yet, accept the handshake and record the fingerprint (TOFU); once a fingerprint exists, any later failure is fatal
- **Verification**: patch applies bidirectionally on the 0006-based tree.

### 8. Non-volatile settings command (`0008`)

- **Rationale**: returning a device to its factory state means clearing the TOFU server fingerprint as well as the `trust` anchor; addressing a bare setting name only removes the in-memory copy and leaves the stored one in place.
- **Changes**: `src/hci/commands/nvclear_cmd.c`, `src/config/general.h` (`NVCLEAR_CMD`), `src/config/config.c` (`REQUIRE_OBJECT ( nvclear_cmd )`), `src/include/ipxe/errfile.h`
  - `nvclear`: deletes `server-fingerprint` and `trust` from the non-volatile options block in one command, reporting per item (`cleared` / `not present` / error). Settings are addressed as `nvo/<name>` inside the block.
- **Verification**: `test/run-qemu-nvclear.sh` (three rounds; the last boot finds every cleared setting gone). Mutation check: without the `nvo.c` zero-length write the last round re-enters the clear branch because `trust` is resurrected from the stale variable (`diag/nvs-{dbg3,fix3}.serial`).
- **Licence**: original kurrent-firmware implementation, `FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )`.

### 9. NVMe boot credentials table (`0009`)

- **Rationale**: with authenticated boot the kernel-side reconnect must not fetch credentials over the network a second time — the firmware already holds the per-session DH-HMAC-CHAP secret and host NQN.
- **Changes**: `src/drivers/block/nbct.c` (new), `src/include/ipxe/nbct.h` (new), `src/include/ipxe/errfile.h`, `src/include/ipxe/nvmetcp.h`, `src/net/tcp/nvmetcp.c`
  - iBFT-style `acpi_model` registration (`nbct_model`); each authenticated NVMe/TCP session exposes an `acpi_describe` interface op
  - at sanboot description time (`efi_block_describe` → `acpi_install`) a custom ACPI table signed `NBCT` is installed: 36-byte ACPI header + entry count + N fixed 1152-byte records (traddr / trsvcid / nqn / hostnqn / secret / tls_trsvcid / tls_psk)
  - the table lives in memory only (no NVRAM) and dies with the boot session
- **Consumption**: `initramfs-nbft/nbft-connect --connect` detects `/sys/firmware/acpi/tables/NBCT*` and connects each record with `--dhchap-secret` / `--hostnqn`; when a record carries `tls_trsvcid` it instead injects `tls_psk` into the kernel global `.nvme` keyring and reconnects with `--tls` on the TLS port (kernel-segment transport encryption), falling back to `connect-all --nbft` when the table is absent (see `../initramfs-nbft/README.md`)
- **Verification**: `nbft-connect --selftest` (synthetic-table parsing) + `test/test-nbft-connect-nbct.sh` (mock-nvme scenarios); full QEMU `AUTH=1` six-stage boot in the repository verification records.
- **Licence**: original kurrent-firmware implementation, `FILE_LICENCE ( BSD2 )`.

### 10. TLS 1.3 pre-shared-key client (`0010`)

- **Rationale**: the firmware boot segment (`sanboot` reading ESP/kernel/initrd) was the last plaintext hop on the encryption chain — iPXE's TLS stack only reaches 1.2, so the kernel segment (after GRUB) could be encrypted by the kernel while the firmware segment could not. This patch gives the firmware a TLS 1.3 PSK client (both the client-side handshake primitives and the filter connection that drives them), so that with the control plane defaulting the `sanboot` port to the data-plane TLS port both segments are encrypted end to end.
- **Changes**: `src/net/tls.c`, `src/include/ipxe/tls.h`, `src/net/tls13.c` (new), `src/include/ipxe/tls13.h` (new), `src/net/tcp/nvmetcp.c`, `src/include/ipxe/errfile.h`, `src/tests/tls13_test.c` (new), `src/tests/tls13_conn_test.c` (new), `src/tests/tests.c`
  - key schedule: `tls13_expand_label` / `tls13_derive_secret` / `tls13_early_secret` / `tls13_handshake_secret` / `tls13_master_secret` / `tls13_traffic_key`, built on the existing `hkdf.c`
  - `tls13_client_hello`: a TLS 1.3 ClientHello offering a single cipher suite (`TLS_AES_128_GCM_SHA256`) and the `psk_dhe_ke` mode, with `pre_shared_key` last and the binder computed across the truncated ClientHello
  - `tls13_binder` and `tls13_finished`: the Finished/binder `HMAC( finished_key, Transcript-Hash( ... ) )` construction, shared by both
  - `tls13_parse_server_hello`: ServerHello parsing (negotiated version, cipher suite, accepted PSK identity, X25519 key share)
  - record protection: `tls13_nonce` (write IV XOR sequence number), `tls13_seal` and `tls13_open` (AES-128-GCM AEAD with the inner content type appended to the plaintext and the record header as additional data)
  - `tls13_generate_key` / `tls13_shared_secret`: X25519 ephemeral key generation and shared-secret agreement via the existing `x25519_algorithm`
  - `struct tls13_handshake` and its accessors: the handshake transcript context (bounds-checked transcript accumulation, `tls13_handshake_exchange` for the Early → Handshake transition, `tls13_handshake_derive` / `_finished` / `_master`)
  - `add_tls13_psk()` (`tls13.c`): the connection itself — a filter interface between a byte-stream consumer and the socket, with a ClientHello → Server flight → client Finished → data phase machine, RX record reassembly, and a plaintext window that stays closed until the handshake completes. The plaintext window is re-notified on every `tls13_psk_tx()` call, including when no record is pending: iPXE's TCP layer reports a zero window while a segment is unacknowledged, so a notification suppressed at that moment would never be reissued and the consumer would stall
  - `tls13_psk_open_socket` (`tls13.h`): the socket-opening function used by `add_tls13_psk()`, defaulting to `xfer_open_named_socket()`; it exists so the connection self-test can substitute a mock socket
  - TLS 1.3 version / extension / cipher constants (`TLS_VERSION_TLS_1_3`, extensions 5/8/41/43/45/51, `TLS_AES_128_GCM_SHA256`)
  - `nvmetcp`: `nvmetcp_open_socket()` routes the session through `add_tls13_psk()` when `nvmetcp_use_tls()` says so — the boot URI carries `tls_psk=` (hex-decoded) *and* the connection port equals `tls_trsvcid` — deriving the `NVMe0R01 <hostnqn> <subsysnqn>` PSK identity; the plaintext path is unchanged when it does not, so a URI that delivers the handoff parameters while still pointing at the plaintext port leaves the firmware connection plaintext
- **Verification**: `tls13_test` self-test (RFC 8448 sections 3 and 4 vectors — key schedule, PSK binder, ServerHello parsing, X25519 key exchange, the handshake transcript context, Finished verify_data and record sealing/opening — plus a ClientHello extension-block walk and mutation-tested negative cases); 110 assertions via `bin-x86_64-efi/tests.efi` under QEMU/OVMF (the Linux `tests.linux` binary cannot be built because of the EFI coupling introduced by `0006`). `tls13_conn_test` drives the connection layer in-process against a mock socket and a mock consumer, with the test itself playing the server side of the handshake: ClientHello → ServerHello → server Finished → client Finished → data, plus the plaintext-window contract in both the handshake and the established state (27 assertions; mutation-verified by reverting the window notification into the transmit branch and by deleting the `SERVER_FINISHED → CLIENT_FINISHED` phase transition, which turn 2 and 6 assertions red respectively). Wire-level acceptance: an EFI image embedding `sanboot nvme://…:4421/<nqn>?tls_psk=…` completes the handshake against a real `nvmet` TLS target (host log `Created nvm controller … , TLS.`), registers the SAN device and reads it, with every `:4421` client connection starting on `0x16` (ClientHello) and zero plaintext ICReq.
- **Licence**: modifies upstream files carrying `FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )`; the new files and the new self-tests follow the same dual licence.

### 11. TPM 2.0 attestation (`0011`)

- **Rationale**: the control plane identifies a device by a TPM quote, not by a signature from a software key held in NVRAM. A private key in firmware-accessible storage can be extracted; an attestation key created inside the TPM with the `restricted` + `sign` attributes cannot leave it.
- **Changes**: `src/interface/efi/efi_tpm2.c` (new), `src/include/ipxe/efi/efi_tpm2.h` (new), `src/hci/commands/ak_cmd.c` (new), `src/config/general.h` (`AK_CMD`, EFI only), `src/config/config.c`, `src/include/ipxe/dhcp.h` (tags 0x60-0x65), `src/include/ipxe/errfile.h`
  - raw TPM 2.0 commands are submitted through `EFI_TCG2_PROTOCOL.SubmitCommand()`, the standard EFI route to the TPM. The protocol exposes no Quote operation, so `TPM2_Quote` is issued directly
  - attestation key: `TPM2_CreatePrimary` under the owner hierarchy with attributes `fixedTPM | fixedParent | sensitiveDataOrigin | userWithAuth | restricted | sign`, ECC P-256 preferred and RSA-2048 as the fallback; `TPM2_EvictControl` makes it persistent at `0x81000001`
  - reuse: `akgen` first probes the persistent handle (`TPM2_ReadPublic`) and only creates a key when none exists — no code path overwrites an existing AK. Rotation is an administrative action (delete the registration and re-pool the device), not a firmware operation
  - `akgen`: creates or reports the existing key; `akpub`: exports `ak-public` (SubjectPublicKeyInfo DER), `ak-name` (TPM2B_NAME: `000b` followed by the SHA-256 of the public area), `ak-type` (`ecc_p256` / `rsa2048`) and `sb` (EFI `SecureBoot` variable, `1` / `0`); `quote <nonce>`: one `TPM2_Quote` over PCR 0/2/4/7 with the nonce as `qualifyingData`, exporting `quote` (raw TPMS_ATTEST, no TPM2B length prefix) and `quote-sig` (ECDSA-SHA256 DER, or RSASSA-PKCS1-v1_5 for an RSA AK)
  - all six settings (DHCP tags 0x60-0x65) live in the in-memory settings root for the current boot only; nothing reaches the EFI variable NVS backend
  - without a TPM the commands fail with `-ENODEV` / `-ENOENT` and nothing else, so a boot script can take its no-TPM path; there is no software fallback
- **Verification**: QEMU/OVMF + swtpm (software TPM, not real hardware). The AK survives a cold reboot and a regenerated OVMF variable store with an identical `ak-name`; `test/verify-ak-quote.py` independently parses the TPMS_ATTEST and verifies the signature; the control plane's real `/devices/report` → `/devices/challenge` → `/boot-vars` flow records `device.attest ok`. Negative cases: a firmware change (different PCR 7) yields `pcr_mismatch`, replaying a nonce yields `nonce_invalid`, and a firmware without a TPM reports `no_tpm` without crashing. See [device-trust-usage.md](device-trust-usage.md) for the command and setting contract.
- **Licence**: original kurrent-firmware implementation, `FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )`; `EFI_TCG2_PROTOCOL` constants are the standard UEFI specification values.

### 12. Secure Boot key enrollment (`0012`)

- **Rationale**: provisioning PK/KEK/db per machine through USB or firmware Setup does not scale. A signed image that boots in Setup Mode (or with Secure Boot off) can install the platform key hierarchy itself and reboot into verified boot.
- **Changes**: `src/hci/commands/sbenroll_cmd.c` (new), `src/include/ipxe/sbenroll_data.h` (new, stub overwritten by the SB build), `src/config/general.h` (`SBENROLL_CMD`, EFI only), `src/config/config.c`, `src/include/ipxe/dhcp.h` (tag 0x66), `src/include/ipxe/errfile.h`
  - `sbenroll` writes PK, then KEK (authenticated by PK), then db (authenticated by KEK) through `EFI_RUNTIME_SERVICES.SetVariable()` with `EFI_VARIABLE_AUTHENTICATION_2` payloads generated at build time by `build/sbenroll-gen.py`
  - db carries the artifact signing certificate and the Microsoft UEFI CA 2011 certificate; only certificates and signatures are embedded, private keys stay offline
  - idempotent: variables already holding our descriptors are not rewritten; a different PK leaves everything untouched and reports `foreign`; failures report `failed`. The result is published as `sbenroll-result` (DHCP tag 0x66) for the phase script
  - `embed/secureboot/sb-boot.ipxe.cfg` chains `${https-url}boot/phase` before the identity flow; the control plane serves the enrollment script while a registration window is open and an empty script otherwise
- **Verification**: QEMU/OVMF (fresh variable store, Setup Mode) + swtpm: the signed image enrolls PK/KEK/db, reports `ok`, reboots, is accepted by Secure Boot and reports `sb=1`; a second run reports `ok (already enrolled)` without touching the variables; a pre-installed vendor PK yields `foreign` with PK/KEK/db unchanged (see `docs/secureboot.md`).
- **Licence**: original kurrent-firmware implementation, `FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )`; the bundled Microsoft UEFI CA 2011 certificate is public trust-anchor data.

> Patch set consolidated on 2026-09-12: the RTL8126 adaptation (previously a separate patch amending the 8125 patch) merged into `0001`; the NVMe/TCP authentication fixes and the `hostnqn` setting (previously separate follow-up patches) merged into `0005`. The 12-patch sequence became 9 patches; replaying the new sequence against the clean baseline reproduces the old sequence's final tree bit-for-bit.

## EMBED Auto-Boot Script

`embed/auto.ipxe` is a configuration asset (not a source patch): changes do not require regenerating patches — modify the file and rebuild. See [patches/README.md](../patches/README.md) for details.

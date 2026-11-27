# Patch Set

[English](README.md) | [中文](README.zh-CN.md)

All patches are generated against the **same upstream baseline**; apply order = filename order.

## Baseline

- Upstream repository: `https://github.com/ipxe/ipxe.git` (mirror available: `https://gitee.com/mirrors/ipxe.git`)
- Baseline commit: `e6e51ccbf17ff40a899c8859fb4e95abd5cfcd57` (master)
- To regenerate patches, in the build cache worktree (`.cache/ipxe-upstream`, which already contains the patches and modifications):

  ```bash
  git -C .cache/ipxe-upstream diff > patches/NNNN-xxx.patch
  ```

## Patch List

| Patch | Files | Content |
|---|---|---|
| `0001-realtek-adaptation.patch` | `src/drivers/net/realtek.c`, `realtek.h` | Realtek 2.5/5GbE adaptation: RTL8125 series (XID 0x688 version table, EPHY initialisation table, 32-bit interrupt register, FETCH/PAUSE_SLOT, BAR 0x4808, TPPOLL_8125) plus RTL8126 5GbE (ICVerID detection and PHY configuration dispatch, shared GPHY OCP/CSI helpers, 3 PHY static configuration tables, ZRXDC/ASPM configuration) |
| `0002-makefile-ipxe-debug.patch` | `src/Makefile` | Added `DRIVERS_ipxe-debug` definition (debug target inherits the full driver set, fixes `obj_ipxe_debug` link failure) |
| `0003-snponly-local-boot.patch` | `src/drivers/net/efi/snponly.c` | snponly local boot support: when chainload location fails (local UEFI boot), fall back to taking over all SNP/NII/MNP devices, excluding SNP handles installed by iPXE itself (prevents recursive net0..netN creation); PXE chainload behaviour unchanged |
| `0004-device-info-collection.patch` | `src/include/ipxe/smbios.h`, `src/interface/smbios/smbios_settings.c`, `src/drivers/bus/pci.c` | Device information collection: SMBIOS type 17 memory settings (`mem-total` aggregated over all modules, `mem-type` / `mem-speed` from first module, custom fetches) + PCI `driver_name` population so `${net0/chip}` reports the device-table name (e.g. `RTL8125`) |
| `0005-nvmeof-adaptation.patch` | `src/config/config.c`, `src/config/general.h`, `src/include/ipxe/errfile.h`, `src/include/ipxe/nvmetcp.h`, `src/net/tcp/nvmetcp.c`, `src/net/tcp/nvmetcp_auth.c`, `src/tests/nvmetcp_test.c`, `src/tests/tests.c` | NVMe-oF (NVMe over TCP) SAN protocol support: new nvmetcp driver (ICReq/ICResp parameter negotiation, Property Set (CC register), Connect/Identify, block read/write, R2T flow control, DH-HMAC-CHAP authentication, EFI device-path description and BlockIo hooking) + `SANBOOT_PROTO_NVME_TCP` config and unit tests. Includes the authentication and state-machine fixes (transient `-EAGAIN` handling, idempotent AuthReceive with unified step advancement, completion gating via `completed`/`rx_complete` plus `rx_cid` command-id matching, Identify Namespace LBAF offset fix) and the `hostnqn` setting override. See `../docs/zh/archive/nvmeof-auth-debug-log.md` |
| `0006-efi-nvs-backend.patch` | `src/config/config_efi.c`, `src/core/nvo.c`, `src/interface/efi/efi_nvs.c`, `src/include/ipxe/dhcp.h`, `src/include/ipxe/errfile.h` | EFI variable NVS backend: a new `efi_nvs.c` settings backend persisted in an EFI NVRAM variable (project namespace GUID) — the `server-fingerprint` (0x5f) setting survives reboot; `nvo_save()` now propagates an emptied options block (a zero-length write means variable deletion), without which deleting the last option never reached storage |
| `0007-tofu-fingerprint.patch` | `src/include/ipxe/tofu.h`, `src/net/tofu.c`, `src/net/tls.c`, `src/include/ipxe/errfile.h` | TOFU fingerprint chain: on the first TLS handshake an otherwise-untrusted leaf certificate is accepted and its SHA-256 fingerprint stored (mirrored into the `trust` setting); once a fingerprint exists, any later certificate validation failure is fatal |
| `0008-nvclear-command.patch` | `src/hci/commands/nvclear_cmd.c`, `src/config/general.h`, `src/config/config.c`, `src/include/ipxe/errfile.h` | `nvclear`: clears `server-fingerprint` and `trust` from the non-volatile options block in one command, reporting per item (`cleared` / `not present` / error). Settings are addressed inside the `nvo` block — deleting a bare name would only drop the in-memory copy; `NVCLEAR_CMD` config option |
| `0009-nvmetcp-nbct-acpi-table.patch` | `src/drivers/block/nbct.c` (new), `src/include/ipxe/nbct.h` (new), `src/include/ipxe/errfile.h`, `src/include/ipxe/nvmetcp.h`, `src/net/tcp/nvmetcp.c` | NVMe boot credentials table (NBCT): a custom ACPI table installed at sanboot time (iBFT-style `acpi_model` registration) carrying one fixed-size record per authenticated NVMe/TCP session (transport address, subsystem NQN, host NQN, DH-HMAC-CHAP secret, plus the kernel-segment TLS handoff parameters `tls_trsvcid`/`tls_psk`); consumed by the initramfs `nbft-connect` (see `../initramfs-nbft/`) to reconnect with `--dhchap-secret`/`--hostnqn` or, when `tls_trsvcid` is set, with `--tls` after injecting the PSK into the `.nvme` keyring, without a second network fetch of credentials |
| `0010-tls13-psk.patch` | `src/net/tls.c`, `src/include/ipxe/tls.h`, `src/net/tls13.c` (new), `src/include/ipxe/tls13.h` (new), `src/net/tcp/nvmetcp.c`, `src/include/ipxe/errfile.h`, `src/tests/tls13_test.c` (new), `src/tests/tls13_conn_test.c` (new), `src/tests/tests.c` | TLS 1.3 (RFC 8446) pre-shared-key client for the firmware boot segment, in two layers. Primitives: the RFC 8446 section 7.1 key schedule (`tls13_expand_label`, `tls13_derive_secret`, `tls13_early_secret`, `tls13_handshake_secret`, `tls13_master_secret`, `tls13_traffic_key`), Finished/binder construction (`tls13_finished`, `tls13_binder`), a ClientHello constructor (`tls13_client_hello`: psk_dhe_ke, single cipher suite, pre_shared_key last, binder across the truncated ClientHello), ServerHello parsing (`tls13_parse_server_hello`), X25519 key exchange (`tls13_generate_key`, `tls13_shared_secret`), the transcript context (`struct tls13_handshake`), RFC 8446 section 5.3 record protection (`tls13_nonce`, `tls13_seal`, `tls13_open`) and the TLS 1.3 version/extension/cipher constants. Connection: `add_tls13_psk()` (`tls13.c`) is a filter interface inserted between a byte stream consumer and the socket, which drives the handshake and protects every subsequent record; `nvmetcp` routes a session through it whenever `nvmetcp_use_tls()` says so, i.e. the boot URI carries `tls_psk=` *and* the connection port equals `tls_trsvcid` (the handoff parameter is delivered on every TLS-capable boot, so the port, not the parameter's presence, decides whether the firmware connection itself is encrypted), deriving the `NVMe0R01 <hostnqn> <subsysnqn>` PSK identity. RFC 8448 self-test (`tls13_test`, sections 3 and 4, plus a ClientHello extension-block walk); connection self-test (`tls13_conn_test`) covers the connection layer with a mock socket and consumer, the test itself playing the server side |

| `0011-tpm-attestation.patch` | `src/interface/efi/efi_tpm2.c` (new), `src/include/ipxe/efi/efi_tpm2.h` (new), `src/hci/commands/ak_cmd.c` (new), `src/config/general.h`, `src/config/config.c`, `src/include/ipxe/dhcp.h`, `src/include/ipxe/errfile.h` | TPM 2.0 device attestation. `efi_tpm2.c` submits raw TPM 2.0 commands through `EFI_TCG2_PROTOCOL.SubmitCommand()` to create a restricted signing attestation key (`TPM2_CreatePrimary`, ECC P-256 with an RSA-2048 fallback), persist it (`TPM2_EvictControl`, handle `0x81000001`) and reuse it on every later boot — no code path overwrites an existing AK. `akgen` / `akpub` / `quote <nonce>` export the SubjectPublicKeyInfo DER, the TPM2B_NAME and a TPMS_ATTEST quote over PCR 0/2/4/7 (digest and signature from a single `TPM2_Quote` call; ECDSA DER or RSASSA-PKCS1-v1_5), plus the Secure Boot state read from the EFI `SecureBoot` variable. Settings `ak-public` / `quote` / `quote-sig` / `ak-name` / `ak-type` / `sb` mirror DHCP tags 0x60-0x65 and live in memory for the current boot only. Without a TPM the commands fail with `-ENODEV` / `-ENOENT`; there is no software fallback. `AK_CMD` config option |

| `0012-sbenroll.patch` | `src/hci/commands/sbenroll_cmd.c` (new), `src/include/ipxe/sbenroll_data.h` (new), `src/config/general.h`, `src/config/config.c`, `src/include/ipxe/dhcp.h`, `src/include/ipxe/errfile.h` | `sbenroll`: installs the Secure Boot platform key hierarchy through `EFI_RUNTIME_SERVICES.SetVariable()` — PK first, then KEK (authenticated by PK), then db (authenticated by KEK). The three `EFI_VARIABLE_AUTHENTICATION_2` payloads are generated at build time by `build/sbenroll-gen.py` from offline PK/KEK keys and compiled in through `src/include/ipxe/sbenroll_data.h`; only certificates and signatures are embedded. Idempotent (writes only what is missing), reports `ok` / `foreign` (different PK present, nothing written) / `failed` in the `sbenroll-result` setting (DHCP tag 0x66). Plain builds keep the stub header and report `failed` without touching variables. `SBENROLL_CMD` config option (EFI only) |

The table above is the **L1 patch series**, applied by `build/build.sh` and by
`build/build-sb.sh`. Secure Boot builds add a second overlay that the normal
glob never sees:

| Patch | Files | Description |
|---|---|---|
| `secureboot/0001-no-tofu.patch` | `src/net/tofu.c` | TOFU must be off when a boot CA is pinned. `tofu_fingerprint_present()` always reports "present", so an untrusted chain becomes fatal instead of being accepted and stored. Applied only by `build/build-sb.sh`; every L1 build keeps the 0007 behaviour byte-for-byte |

> RTL8168 research was terminated in 2026-08; the patches contain no 8168 filtering or fix code (see `../docs/zh/archive/8168-research-log.md`).
>
> The patch set was consolidated on 2026-09-12 (previous 12 patches repacked into patches 0001-0009; patches that only amended an earlier patch have been merged into it), verified by replaying the new sequence against the clean baseline: the final tree hash is bit-identical to the old sequence (`2151e97b3d0b9029b03ae0f7a3dbfbe88930f206`). Patch 0010 (TLS 1.3 PSK) was added later on 2026-10-06; patch 0003 gained the local-boot SNP-handle exclusion on 2026-10-17. Patch 0008 was reduced to `nvclear` and patch 0011 (TPM 2.0 attestation) added on 2026-11-12, replacing the software device key with a TPM-held attestation key. Patch 0012 (Secure Boot key enrollment) was added on 2026-11-23. The current 12-patch sequence (clean baseline + `0001`-`0012`) replays to tree hash `738f43542930ac4bb390b13b8db00ee791ef2a4f`; the Secure Boot overlay lives in `secureboot/` and is applied only by `build/build-sb.sh`, so this tree hash still describes every L1 build.

## Licensing

- The upstream files modified by the patches (`realtek.c`, `snponly.c`, `Makefile`, `smbios.h`, `smbios_settings.c`, `pci.c`) inherit the iPXE GPL-2.0-or-later / UBDL licence;
- the RTL8125 adaptation parts in `0001` (XID version table, EPHY initialisation, power management, etc.) are derived from the Linux kernel r8169 driver (`drivers/net/ethernet/realtek/r8169_main.c`, GPL-2.0-only); those parts are **GPL-2.0 only** and may not be redistributed under UBDL or any later licence;
- the RTL8126 adaptation parts in `0001` (PHY static configuration tables, GPHY OCP/CSI interfaces, ZRXDC/ASPM configuration, etc.) are derived from the Realtek r8126 driver (`r8126_n.c`, GPL-2.0-only, Copyright 2025 Realtek Semiconductor Corp.) and the Linux kernel r8169 driver (`drivers/net/ethernet/realtek/r8169_main.c`, GPL-2.0-only); those parts are **GPL-2.0 only** and may not be redistributed under UBDL or any later licence;
- the new NVMe/TCP driver files in `0005` (`nvmetcp.c`, `nvmetcp_auth.c`, `nvmetcp.h`, `nvmetcp_test.c`) are original kurrent-firmware implementations carrying `FILE_LICENCE ( GPL2_ONLY )`; they are **GPL-2.0 only** and may not be redistributed under UBDL;
- the device-trust files in `0006`/`0007`/`0008` (`efi_nvs.c`, `tofu.c`, `tofu.h`, `nvclear_cmd.c`) are original kurrent-firmware implementations carrying `FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )`, matching upstream iPXE's dual licence;
- the NBCT files in `0009` (`nbct.c`, `nbct.h`) are original kurrent-firmware implementations carrying `FILE_LICENCE ( BSD2 )` (kernel-style licence, matching the ACPI-table precedent in upstream iPXE's `ibft.c`);
- the TLS 1.3 additions in `0010` modify upstream files (`tls.c`, `tls.h`, `errfile.h`, `nvmetcp.c`, `tests.c`) carrying `FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )`, and the two new files (`tls13.c`, `tls13.h`) and the new self-test (`tls13_test.c`) follow the same upstream dual licence;
- the TPM attestation files in `0011` (`efi_tpm2.c`, `efi_tpm2.h`, `ak_cmd.c`) are original kurrent-firmware implementations carrying `FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )`; the `EFI_TCG2_PROTOCOL` definitions they use are the standard UEFI specification values;
- `0012` (`sbenroll_cmd.c`, `sbenroll_data.h`) is an original kurrent-firmware implementation carrying `FILE_LICENCE ( GPL2_OR_LATER_OR_UBDL )`; `build/certs/MicrosoftUEFI-CA-2011.pem` is the public Microsoft UEFI CA 2011 certificate, redistributed as a trust anchor;
- `secureboot/0001-no-tofu.patch` modifies the project's own `tofu.c` (GPL2_OR_LATER_OR_UBDL) and adds no third-party code;
- this repository as a whole is licensed under GPL-2.0 (see `../LICENSE`); every patch header carries an SPDX declaration.

## Upgrading the Upstream Baseline

After an upstream upgrade the patches may no longer apply. Migration workflow:

1. Update the baseline:

   ```bash
   git fetch https://github.com/ipxe/ipxe.git master
   git log FETCH_HEAD --oneline | head   # confirm the new baseline
   ```

2. Regenerate the patches in the build cache worktree (`.cache/ipxe-upstream`) against the new baseline:

   ```bash
   # In .cache/ipxe-upstream: check out the new baseline, reproduce the modifications
   # (or apply the old patches and resolve conflicts), then:
   git diff > patches/0001-realtek-adaptation.patch
   ```

   Note: **apply the old patches to the new baseline → resolve conflicts manually → regenerate** is more reliable than rewriting by hand; regenerating overwrites the header licence comment, so copy it from the old patch header (see "Licensing" above).
3. Update `UPSTREAM_COMMIT` in `build/build.sh` and the baseline records in this document.

4. Run `./build/build.sh` to verify the patches apply cleanly and the artifacts work (key regression: 8125/8126 boot).

## Notes

- `embed/auto.ipxe` is a **configuration asset** (not a source patch): changes do not require regenerating patches — modify `../embed/auto.ipxe` and rebuild.
- Patches must pass `git apply --check`; patches are strongly tied to the baseline commit — always go through the upgrade workflow before changing `UPSTREAM_COMMIT`.
- When a patch is amended, edit it in place (regenerate from the build cache worktree) instead of appending a follow-up "fix of a fix" patch; if a fix must be layered, merge it back into the originating patch before release.

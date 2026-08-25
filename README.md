# Kurrent Firmware

[![License](https://img.shields.io/badge/License-GPL--2.0-green)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/dutyc/kurrent-firmware)](https://github.com/dutyc/kurrent-firmware)
[![Version](https://img.shields.io/github/v/tag/dutyc/kurrent-firmware)](https://github.com/dutyc/kurrent-firmware/releases)
[![Platform](https://img.shields.io/badge/Platform-x86_64%20UEFI%2FBIOS-0f766e)](docs/network-support.md)
[![Upstream](https://img.shields.io/badge/Upstream-iPXE%20e6e51ccb-111111)](patches/README.md)
[![Patches](https://img.shields.io/badge/Patches-12-7c3aed)](docs/customizations.md)

[English](README.md) | [中文](README.zh-CN.md)

>  **Production full-stack chain verified (2026-08-25)** — DHCP → TFTP → iPXE → control plane → NVMe/TCP auth (firmware + kernel) → GRUB 2.14 → rootfs → `login:`. Full record with serial + pcap evidence: **[production-boot-verification.md](docs/production-boot-verification.md)**.

**Kurrent Firmware** is the **firmware engine for Kurrent** — *make bare metal flow at the boot layer*. It is a **network boot firmware build repository**: it contains no iPXE source code — only difference patches and build assets — rebuildable on any upstream baseline. The `research/nvme-of` branch centres on the **NVMe-oF (NVMe over TCP) SAN boot** capability: a native `nvmetcp` driver with DH-HMAC-CHAP authentication, plus an in-band boot-credentials table (NBCT) so the kernel-side reconnect reuses the firmware's secret.

> **Branch: `research/nvme-of`** — experimental NVMe-oF SAN boot development branch: `nvmetcp` driver, DH-HMAC-CHAP authentication, NBCT credential table, NBFT/initramfs consumer seed module, test tooling. Exploratory work is kept isolated from `main`; it may be merged into `main` once stabilized.

----

## NVMe-oF: SAN boot over NVMe/TCP

Upstream iPXE has no NVMe-oF client. This branch adds a native one (patch [0006](patches/0006-nvmeof-adaptation.patch)): `nvmetcp` — an NVMe/TCP driver derived from the Linux kernel NVMe-oF implementation and the TP 8000 / NVM Express Base 2.x specifications. It boots disks over the network with full DH-HMAC-CHAP authentication, with no extra boot software between the firmware and the target.

### Boot chain

```
UEFI → iPXE nvmetcp → NVMe/TCP :4420 → nvmet target
  → Connect → DH-HMAC-CHAP (Negotiate → Challenge → Reply → Success1)
  → Property Set (CC.EN=1) → Identify Ctrl/NS → I/O queue (qid 1)
  → sanboot (GRUB 2.14) → kernel → initramfs NBFT/NBCT consumer
  → `nvme connect` reconnect with the firmware's secret → rootfs
```

### Authentication

- DH-HMAC-CHAP (one-way): Negotiate → Challenge → Reply → Success1, triggered by the ATR flag / `AUTH_REQUIRED` status on the Connect response
- SHA-256/384/512 hashes, DH groups 2048/3072/4096 (ffdhe4096 exercised in validation); DHHC-1 key format with CRC32 verification
- State-machine race fixes (patch [0007](patches/0007-nvmetcp-auth-fix.patch)): `completed`/`rx_complete` gating and command-id matching for out-of-order completions

### Credential relay: NBCT

Patch [0012](patches/0012-nvmetcp-nbct-acpi-table.patch) adds an in-band boot-credentials ACPI table (NBCT): the firmware writes the per-session DH-HMAC-CHAP secret and host NQN; the initramfs seed module ([initramfs-nbft/](initramfs-nbft/)) reads the table and reconnects with `nvme connect --dhchap-secret` — no second network fetch of credentials.

### Identity

Patch [0011](patches/0011-nvmetcp-hostnqn-setting.patch) adds a `hostnqn` setting for per-MAC NVMe identity, enabling strict-mode authentication (`allow_any_host=0`) on the target.

### Status

- DH-HMAC-CHAP authentication → SAN boot chain closed end-to-end under QEMU + Linux nvmet (2026-08-19): [nvmeof-auth-debug-log.md](docs/nvmeof-auth-debug-log.md)
- Six-ring NBFT chain — sanboot → GRUB → kernel → initramfs NBFT consumption → rootfs → login — verified (2026-08-21): [nbft-boot-verification.md](docs/nbft-boot-verification.md)
- Full production-stack chain — DHCP → TFTP → iPXE → control plane (report/challenge/boot-vars) → NVMe/TCP auth (firmware + kernel) → GRUB 2.14 → 6.12 kernel → rootfs → login — verified (2026-08-25): [production-boot-verification.md](docs/production-boot-verification.md)
- Protocol design, message formats and wire details: [nvmeof-research.md](docs/nvmeof-research.md)

## Other Customizations

Beyond NVMe-oF, the patch set (twelve in total, pinned baseline `e6e51ccb`) also carries: native RTL8125 (2.5G) / RTL8126 (5G) NIC drivers, SNP local-boot fallback, debug builds, device information collection, an EFI-variable NVS backend (device identity key / server fingerprint persist across reboot), TOFU (trust-on-first-use) certificate fingerprinting, and device identity key commands (`keygen`/`pubkey`/`sign`, ECDSA P-256). Design rationale and implementation: **[docs/customizations.md](./docs/customizations.md)**. NIC support matrix and field-test records: [docs/network-support.md](./docs/network-support.md).

## Quick Start

```bash
./build/build.sh    # Full build: fetch source -> apply patches -> build -> archive
```

Requirements: Linux with `git` / `make` / `gcc`. Artifacts are written to `dist/` (7 UEFI form factors + `SHA256SUMS`); see [docs/build-artifacts.md](./docs/build-artifacts.md) for the full list and selection guide.

Try NVMe-oF in QEMU:

```bash
sudo bash test/nvmet-setup.sh        # NVMe/TCP target on 127.0.0.1:4420 (AUTH=1 enables DH-HMAC-CHAP)
python3 test/cred-server.py 8000     # credential endpoint (required with AUTH=1)
bash test/run-qemu-auth.sh           # one QEMU validation round
```

## Documentation

- [NVMe-oF usage](./docs/nvmeof-usage.md) — target setup (incl. DH-HMAC-CHAP auth), `sanboot` usage, QEMU validation (Chinese only)
- [NVMe-oF test procedure](./docs/nvmeof-test-procedure.md) — end-to-end test flow: `test/` scripts, GRUB boot disk, QEMU rounds, pcap analysis (Chinese only)
- [NBFT boot verification](./docs/nbft-boot-verification.md) — six-ring full-chain verification record (Chinese only)
- [Production boot verification](./docs/production-boot-verification.md) — Kurrent full-stack cold-boot chain record: three blocking issues fixed (4K GPT / 6.12 auth kernel / systemd network takeover), serial + pcap evidence (Chinese only)
- [Customizations](./docs/customizations.md) — design rationale and implementation of every patch
- [NIC support matrix](./docs/network-support.md) — coverage and field-test records
- [Device information reporting](./docs/device-info-reporting.md) — collected settings and report URL usage
- [Build artifacts](./docs/build-artifacts.md) — artifact list, checksums, selection guide
- [Capability reference for Kurrent](./docs/capability-reference.md) — firmware capabilities and interface contracts, credential injection flow in detail (Chinese only)
- [Device trust-root usage](./docs/device-trust-usage.md) — `keygen`/`pubkey`/`sign` commands, TOFU HTTPS behaviour, NVRAM-backed settings, signature verification contract (Chinese only)
- [Patch set](./patches/README.md) — licensing and upstream baseline upgrade workflow
- [RTL8126 porting audit](./docs/8126-porting-audit.md) — dual-source porting audit records (Chinese only)

## Platform Repository

**[Kurrent](https://github.com/dutyc/ipxe-all-ready)** (周流) — the cloud-native platform that carries statelessness to the compute layer itself: compute is not bound to any specific hardware; nodes boot on plug-in, discardable and rebuildable in seconds. Two sides of the same idea: the platform makes compute stateless; this repository makes the boot firmware flow.

## Community & Contribution

Welcome Star / Watch / Issues / Pull Requests. As with the platform repository: **AI may write the syntax; the architecture must be understood by humans**.

## License

Licensed under **[GPL-2.0](./LICENSE)**, compatible with upstream iPXE (GPL-2.0-or-later / UBDL dual-licensed). Adaptations derived from third-party drivers are **GPL-2.0 only** and may not be redistributed under UBDL or any later licence — see [patches/README.md](./patches/README.md).

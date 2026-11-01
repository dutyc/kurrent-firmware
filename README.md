# Kurrent Firmware

[![License](https://img.shields.io/badge/License-GPL--2.0-green)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/dutyc/kurrent-firmware)](https://github.com/dutyc/kurrent-firmware)
[![Version](https://img.shields.io/github/v/tag/dutyc/kurrent-firmware)](https://github.com/dutyc/kurrent-firmware/releases)
[![Platform](https://img.shields.io/badge/Platform-x86_64%20UEFI-0f766e)](docs/network-support.md)
[![Upstream](https://img.shields.io/badge/Upstream-iPXE%20e6e51ccb-111111)](patches/README.md)
[![Patches](https://img.shields.io/badge/Patches-10-7c3aed)](docs/customizations.md)

[English](README.md) | [中文](README.zh-CN.md)

**Kurrent Firmware** is the **firmware engine for Kurrent** — *make bare metal flow at the boot layer*. It contains no iPXE source code — only difference patches and build assets — rebuildable on any upstream baseline. Its core is **NVMe-oF (NVMe over TCP) SAN boot** — a native `nvmetcp` driver (with DH-HMAC-CHAP authentication) fills the upstream gap, plus an in-band boot-credentials table (NBCT) so the kernel-side reconnect reuses the firmware's secret; no extra boot software between the firmware and the target.

## Boot chain

```
UEFI → iPXE nvmetcp (TLS 1.3 PSK) → NVMe/TCP :4421 → nvmet target
  → Connect → DH-HMAC-CHAP (Negotiate → Challenge → Reply → Success1)
  → Property Set (CC.EN=1) → Identify Ctrl/NS → I/O queue (qid 1)
  → sanboot (GRUB 2.14) → kernel → initramfs NBFT/NBCT consumer
  → `nvme connect --tls` reconnect with the firmware's secret → rootfs
```

Protocol design, message formats and wire details: [nvmeof-research.md](docs/nvmeof-research.md).

## Capabilities

- **NVMe-oF SAN boot** — a native `nvmetcp` driver (TP 8000 / NVM Express Base 2.x); UEFI firmware boots disks straight off an NVMe/TCP target.
- **DH-HMAC-CHAP authentication** — one-way (SHA-256/384/512, DH groups up to ffdhe4096), DHHC-1 keys with CRC32; per-MAC `hostnqn` enables strict-mode targets (`allow_any_host=0`).
- **Credential relay (NBCT)** — the firmware writes the per-session secret and host NQN; the initramfs seed module ([initramfs-nbft/](initramfs-nbft/)) reads the table and reconnects with `nvme connect --dhchap-secret` — no second network fetch of credentials.
- **Golden image matrix** — SAN golden images for Debian 12/13, Ubuntu 24.04/26.04, Fedora 44, AlmaLinux 10.2 and openSUSE Leap 16.0 have all passed cold-boot acceptance: [golden-image-matrix.md](docs/golden-image-matrix.md).
- **NIC & firmware customizations** — native RTL8125/RTL8126 drivers, SNP local-boot fallback, device identity keys and TOFU fingerprinting; ten patches in total: [customizations.md](docs/customizations.md), [network-support.md](docs/network-support.md).

## Quick Start

```bash
./build/build.sh    # Full build: fetch source -> apply patches -> build -> archive
```

Requirements: Linux with `git` / `make` / `gcc`. Artifacts are written to `dist/` (7 UEFI form factors + `SHA256SUMS`). See [Firmware Build and Deployment](https://dutyc.github.io/kurrent/en/firmware/build-deploy.html) for the build and deployment flow.

## Documentation

Full documentation lives under [`docs/`](./docs/); frequently used entries:

- [NVMe-oF usage](docs/nvmeof-usage.md) — target setup (incl. DH-HMAC-CHAP), `sanboot` usage and QEMU validation
- [Build artifacts](docs/build-artifacts.md) — artifact list, form-factor selection and checksums
- [Golden image matrix](docs/golden-image-matrix.md) — per-distro setup scripts, differences and acceptance status
- [Capability reference for Kurrent](docs/capability-reference.md) — firmware capabilities and interface contracts, credential injection flow
- [Patch set](patches/README.md) — licensing and upstream baseline upgrade workflow

## Platform Repository

**[Kurrent](https://github.com/dutyc/ipxe-all-ready)** (周流) — the cloud-native platform that carries statelessness to the compute layer itself: compute is not bound to any specific hardware; nodes boot on plug-in, discardable and rebuildable in seconds. Two sides of the same idea: the platform makes compute stateless; this repository makes the boot firmware flow.

## Community & Contribution

Welcome Star / Watch / Issues / Pull Requests. As with the platform repository: **AI may write the syntax; the architecture must be understood by humans**.

## License

Licensed under **[GPL-2.0](./LICENSE)**, compatible with upstream iPXE (GPL-2.0-or-later / UBDL dual-licensed). Adaptations derived from third-party drivers are **GPL-2.0 only** and may not be redistributed under UBDL or any later licence — see [patches/README.md](./patches/README.md).

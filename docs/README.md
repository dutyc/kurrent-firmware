# Documentation

The documents are grouped by purpose. Every document under the root,
`guides/` and `reference/` exists in English and as a `.zh-CN.md` counterpart.

## Core documents

| Document | English | Chinese |
|---|---|---|
| Capability reference for Kurrent | [capability-reference.md](capability-reference.md) | [capability-reference.zh-CN.md](capability-reference.zh-CN.md) |
| Firmware customizations | [customizations.md](customizations.md) | [customizations.zh-CN.md](customizations.zh-CN.md) |
| Golden image matrix | [golden-image-matrix.md](golden-image-matrix.md) | [golden-image-matrix.zh-CN.md](golden-image-matrix.zh-CN.md) |
| NVMe-oF usage | [nvmeof-usage.md](nvmeof-usage.md) | [nvmeof-usage.zh-CN.md](nvmeof-usage.zh-CN.md) |
| Secure Boot profile | [secureboot.md](secureboot.md) | [secureboot.zh-CN.md](secureboot.zh-CN.md) |

## Guides

| Guide | English | Chinese |
|---|---|---|
| Build artifacts | [guides/build-artifacts.md](guides/build-artifacts.md) | [guides/build-artifacts.zh-CN.md](guides/build-artifacts.zh-CN.md) |
| Golden image customization (Debian 12) | [guides/golden-image-customization-debian12.md](guides/golden-image-customization-debian12.md) | [guides/golden-image-customization-debian12.zh-CN.md](guides/golden-image-customization-debian12.zh-CN.md) |
| NVMe-oF test procedure | [guides/nvmeof-test-procedure.md](guides/nvmeof-test-procedure.md) | [guides/nvmeof-test-procedure.zh-CN.md](guides/nvmeof-test-procedure.zh-CN.md) |
| Device trust usage | [guides/device-trust-usage.md](guides/device-trust-usage.md) | [guides/device-trust-usage.zh-CN.md](guides/device-trust-usage.zh-CN.md) |

## Reference

| Reference | English | Chinese |
|---|---|---|
| Device information reporting | [reference/device-info-reporting.md](reference/device-info-reporting.md) | [reference/device-info-reporting.zh-CN.md](reference/device-info-reporting.zh-CN.md) |
| Network support | [reference/network-support.md](reference/network-support.md) | [reference/network-support.zh-CN.md](reference/network-support.zh-CN.md) |

## Archive

Historical research, debugging and verification records. They are kept in the
language they were written in (Chinese) and are not maintained against the
current code.

- [8126-porting-audit.md](archive/8126-porting-audit.md) — RTL8126 PHY table porting audit
- [8168-research-log.md](archive/8168-research-log.md) — RTL8168 driver investigation
- [nbft-consumption-research.md](archive/nbft-consumption-research.md) — kernel-side NBFT consumption research
- [nbft-boot-verification.md](archive/nbft-boot-verification.md) — NBFT boot-chain verification record
- [debian12-nbft-auth-verification.md](archive/debian12-nbft-auth-verification.md) — Debian 12 authenticated boot verification
- [nvmeof-auth-debug-log.md](archive/nvmeof-auth-debug-log.md) — DH-HMAC-CHAP debugging log
- [nvmeof-research.md](archive/nvmeof-research.md) — NVMe-oF protocol research
- [nvmeof-san-boot-verification.md](archive/nvmeof-san-boot-verification.md) — unauthenticated SAN boot verification
- [production-boot-verification.md](archive/production-boot-verification.md) — production boot-chain verification
- [real-reinstall-tls-coldboot-verification.md](archive/real-reinstall-tls-coldboot-verification.md) — real reinstall and TLS cold-boot verification (Debian 13 / Ubuntu 26.04)
- [debian12-tls-coldboot-verification.md](archive/debian12-tls-coldboot-verification.md) — Debian 12 TLS-only cold-boot verification with source-built userspace

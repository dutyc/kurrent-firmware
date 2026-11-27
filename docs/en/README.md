# Documentation

The firmware documentation is split by language. This directory holds the English set; the Chinese set lives in [`../zh/`](../zh/README.md).

- [Build and artifacts](build.md) — the seven UEFI artifacts and the Secure Boot profile
- [Firmware interface contract](interface.md) — boot chain, control plane endpoints, TPM attestation, NBCT handoff
- [Distribution matrix](distributions.md) — supported distributions, the A–F flow, adding a new one
- [Verification](verification.md) — repository gates and the isolated cold-boot acceptance

Historical research, debugging and verification records are kept in Chinese under [`../zh/archive/`](../zh/archive/) and are not maintained against the current code.

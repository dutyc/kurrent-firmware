# test

Tests, QEMU ranges, capture analysis and fixtures. Golden image provisioning
lives in `golden/`; the layout gate keeps the two trees apart.

| Entry | Content |
|---|---|
| `ci-gates.sh` | repository gates (`layout`, `syntax`, `shellcheck`, `embed`, `boot`, `pcap`, `replay`, `build`) |
| `archlinux/` | Arch-specific unit tests for the installer exit path and the DHCP interface choice |
| `manual/` | hand-driven QEMU validation suites; see [manual/README.md](manual/README.md) |
| `shared/` | QEMU scaffolding, isolated PXE/NVMe-oF ranges, capture analysis and shared fixtures |
| `test-nbft-connect-nbct.sh` | NBCT parsing and connection unit tests |

```bash
bash test/ci-gates.sh layout
bash test/test-nbft-connect-nbct.sh
```

CI runs every gate from `.github/workflows/ci.yml`. The manual suites are not
part of CI; they need `/dev/kvm`, root for the isolated bridge or nvmet target,
and a firmware built with the suite's `*.ipxe` script.

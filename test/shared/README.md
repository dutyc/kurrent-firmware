# test/shared

Reusable pieces for the manual and semi-automated test flows. Everything here
runs from the repository root; runtime output goes to `diag/` or `.cache/`
(both gitignored).

## Sourced libraries

| File | Used by | Purpose |
|---|---|---|
| `golden-common.sh` | `test/*/golden-image-setup-*.sh` | A-F image customization stages shared by all distributions; embedded into the scripts as `EMBED_B64_COMMON` so they stay single-file |
| `golden-install-vm.sh` | `test/almalinux10/run-almalinux10-install.sh`, `test/opensuse-leap16/run-leap16-install.sh` | host-side installer scaffolding: SSH key, ISO kernel/initrd extraction, HTTP source, target disk and OVMF variables |
| `qemu-lib.sh` | `test/run-qemu-*.sh` | OVMF paths, ESP check, private TMPDIR and the shared QEMU argument groups (`QEMU_STD`, `QEMU_FAT`, `QEMU_NET`) |

`embed-components.py` regenerates the `EMBED_B64_*` blocks (initramfs-nbft
components, BOOTX64 image and the golden-common copy) from the repository
sources. `verify-embed.py` checks the decoded SHA-256 of every block against
its source and fails on a missing, duplicated or stale copy:

```bash
python3 test/shared/embed-components.py
python3 test/shared/verify-embed.py
```

## Manual QEMU helpers

| File | Purpose | Notes |
|---|---|---|
| `fwtest-boot.sh` | PXE cold boot over an isolated bridge, with optional NVMe/TCP credentials | Requires root for the tap/bridge and a local dnsmasq; not sourced |
| `fwtest-net.sh` | `setup`/`teardown` of the `br-fwtest` bridge and tap | Root; pairs with `fwtest-boot.sh` |
| `fwtest-nvmet-tls.sh` | configfs nvmet target with TLS 1.3 and DH-HMAC-CHAP | Extends `test/nvmet-setup.sh` with the PSK keyring setup |
| `golden-esp-verify.sh` | Mount a 512-sector view of a golden image and list the 4K ESP | Read-only inspection |
| `golden-net-rebuild.sh` | Rebuild `br0`/`tap0` and NAT after a host reboot | Root |
| `golden-nvmet-enable.sh` | Re-enable an nvmet namespace from the host mount namespace | Root |
| `golden-vm-run.sh` | Boot a raw golden image under QEMU with SSH forwarding (`:2222`) | QMP socket under `/tmp` |
| `golden-ubuntu-vm-run.sh` | Boot a cloud image with a seed ISO (`:2222`) | Companion of the raw-image runner |
| `golden-vm-sendkey.py` | Send the SSH public key to a running golden VM | Used with the two runners above |
| `pcap-flows.py` | Summarize client TCP connections, first payload bytes and TLS record types in a capture | Connections are keyed by the four-tuple and started by SYN (port reuse with a new SYN counts separately); sequence gaps, retransmissions and snaplen truncation stay in the same connection |
| `test_pcap_flows.py` | Regression tests for `pcap-flows.py` | Standard library only; generates synthetic captures, no real pcap |

### Capture analysis

`pcap-flows.py` prints `client_connections_to_<port>`, one `connN` line per
connection, `first_bytes`, `plaintext_markers`, `packets_to_<plain-port>` and
`truncated_packets`, and exits non-zero unless every connection starts with
`0x16`, no credential marker appears and the plaintext port count is 0. A
connection is the four-tuple starting at its client SYN; payload after a
sequence gap, retransmission or snaplen cut stays in that connection, a new SYN
on a reused tuple starts a new one, and a capture without the SYN is anchored
at its first payload.

`test_pcap_flows.py` covers these cases with synthetic captures; CI runs it
through `bash test/ci-gates.sh pcap`.

`assets/BOOTX64-2.14-generic.EFI` is the GRUB image embedded into the golden
scripts; see `docs/zh/build.md` for its origin and licence.

## Test NQNs

Fixtures use the project test domain:

| Role | NQN |
|---|---|
| subsystem | `nqn.2026-07.com.kurrent:test` |
| host | `nqn.2026-07.com.kurrent:host.test` |
| extra namespaces | `nqn.2026-07.com.kurrent:disk0`, `:disk1` |

These replace the old `nqn.2026-08.org.ipxe-stateless:*` and
`nqn.2026-08.test:*` names. `nqn.2014-08.org.ipxe:ipxe` is the upstream iPXE
fallback host NQN used when the platform provides no SMBIOS UUID; it is not a
project name. Historical verification records under `docs/` keep the values
observed at the time.

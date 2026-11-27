# Verification

[English](verification.md) | [中文](../zh/verification.md)

Verification is split into repository gates (no environment needed) and the
isolated host-side cold-boot acceptance (QEMU/OVMF + an nvmet TLS target).

## Repository gates

`test/ci-gates.sh` runs the checks that CI and local runs share:

```bash
bash test/ci-gates.sh syntax     # bash -n / sh -n on every tracked script
bash test/ci-gates.sh shellcheck # ShellCheck at error severity
bash test/ci-gates.sh embed      # every embedded payload matches its source
bash test/ci-gates.sh boot       # initramfs TLS wiring (tlshd config, kTLS ciphers)
bash test/ci-gates.sh pcap       # pcap flow-aggregation tests
bash test/ci-gates.sh replay     # patches 0001..0012 against the pinned baseline
bash test/ci-gates.sh build      # full build + dist/SHA256SUMS
```

Unit tests are compiled into the firmware test image and run under QEMU/OVMF:

```bash
make -C .cache/ipxe-upstream/src bin-x86_64-efi/tests.efi
```

The full suite reports `all 11762 tests passed` on the serial console
(`tls13` 110, `tls13conn` 27, `nvmetcp` 101, plus the baseline suites).

## Isolated cold-boot acceptance

The isolated bridge leaves the production `br0/4421` untouched:

```bash
sudo bash test/shared/fwtest-net.sh setup            # br-fwtest + tap0fw
sudo bash test/shared/fwtest-nvmet-tls.sh setup <raw> <subnqn> <hostnqn> <DHHC> \
      192.168.81.1 4422 3                            # tls1.3 / required
TRSVCID=4422 bash test/shared/fwtest-boot.sh --nqn <subnqn> \
     --secret '<DHHC-1:..>' --psk <hex> --serial diag/x.serial --pcap diag/x.pcap
python3 test/shared/pcap-flows.py diag/x.pcap --port 4422 --secret '<DHHC-1:..>' --psk <hex>
```

Passing criteria: `login:` on the serial console; two
`nvmet: Created nvm controller … , TLS.` lines in the target dmesg; the capture
script reports `ALL_TLS_HANDSHAKE`, `plaintext_markers=none`, `packets_to_4420=0`.

The historical per-distribution acceptance records (pcaps, serial logs and
verification notes) are kept in the archive under `docs/zh/archive/`.

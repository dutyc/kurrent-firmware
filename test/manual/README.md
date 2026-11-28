# test/manual

Hand-driven QEMU validation suites. Each suite owns its `run-qemu-*.sh`
entry, its iPXE script and any generator; runtime output stays under `diag/`
(gitignored). Requires `/dev/kvm`, a built firmware with the suite's script
embedded, and root only where the suite starts an nvmet target.

| Suite | Entry | Order |
|---|---|---|
| `ak/` | `bash test/manual/ak/run-qemu-ak.sh <1\|2>` | rounds share `diag/ak/swtpm` and `diag/OVMF_VARS-ak.fd`; round 1 first. `--no-tpm` is the negative case |
| `auth/` | `bash test/manual/auth/run-qemu-auth.sh` | start `test/shared/nvmet-setup.sh AUTH=1` first |
| `nbft/` | `bash test/manual/nbft/run-qemu-nbft.sh` | `test/shared/nvmet-setup.sh` → `make-debian-san-disk.sh` → build/deploy the firmware → `gen-nbft-table.py` → run |
| `nvs/` | `bash test/manual/nvs/run-qemu-nvs.sh <setup\|verify>` | setup then verify on one `diag/OVMF_VARS.fd`; `run-qemu-nvclear.sh` covers clear rounds 1–3 |
| `tofu/` | `bash test/manual/tofu/run-qemu-tofu.sh <1\|2\|3>` | rounds share `diag/OVMF_VARS.fd`; round 1 first. Server certificates are generated under `diag/tls/` |

Logs, captures and disk images land in `diag/`; the repository keeps no test
certificates.

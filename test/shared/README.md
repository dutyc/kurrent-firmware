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
sources. Run it after changing any embedded source:

```bash
python3 test/shared/embed-components.py
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
| `pcap-flows.py` | Summarize client flows, first bytes and TLS record types in a capture | Used to prove plaintext/TLS paths |

`assets/BOOTX64-2.14-generic.EFI` is the GRUB image embedded into the golden
scripts; see `docs/build-artifacts.md` for its origin and licence.

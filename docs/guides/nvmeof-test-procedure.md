# NVMe-oF Firmware Test Procedure (test/ Directory)

[English](nvmeof-test-procedure.md) | [中文](nvmeof-test-procedure.zh-CN.md)

This document describes the complete test procedure of the delivered scripts in the `test/` directory: from nvmet target configuration and GRUB boot disk creation to test firmware builds, QEMU full-chain verification, and pcap/log analysis.

## 1. Directory Roles

| Directory | Content | Tracked in repository |
|---|---|---|
| `test/` | Deliverable test procedure scripts (tracked by this repository) | Yes |
| `diag/` | Local diagnostic workspace: run artifacts (disk images, logs, pcaps, OVMF_VARS.fd, temporary FAT disks) | No (gitignore) |
| `docs/` | Documentation (this procedure document, usage guide, troubleshooting log) | Yes |

All scripts are invoked with `test/` paths; run artifacts (`nvme-boot.img`, `qemu-*.log`, `netdump-*.pcap`, `tmp/` and so on) are written to `diag/` and do not pollute the repository.

## 2. Environment Prerequisites

- QEMU + OVMF (`/usr/share/OVMF/OVMF_CODE_4M.fd`, `OVMF_VARS_4M.fd`), with `/dev/kvm` available (QEMU steps must run outside the sandbox)
- Kernel modules `nvmet`/`nvmet_tcp` (server side)
- Tools: `python3`, `mkfs.vfat`, `mcopy` (mtools), `grub-mkimage`, `nvme-cli` (host diagnostics only), `timeout`, `ss`
- **`test/nvmet-setup.sh` and `test/nvme-host-diagnose.sh` require sudo** (configfs writes, module loading); in environments without sudo privileges these steps must be executed manually, and the remaining steps require no root

## 3. Script Inventory

| Script | Function | Dependencies | Privileges |
|---|---|---|---|
| `make-grub-bootdisk.sh` | Creates a bootable NVMe/TCP backing disk (GPT 4K sectors + FAT32 ESP + GRUB EFI) and writes `diag/nvme-boot.img` | `python3`/`mkfs.vfat`/`mcopy`/`grub-mkimage` | none |
| `nvmet-setup.sh` | nvmet target configuration (idempotent, includes DHHC-1 key self-check); `AUTH=1` enables authentication | kernel module `nvmet_tcp` | sudo |
| `cred-server.py` | HTTP credential injection endpoint (`/boot-vars`) returning a `set nbft-secret ...` script body | none | none |
| `nvmeof-auth-test.ipxe` | Script embedded in the authentication test firmware (credential injection → sanboot) | `cred-server.py` | — |
| `nvmeof-test.ipxe` | Script embedded in the unauthenticated test firmware (HTTP connectivity → sanboot) | none | — |
| `run-qemu-auth.sh` | Runs one QEMU verification round, writing `diag/qemu-<round>.log` + `diag/netdump-<round>.pcap` | firmware placed in `diag/tmp/EFI/BOOT/`, OVMF | none (requires KVM) |
| `parse-pcap-auth.py` | Per-packet PDU summary from a pcap (reads `diag/netdump-auth.pcap` by default) | none | none |
| `parse-pcap-stream.py` | TCP stream reassembly parsing of a pcap (PDUs spanning segments) | none | none |
| `nvme-host-diagnose.sh` | Host-side connection diagnostics (dyndbg + nvme-cli + dmesg delta) | `nvme-cli` | sudo |

Dependency order: `make-grub-bootdisk.sh` → `nvmet-setup.sh` → `run-qemu-auth.sh` → `parse-pcap-*.py`; the authentication chain additionally requires `cred-server.py`.

## 4. Test Procedure

### 4.1 Unauthenticated Chain

```bash
# 1. Create the GRUB-bootable backing disk (no root)
bash test/make-grub-bootdisk.sh
#    output: diag/nvme-boot.img (512 MiB, GRUB menu "NVMe/TCP SAN boot OK")

# 2. Configure the nvmet target (no authentication, sudo)
sudo bash test/nvmet-setup.sh
#    expected final output: ==> LISTENING on 4420

# 3. Build the test firmware (with the unauthenticated test script embedded)
bash build/build.sh    # or build only the test target:
#    make -C .cache/ipxe-upstream/src bin-x86_64-efi/ipxe.efi \
#      EMBED=test/nvmeof-test.ipxe DEBUG=nvmetcp:3

# 4. Place it on the QEMU FAT disk and run (outside the sandbox)
mkdir -p diag/tmp/EFI/BOOT
cp .cache/ipxe-upstream/src/bin-x86_64-efi/ipxe.efi diag/tmp/EFI/BOOT/BOOTX64.EFI
bash test/run-qemu-auth.sh basic    # log diag/qemu-basic.log, capture diag/netdump-basic.pcap

# 5. Verify (see section 5)
grep -E "namespace 1:|I/O queue established|GRUB BOOTED" diag/qemu-basic.log
```

### 4.2 Authentication Chain (DH-HMAC-CHAP)

```bash
# 1. Create the backing disk (as above)
bash test/make-grub-bootdisk.sh

# 2. Configure the nvmet target (authentication enabled, sudo)
sudo AUTH=1 bash test/nvmet-setup.sh
#    expected output includes: dhchap_key / dhchap_dhgroup / allowed_hosts listed

# 3. Start the credential injection endpoint (required by the authentication chain; it provisions the secret)
python3 test/cred-server.py &        # :8000 by default, log cred-server.log

# 4. Build the authentication test firmware (nvmetcp_auth debug is required, otherwise no authentication output appears)
make -C .cache/ipxe-upstream/src bin-x86_64-efi/ipxe.efi \
  EMBED=test/nvmeof-auth-test.ipxe DEBUG=nvmetcp,nvmetcp_auth:3

# 5. Place it on the FAT disk and run
cp .cache/ipxe-upstream/src/bin-x86_64-efi/ipxe.efi diag/tmp/EFI/BOOT/BOOTX64.EFI
bash test/run-qemu-auth.sh auth     # writes diag/qemu-auth.log + diag/netdump-auth.pcap by default

# 6. Verify (see section 5)
grep -E "CRED-FETCH|authentication succeeded|sending Property Set|GRUB BOOTED" diag/qemu-auth.log
python3 test/parse-pcap-auth.py     # reads diag/netdump-auth.pcap by default
```

## 5. Verification Method

**Log evidence chain** (`DEBUG=nvmetcp,nvmetcp_auth:3` firmware):

```
sending Connect (qid 0)          → Connect(admin) completion
completion: cid 1 status 0x0     → Connect succeeded (ATR path)
authentication required          → server requires authentication
sent Negotiate / authentication succeeded → four authentication messages completed
sending Property Set (CC)        → authentication stage correctly closed (core of the 0005 fix)
namespace 1: N blocks of 4096 bytes → Identify completed
I/O queue established            → I/O connection ready
== GRUB BOOTED FROM NVME/TCP SAN DISK == → on-disk boot succeeded
```

**pcap evidence chain** (`parse-pcap-auth.py`):

```
ICREQ/ICRESP → CMD cid=1 Connect → RSP status=0x0000 result=0x00020001 (ATR)
→ four AuthSend/AuthReceive authentication messages → CMD cid=7 PropSet → RSP status=0x0000
→ Identify → I/O queue; status=0x0 throughout, no 0x8018
```

**Unit tests** (regression guard, no environment required):

```bash
make -C .cache/ipxe-upstream/src bin-x86_64-linux/tests.linux
.cache/ipxe-upstream/src/bin-x86_64-linux/tests.linux   # full suite, 11625 assertions
```

## 6. Failure Reference

| Symptom | Cause and remedy |
|---|---|
| `==> NOT LISTENING (check nvmet_tcp module)` | `nvmet_tcp` is not loaded; run `modprobe nvmet_tcp` and re-run `nvmet-setup.sh` |
| `ERROR: subsystem dir still present (live controller?)` | A controller is still connected; disconnect (`nvme disconnect-all`) or unload nvmet, then re-run |
| `base64 key decoding error -1` | The DHHC-1 prefix is not the two-digit type `DHHC-1:XX:` (the kernel skips a 10-byte prefix); the key self-check is built into `nvmet-setup.sh` |
| `Failed to setup authentication, dhchap status 2` | The CRC32 is not the zlib final value in little-endian order; regenerate with the `python3 -c '...'` line in the script |
| No `authentication succeeded` in the log | The firmware does not include `nvmetcp_auth` debug (`DEBUG=nvmetcp,nvmetcp_auth:3` rather than `nvmetcp` alone) |
| `command failed: status 0x8018` in the log | The authentication stage was skipped (Property Set not sent); the firmware lacks patch 0005 or an old firmware is in use |
| The parser labels Identify as PropSet | An older parser is in use; the `test/` version decides by opcode==0x7f |
| QEMU does not start (KVM error) | It must run outside the sandbox (/dev/kvm not visible) |

## 7. Key Consistency

The DHHC-1 key (`DHHC-1:01:...`) is fixed separately in three scripts and **must be kept exactly identical**:

- `test/nvmet-setup.sh` (`DHHCP_KEY`, written to configfs)
- `test/cred-server.py` (`SECRET`, injected into iPXE)
- `test/nvme-host-diagnose.sh` (`KEY`, host-side direct connection verification)

Each script has a built-in key self-check (prefix length plus CRC32 final value validation), so a mistake fails immediately at configuration time rather than surfacing only at run time. When changing the key, update all three locations.

## 8. Related Documents

- [nbft-boot-verification.md](../archive/nbft-boot-verification.md) — NBFT end-to-end boot verification across six links (NBFT consumption → rootfs mount → login prompt)
- [nvmeof-usage.md](../nvmeof-usage.md) — firmware NVMe-OF end-to-end usage (deployment, sanboot, verification method)
- [nvmeof-auth-debug-log.md](../archive/nvmeof-auth-debug-log.md) — authentication troubleshooting history (0x8018 root cause, state machine fix, status of remaining items)
- [customizations.md](../customizations.md) — customization inventory (patch 0005 notes)

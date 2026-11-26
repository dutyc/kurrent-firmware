# NVMe-OF (NVMe over TCP) SAN Boot Firmware Usage Guide

[English](nvmeof-usage.md) | [中文](nvmeof-usage.zh-CN.md)

> Scope: firmware built from patch chain `0001-0011` (baseline `e6e51ccb`).
> For implementation details see [customizations.md](customizations.md) (patch 0005); for the authentication troubleshooting history see [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md).

## 1. Capability Overview

The firmware contains a purpose-built `nvmetcp` driver (patch 0005) that provides NVMe over TCP SAN boot capability:

- **Protocol flow**: ICReq/ICResp parameter negotiation → Connect (Admin queue) → Property Set (CC.EN=1) → Identify (controller/namespace) → I/O queue Connect → block read/write (R2T flow control)
- **Authentication**: DH-HMAC-CHAP (SHA-256/384/512, DH groups 0/2048/3072/4096; patch 0005 contains the authentication completion sequencing and state machine race fixes)
- **Verified environment**: client QEMU/OVMF (x86_64 UEFI) plus server Ubuntu 26.04 (kernel 7.0.0-14) nvmet TCP target plus GRUB 2.14 chainload; the full chain passes (every wire-level command returns `status=0x0000`)

**Boundaries**: TCP transport only (no RDMA/FC); authentication is fixed to DH-HMAC-CHAP; the boot path covers a single controller and a single namespace (Identify parses 512B/4K blocks).

## 2. Firmware Artifacts and Deployment

`./build/build.sh` writes artifacts to `dist/` (the full list is in `docs/build-artifacts.md`):

| Artifact | Boot environment | Typical deployment |
|---|---|---|
| `pxe-uefi/ipxe.efi` | UEFI + PXE | Loaded with `chain` from the DHCP menu (native drivers) |
| `pxe-uefi/snponly.efi` | UEFI + PXE/local | As above; falls back to taking over all SNP/NII/MNP devices when chainloading fails (patch 0003) |
| `pxe-uefi/ipxe-debug.efi`, `pxe-uefi/snponly-debug.efi` | UEFI + PXE | Debug builds of the corresponding artifacts |
| `direct-uefi/ipxe.efi` | UEFI local | Firmware boots directly (for example `\EFI\BOOT\BOOTX64.EFI` on the ESP); the embedded `embed/auto.ipxe` boot chain is built in |
| `direct-uefi/snponly.efi` | UEFI local | As above, SNP-only |
| `direct-uefi/ipxe-debug.efi` | UEFI local | Debug build of the corresponding artifact |

Debug artifacts enable `DEBUG=realtek:3`. To obtain `nvmetcp` debug logs, rebuild with `DEBUG=nvmetcp:3`; to obtain authentication module logs (such as `authentication succeeded`), add `nvmetcp_auth`, that is `DEBUG=nvmetcp,nvmetcp_auth:3` (`DEBUG=` takes effect by source file name).

Deployment notes:

- **UEFI**: copy `ipxe.efi` to `\EFI\ipxe\ipxe.efi` on the ESP and add a boot entry in the firmware Boot Manager; or boot it with GRUB2 `chainloader /EFI/ipxe/ipxe.efi`
- **PXE**: DHCP hands out `next-server`/the boot file name, and the menu runs `chain tftp://${next-server}/ipxe.efi`
- **Automatic boot chain** (`direct-uefi`): `dhcp` → `chain tftp://${next-server}/boot.ipxe` → control-plane script (the script may execute `sanboot`, see section 4)

## 3. Server Side: nvmet Target Configuration

### 3.1 Prerequisites

```bash
sudo modprobe nvmet
sudo modprobe nvmet_tcp
mount | grep configfs        # configfs must be mounted (normally /sys/kernel/config by default)
```

The backing file should be placed in the project workspace (for example `diag/nvme-boot.img`) rather than `/tmp` (even root may be unable to write there in a restricted environment).

### 3.2 Minimal Configuration Without Authentication

```bash
NQN="nqn.2026-07.com.kurrent:test"     # example NQN, adjust as needed
IMG=/path/to/backing.img
SYS=/sys/kernel/config/nvmet/subsystems/$NQN
PORT=/sys/kernel/config/nvmet/ports/1

mkdir -p "$SYS"
echo 1 > "$SYS/attr_allow_any_host"           # no authentication: admit any host
mkdir -p "$SYS/namespaces/1"
echo -n "$IMG" > "$SYS/namespaces/1/device_path"
echo 1 > "$SYS/namespaces/1/enable"

mkdir -p "$PORT"
echo ipv4 > "$PORT/addr_adrfam"
echo tcp  > "$PORT/addr_trtype"
echo 127.0.0.1 > "$PORT/addr_traddr"
echo 4420 > "$PORT/addr_trsvcid"
ln -sf "$SYS" "$PORT/subsystems/$NQN"

ss -tln | grep 4420          # confirm LISTENING
```

The example uses the `com.kurrent` test domain. Scripts under `test/` that used to show `nqn.2026-08.org.ipxe-stateless:test` (and `nqn.2026-08.test:*` in the self-test) now use `nqn.2026-07.com.kurrent:test` and `nqn.2026-07.com.kurrent:host.test`; earlier verification records keep the old names as written.

Ready-made script: [test/nvmet-setup.sh](../test/nvmet-setup.sh) (idempotent, may be re-run).

### 3.3 DH-HMAC-CHAP Authentication Configuration

**Key format** (NVMe specification): `DHHC-1:XX:<base64(key + CRC32)>`

- `XX` must be two digits (`01` = SHA-256); the kernel skips a fixed 10-byte prefix on both sides, so a single-digit `XX` truncates the first base64 character and produces `base64 key decoding error -1`
- `CRC32` must be the standard CRC-32 **final value** (`zlib.crc32`), appended to the key in little-endian order; omitting the final XOR causes nvmet to reject the key with `dhchap status 2`

Generation command:

```bash
python3 -c 'import zlib,base64; k=b"0123456789abcdef0123456789abcdef"; \
print("DHHC-1:01:"+base64.b64encode(k+zlib.crc32(k).to_bytes(4,"little")).decode())'
```

**configfs layout (kernel 7.0+, different from `auth_ctrl/attr_authentication` in 6.x)**:

```bash
HOSTNQN="nqn.2014-08.org.ipxe:ipxe"           # must match the Host NQN the client actually sends
HOST_DIR=/sys/kernel/config/nvmet/hosts/$HOSTNQN

echo 0 > "$SYS/attr_allow_any_host"           # when =1 the kernel skips authentication entirely (important!)
mkdir -p "$HOST_DIR"
echo -n "$KEY" > "$HOST_DIR/dhchap_key"
echo ffdhe4096 > "$HOST_DIR/dhchap_dhgroup"
ln -sf "$HOST_DIR" "$SYS/allowed_hosts/$HOSTNQN"   # symbolic link, mkdir does not work
```

**Host NQN matching**: the iPXE Host NQN is derived from the SMBIOS UUID; when QEMU+OVMF provides no UUID the firmware falls back to the fixed `nqn.2014-08.org.ipxe:ipxe`, and the server-side `hosts/` directory name must match.

Ready-made script: `sudo AUTH=1 bash test/nvmet-setup.sh` (built-in key self-check and idempotent cleanup).

### 3.4 Server Configuration Error Reference

| Symptom | Cause | Remedy |
|---|---|---|
| `base64 key decoding error -1` | The `DHHC-1:XX:` prefix is shorter than 10 bytes (single-digit XX) | Keep two digits: `DHHC-1:01:...` |
| `Failed to setup authentication, dhchap status 2` | The key CRC32 is not the final value | Regenerate with `zlib.crc32` (including the final XOR) |
| Authentication has no effect at all (unauthenticated direct connection) | `attr_allow_any_host=1` | Set it to 0 and recreate the subsystem |
| `Can't set allow_any_host when explicit hosts are set!` | Leftover `allowed_hosts/` link (old configuration not cleaned up) | `rm -f $SYS/allowed_hosts/*` and then rmdir |

## 4. Client: sanboot Usage

### 4.1 URI Syntax

```text
sanboot nvme://<traddr>:<trsvcid>/<nqn>[?secret=<DHHC-1 key>]
```

- Without authentication: `sanboot nvme://10.0.2.2:4420/nqn.2026-07.com.kurrent:test`
- With authentication: `sanboot nvme://10.0.2.2:4420/nqn.2026-07.com.kurrent:test?secret=DHHC-1:01:...`
- Success indicators (`DEBUG=nvmetcp,nvmetcp_auth:3` logs): `sending Property Set (CC)` → `namespace 1: N blocks of 4096 bytes` → `I/O queue established`, after which control passes to the on-disk boot loader (GRUB)

### 4.2 Two Forms of Authentication Requirement Detection

When the server requires authentication, iPXE detects it from the Connect completion (both forms are supported):

1. **ATR bit**: bit 17 of the `result` field in the Connect response is set (observed on nvmet 7.0.0-14: `status=0x0000, result=0x00020001`)
2. **Status code**: Connect completion status `0x0c` (`NVME_SC_AUTH_REQUIRED`) with no ATR bit (compatibility path, patch 0005)

After detection, if no `secret` parameter is present the firmware reports `authentication required but no secret` and refuses to boot.

### 4.3 Key Injection Mode (Control-Plane Provisioning, Recommended)

The key is not fixed in the firmware; the control plane provisions it per client and injects it into the `${nbft-secret}` variable:

```ipxe
#!ipxe
dhcp || goto failed
chain --autofree http://10.0.2.2:8000/boot-vars?mac=${mac}&hostname=${hostname} \
  || goto failed          # response body is an iPXE script: set nbft-secret DHHC-1:01:...
sanboot nvme://10.0.2.2:4420/nqn.2026-07.com.kurrent:test?secret=${nbft-secret}
:failed
shell
```

With TLS enabled, the control plane provisions `nbft-tls-psk` / `nbft-tls-port` (both are **mandatory** under the default fully encrypted chain), and the script appends
`&tls_psk=${nbft-tls-psk}&tls_trsvcid=${nbft-tls-port}` to the URI. These two parameters serve a **dual purpose** (stage 1.3c + stage 2.2):

- They are handed to initramfs together with the NBCT table, which reconnects on the TLS port with `--tls` (see `initramfs-nbft/nbft-connect`);
- They also determine whether the **firmware stage itself** encrypts: when the sanboot URI port equals `tls_trsvcid`, the firmware performs a
  TLS 1.3 PSK handshake for that connection (the PSK is `tls_psk`, identity = `NVMe0R01 <hostnqn> <subsysnqn>`).

The control plane takes the sanboot port from `nbft-tls-port` (the storage node data-plane port), so by default both the **firmware stage and the kernel stage are encrypted**;
when the port or key is missing the control plane does not provision the boot variables and the script runs `goto failed`, with no fallback to plaintext `:4420`. The decision logic is implemented in
`nvmetcp_use_tls()` in `nvmetcp.c`, and the handshake and record layer in `add_tls13_psk()` in `net/tls13.c`.
(The local test target `test/nvmet-setup.sh` from sections 3 and 5 remains plaintext `:4420`; in that case the firmware uses the plaintext path, the compatibility branch of the criterion.)

> Security note: in production this endpoint must sit behind strong authentication (TLS/mTLS plus client identity verification); [test/cred-server.py](../test/cred-server.py) is a test endpoint for verification only. A complete embeddable script example is in [test/nvmeof-auth-test.ipxe](../test/nvmeof-auth-test.ipxe).

### 4.4 Interactive Shell

After booting any iPXE build (including the PXE variants), the following can be entered:

```ipxe
iPXE> sanboot nvme://10.0.2.2:4420/nqn.2026-07.com.kurrent:test?secret=...
```

## 5. Verification Method (QEMU Full Chain)

### 5.1 Prerequisites

- Host: KVM (`/dev/kvm`), OVMF firmware (`/usr/share/OVMF/OVMF_CODE_4M.fd`)
- Server: nvmet modules loaded, port 4420 listening (section 3)

### 5.2 Steps

```bash
# 1. Server side (with authentication)
sudo AUTH=1 bash test/nvmet-setup.sh          # output ==>> LISTENING on 4420

# 2. Credential endpoint (port 8000 by default)
python3 test/cred-server.py &

# 3. Build firmware containing the test script and nvmetcp debug output, deploy to the FAT image
#    (diag/tmp/EFI/BOOT/BOOTX64.EFI; the test script is test/nvmeof-auth-test.ipxe)

# 4. Start QEMU (outside the sandbox, with KVM)
bash test/run-qemu-auth.sh                    # timeout 150s; log qemu-auth.log, capture netdump-auth.pcap
```

### 5.3 Expected Results (Evidence Chain)

Key sequence in `qemu-auth.log`:

```text
sending Connect (qid 0)
completion: cid 1 status 0x0          # Connect completion, ATR bit set
authentication required
sending Property Set (CC)             # ← authentication succeeded → enable controller (fix in patch 0005)
...
namespace 1: 131072 blocks of 4096 bytes
I/O queue established
... GNU GRUB 2.14 ... "NVMe/TCP SAN boot OK"
```

Wire sequence in `netdump-auth.pcap` (parser `test/parse-pcap-auth.py`): ICREQ/ICRESP → `CMD cid=1 Connect` → `RSP status=0x0000 result=0x00020001` (ATR) → the four AuthSend/AuthReceive authentication messages → `CMD cid=7 PropSet` → `RSP status=0x0000` → Identify → I/O queue; `0x8018` never appears.

### 5.4 Client Failure Reference

| Symptom | Meaning | Remedy |
|---|---|---|
| `command failed: status 0x8018` (Identify rejected) | Command Sequence Error: the controller is not enabled (`CC.EN==0`), **Property Set was skipped** | Authentication completion sequencing problem, see [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md) Bug 3; confirm the firmware contains patch 0005 |
| No `sending Property Set (CC)` in the log at all | Authentication did not complete or a phase race occurred | As above; check the server authentication configuration and key |
| `Connection reset` after authentication | AuthReceive sent more than once (firmware lacks the send idempotency fix from patch 0005) | Rebuild the firmware with 0005 |
| `authentication required but no secret` | The server requires authentication but no secret was provided | Check the URI `?secret=` parameter and the `${nbft-secret}` injection |
| Retry after `waiting for window (...)` | Transient send failure (-EAGAIN); after the 0005 fix the window is awaited automatically | Normal path, no intervention needed |
| `command failed` (during Connect) | The server rejected the connection (NQN/port/authentication mismatch) | Check the 3.2/3.3 configuration; confirm listening with `ss -tln` |

## 6. Limitations and Cautions

- The firmware must contain the **complete patch chain 0001-0011**: the authentication fix is merged into `0005` (formerly the separate patch 0007); a build missing it or using an older chain skips Property Set during authentication and ends in 0x8018
- The `nvmetcp` driver has no default debug output at build time; to obtain authentication/state machine logs (including `authentication succeeded`) build manually with `DEBUG=nvmetcp,nvmetcp_auth:3` (`DEBUG=nvmetcp:3` alone does not show output from `nvmetcp_auth.c`)
- Authentication supports DH-HMAC-CHAP only (SHA-256/384/512); DH groups 0/2048/3072/4096 are supported (the server may be configured with `ffdhe4096`)
- The Host NQN depends on the SMBIOS UUID; platforms without a UUID (such as QEMU+OVMF) fall back to a fixed NQN, and the server must be configured for the actual value
- Server-side CRC32 checking of keys is strict (final value, little-endian); after generation the built-in self-check in `test/nvmet-setup.sh` can confirm correctness

## 7. Related Documents

| Document | Scope |
|---|---|
| [customizations.md](customizations.md) | Design and implementation of patch 0005 (result-oriented document) |
| [nvmeof-auth-debug-log.md](nvmeof-auth-debug-log.md) | Full authentication troubleshooting history: timeline of three bugs, 0x8018 decoding, verification evidence (process-oriented document) |
| [network-support.md](network-support.md) | NIC support matrix and test records |
| [build-artifacts.md](build-artifacts.md) | Build artifact list and selection guide |
| [patches/README.md](../patches/README.md) | Patch chain inventory, baseline, licensing and upgrade procedure |

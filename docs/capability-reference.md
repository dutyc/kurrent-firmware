# Firmware Capability Implementation Reference (for Kurrent Integration)

[English](capability-reference.md) | [中文](capability-reference.zh-CN.md)

> Intended audience: developers and integrators of the main repository Kurrent (stateless operation of the compute layer).
> This repository, kurrent-firmware, is the **firmware foundation** at the bottom of the Kurrent boot chain: the two repositories share the same semantics and keep their responsibilities strictly separate (firmware build versus stateless compute operation).
> This document describes the **implementation approach and interface contracts** of the capabilities already implemented in the firmware layer, with emphasis on the **NVMe-oF authentication credential delivery chain** (Chapter 4). For operational procedures, see [nvmeof-usage.md](nvmeof-usage.md).

## 1. Capability Overview and Repository Responsibilities

### 1.1 Responsibility Boundaries

| Repository | Responsibility | Deliverable |
|---|---|---|
| **Kurrent** (main repository) | Stateless operation of the compute layer: control plane, dynamic variable chain, identity injection, node registration, disk-host decoupling, NBFT consumption | Control plane services, boot chain scripts (boot.ipxe etc.), initramfs integration |
| **kurrent-firmware** (this repository, firmware foundation) | Firmware build and customization: protocol drivers, authentication, device information collection, NIC adaptation | Firmware artifacts under `dist/`, patch chain under `patches/`, test scripts under `test/` |

Interface boundary: the main repository interacts with the firmware through the **DHCP/TFTP/HTTP control plane**—boot chain scripts are delivered by the control plane, identity and credentials are injected through control plane endpoints (see Chapter 4), and device information is collected and reported by the firmware.

### 1.2 Firmware Layer Capability List

| # | Capability | Implementation location | Status |
|---|---|---|---|
| 1 | NVMe over TCP SAN boot (nvmetcp driver, 8-phase state machine) | Patch 0005 | Verified (QEMU/OVMF + nvmet 7.0 + GRUB 2.14, full chain) |
| 2 | DH-HMAC-CHAP authentication (including the state machine race fix) | Patch 0005 | Verified (wire evidence on the ATR path + unit test coverage) |
| 3 | Control plane injection of authentication credentials (`nbft-secret` dynamic variable) | `embed/auto.ipxe` + control plane `/boot-vars` endpoint | Verified (full-chain scripts under test/) |
| 4 | Device information collection (SMBIOS memory, PCI driver name → `${net0/chip}` etc.) | Patch 0004 | Verified |
| 5 | NIC adaptation (RTL8125/8126 drivers, snponly takeover fallback, UNDI) | Patches 0001-0003 | Verified |
| 6 | UEFI firmware artifacts (PXE-UEFI / direct UEFI, 7 in total) | `build/build.sh` → `dist/` | Reproducible build |
| 7 | Test system (11762 unit test assertions, QEMU full chain, pcap analysis) | `tests/` (inside patches), `test/` directory | Regression guardrail |

## 2. Boot Chain and Interface Boundaries

### 2.1 Firmware-Side Boot Chain (`embed/auto.ipxe`)

```ipxe
#!ipxe
dhcp || goto failed
chain --autofree tftp://${next-server}/boot.ipxe || goto failed   # enter the main repository boot chain
exit
:failed
shell
```

- `next-server` is provided by DHCP; in a co-located deployment it is the control plane IP address
- `boot.ipxe` and everything after it (`boot.ipxe.cfg`, `menu.ipxe`) is hosted by the **main repository control plane**; the firmware embeds no business scripts
- For the authentication test firmware's embedded script, see `test/nvmeof-auth-test.ipxe` (directly `chain http://<control plane>/boot-vars` → `sanboot`)

### 2.2 Firmware Layer Interface Points (Contracts the Main Repository Must Implement)

| Interface | Direction | Purpose |
|---|---|---|
| DHCP (next-server) | Control plane → firmware | Locate the boot chain server |
| TFTP `/boot.ipxe` | Control plane → firmware | Boot chain entry script |
| HTTP `/boot-vars?mac=...&hostname=...` | Firmware → control plane | **Dynamic variable injection (including authentication credentials)**; the response is an iPXE script body |
| HTTP device information reporting | Firmware → control plane | Device information collection (patch 0004, see 5.1) |
| `nvme://` SAN URI | Firmware internal | `sanboot` entry (including the `?secret=` authentication parameter) |

**Form of the dynamic variable chain in the firmware layer**: the main repository's notion that "the control plane injects the real identity through the dynamic variable chain" is realized in the firmware layer as `chain --autofree http://.../boot-vars?...` → the response body (an `#!ipxe` script) executes `set <variable> <value>` → subsequent scripts reference `${<variable>}`. Variables are **fetched anew on every boot** and are never pinned in the firmware image.

## 3. NVMe-oF Capability Implementation Reference (Driver Layer)

### 3.1 Session State Machine (8 Phases)

```
ICREQ → CONNECT_ADMIN → AUTH → PROP_SET → IDENTIFY_CTRL → IDENTIFY_NS
      → ICREQ_IO → CONNECT_IO → READY (failure in any phase → FAILED)
```

| Phase | Action | Notes |
|---|---|---|
| ICREQ | Parameter negotiation (PFV, maximum PDU, etc.) | 128-byte ICReq/ICResp |
| CONNECT_ADMIN | Connect command (fctype=0x01, Admin queue) | Authentication requirements are identified on completion (see 4.2) |
| AUTH | DH-HMAC-CHAP four messages (see 3.3) | Authentication sub-state machine (5 steps) |
| PROP_SET | Property Set (CC register, CC.EN=1) | **Must wait until authentication has fully finished**, otherwise Identify is rejected with `0x8018` |
| IDENTIFY_CTRL/NS | Identify controller and namespace | Parse LBAF to compute block size/capacity (512B/4K) |
| ICREQ_IO/CONNECT_IO | I/O queue connection | Enters READY once established |
| READY | Block read/write (R2T flow control) | Provides service to sanboot/BlockIo |

### 3.2 Authentication Sub-State Machine and Key Fixes (Patch 0005)

The authentication sub-state machine has 5 steps: `START → COMPLETE_NEGOTIATE → CHALLENGE → COMPLETE_REPLY → SUCCESS1 → START`.

Three bugs found and fixed during troubleshooting (wire evidence in [nvmeof-auth-debug-log.md](archive/nvmeof-auth-debug-log.md)):

1. **A transient `-EAGAIN` kills the session**: a send failure while the TCP window is closed aborted the session → now the driver waits for the window to reopen and retries (`tx_in_flight` gating prevents duplicate sends)
2. **Duplicate AuthReceive sends**: the window retry path overlapped the normal advancement path → sends are now idempotent and the step advances uniformly
3. **Authentication completion race (0x8018)**: the Success1 data and the final AuthReceive completion may arrive out of order (within the same TCP segment); advancing on the step alone misjudges the Reply completion as the AuthReceive completion, which skips the Property Set and causes Identify to be rejected with `0x8018` → **dual-flag gating** (`completed` + `rx_complete`) plus **command id matching** (`rx_cid`); both must hold before advancing to PROP_SET

Unit test coverage (`tests/nvmetcp_test.c`, delivered with patch 0005): phase completion gating, command id matching and the START step guard; the full 11762 assertions pass (`tests.efi`).

### 3.3 Authentication Message Flow (DH-HMAC-CHAP, Four Messages)

Fabric commands `fctype=0x05` (AuthSend) / `0x06` (AuthReceive); negotiation messages:

| Message | AuthSend payload | Contents |
|---|---|---|
| 1. Negotiate | `nvmf_auth_dhchap_negotiate_data` | Hash (01=SHA-256, 02=SHA-384, 03=SHA-512), DH group (0/2048/3072/4096), transaction random number |
| 2. Challenge | `nvmf_auth_dhchap_challenge_data` | 16-byte cval, server DH public key |
| 3. Reply | `nvmf_auth_dhchap_reply_data` | Client DH public key + response rval |
| 4. Success1 | `nvmf_auth_dhchap_success1_data` | Server verification (hl/rvalid fields) |

- Bidirectional authentication (`rvalid=1`) is **not supported**; it is reported as `-EPROTO` when received
- Hash support: SHA-256/SHA-384/SHA-512 (selected by the server during Negotiate); DH groups 0 (no DH)/2048/3072/4096 (the server can be configured with `ffdhe4096` to perform the full DH exchange)
- Failure path: any failed verification returns an error code and the session enters FAILED

### 3.4 BlockIo and the EFI Device Path (sanboot Protocol)

- The driver implements the EFI device path description and BlockIo hookup; the `sanboot` command attaches the SAN disk as a bootable device
- Authentication test firmware: `sanboot nvme://<traddr>:<trsvcid>/<nqn>?secret=...`; on success control passes to the boot loader on the disk (verified with GRUB 2.14: `== GRUB BOOTED FROM NVME/TCP SAN DISK ==`)
- On failure the firmware falls back to the iPXE shell (observable through `sanboot rc = ${?}`)

### 3.5 Driver Layer Limitations

- TCP transport only (no RDMA/FC)
- Single-controller, single-namespace boot path
- No compile-time default debug output; a `DEBUG=nvmetcp,nvmetcp_auth:3` build is required (`DEBUG=` takes effect per source file name, so `nvmetcp` alone does not show auth messages)

## 4. Authentication Credential Delivery Chain (Core)

> This chapter is the part that **must be fully aligned** during main repository integration: key format, trigger mechanism, injection method, endpoint contract and host identity matching. The firmware side is fully verified; what the main repository must implement is the control plane `/boot-vars` endpoint and the boot chain scripts.

### 4.1 Credential Form: DHHC-1 Key Format

**Format**: `DHHC-1:XX:<base64(key + CRC32)>`

| Segment | Rule | Consequence of violation (measured) |
|---|---|---|
| Prefix `DHHC-1:` | Fixed 7 characters | — |
| Type `XX` | **Must be two digits** (`01`=SHA-256); kernel code on both sides unconditionally skips the 10-byte prefix | A single digit truncates the first base64 character → `base64 key decoding error -1` |
| `base64(key+CRC32)` | 32-byte key + **CRC-32 final value** (`zlib.crc32`, including the final XOR) as 4 little-endian bytes; decoded length is 36 in total (or 68 for a 68-byte key) | A CRC that is not the final value → `Failed to setup authentication, dhchap status 2` |

**Generation command**:

```bash
python3 -c 'import zlib,base64; k=b"0123456789abcdef0123456789abcdef"; \
print("DHHC-1:01:"+base64.b64encode(k+zlib.crc32(k).to_bytes(4,"little")).decode())'
```

**Self-check**: `test/nvmet-setup.sh` / `test/cred-server.py` / `test/nvme-host-diagnose.sh` all embed the same self-check (prefix length + decoded length + CRC32 final value verification), so misconfiguration fails at configuration time instead of surfacing at runtime. The main repository should reuse this self-check logic when implementing key delivery.

### 4.2 Authentication Trigger (Firmware-Side Detection)

When the server requires authentication, iPXE detects it on Connect completion; **both forms are supported**:

| Form | Evidence | Notes |
|---|---|---|
| **ATR bit** (primary path) | Bit 17 of the `result` field in the Connect response is set | Measured with nvmet 7.0.0-14: `status=0x0000, result=0x00020001` (pcap evidence) |
| **Status code** (compatibility path) | Connect completion status `0x0c` (`NVME_SC_AUTH_REQUIRED`) without ATR | Compatibility branch added by patch 0005 |

When an authentication requirement is detected but no `secret` parameter is present → the firmware reports `authentication required but no secret` and refuses to boot. **Detecting the requirement and delivering the key are two independent steps**: for key delivery see 4.3/4.4.

### 4.3 Delivery Method A: URI `?secret=` Parameter (Direct)

**Complete URI format**:

```text
sanboot nvme://<server address>:<port>/<subsystem NQN>?secret=<DHHC-1 key>
```

**Three real examples** (from `test/nvmeof-test.ipxe` / `nvmeof-auth-test.ipxe`):

```ipxe
# 1. No authentication
sanboot nvme://10.0.2.2:4420/nqn.2026-07.com.kurrent:test

# 2. With authentication (key written directly in the URI)
sanboot nvme://10.0.2.2:4420/nqn.2026-07.com.kurrent:test?secret=DHHC-1:01:MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYOtVl3

# 3. With authentication (recommended: the key is delivered by the control plane and referenced as a variable in the script)
dhcp
chain --autofree http://10.0.2.2:8000/boot-vars?mac=${mac}&hostname=ipxe-auth-test
sanboot nvme://10.0.2.2:4420/nqn.2026-07.com.kurrent:test?secret=${nbft-secret}
```

**Field breakdown**:

| Field | Example | Notes |
|---|---|---|
| Scheme | `nvme://` | Fixed |
| Server address | `10.0.2.2` | Storage server IP (inside a QEMU virtual machine `10.0.2.2` is the host; use the server address on a real network) |
| Port | `4421` | Data plane port (NVMe/TCP TLS 1.3). `:4420` is the standard NVMe/TCP port and is used only for local testing and historical examples (`test/*.ipxe` point at plaintext test targets) |
| Subsystem NQN | `nqn.2026-07.com.kurrent:test` | The "street number"; must exactly match the NQN created in the server configfs |
| `?secret=` | `DHHC-1:01:...` | Optional; mandatory when the server requires authentication, otherwise the firmware reports `authentication required but no secret` and refuses to boot |
| `&tls_psk=` | 64 hexadecimal characters | TLS pre-shared key (segments 1.3c/2.2). It is handed to initramfs along with the NBCT table for reconnection in the kernel stage, and is used for the firmware-stage handshake when **the firmware's own connection port == `tls_trsvcid`** |
| `&tls_trsvcid=` | `4421` | TLS data plane port, always delivered together with `tls_psk` (both are required). It is also the criterion for whether the firmware stage is encrypted: if the URI port equals this value → the firmware performs TLS on that connection; otherwise → the firmware connects in plaintext (compatibility test targets only). The control plane has already switched the port to `tls_trsvcid` by default (see §4.4) |

**Notes**:

- No space is allowed before `?`; `secret=` is followed directly by the key, and the `:` and base64 characters inside the key need no escaping
- The interactive shell accepts it directly: `iPXE> sanboot nvme://10.0.2.2:4420/nqn.2026-07.com.kurrent:test?secret=...`
- A key supplied through method A is visible in scripts, menus and logs; in production prefer method B (4.4 control plane injection)
- `tls_psk`/`tls_trsvcid` have two roles: in the **kernel stage** they travel with the NBCT table to initramfs so it can reconnect on the TLS port; in the **firmware stage**, when the URI port == `tls_trsvcid` (`nvmetcp_use_tls()`), they perform a TLS 1.3 PSK handshake for the firmware's own connection. The control plane encrypts the whole chain by default—`nbft-tls-port` is the data plane port (`tls_trsvcid`), and the sanboot port in `menu.ipxe` is taken from it; if the port or the key is missing the firmware refuses to boot and no longer falls back to `:4420`. The port comparison criterion is retained so that local plaintext test targets (`test/nvmet-setup.sh`) still use the plaintext path
- Firmware-side URI parsing: `nvmetcp_parse_secret()` and `nvmetcp_parse_tls()` in `nvmetcp.c` (parse the `secret=` / `tls_psk=` / `tls_trsvcid=` query parameters into the session); whether to encrypt is decided by `nvmetcp_use_tls()`, and the handshake and record layer are handled by the `add_tls13_psk()` filter interface in `net/tls13.c`

### 4.4 Delivery Method B: Control Plane `/boot-vars` Injection (Recommended, Full Sequence)

**Design principle**: the key **never enters the firmware image** and **never enters the boot menu**; the control plane injects it dynamically when delivering the boot script, keyed by client MAC/hostname, and it is fetched anew on every boot.

**Sequence**:

```text
1. Firmware DHCP (obtains next-server = control plane)
2. Firmware chain http://<control plane>:8000/boot-vars?mac=${mac}&hostname=${hostname}
3. Control plane looks up the key by client identity and returns an iPXE script body:
     #!ipxe
     # credentials for mac=...&hostname=...
     set nbft-secret DHHC-1:01:...
4. Firmware executes the script body → variable nbft-secret is ready
5. Firmware executes sanboot nvme://...?secret=${nbft-secret}
6. Four authentication messages complete → PROP_SET → Identify → I/O queue → boot loader on disk
```

**Firmware-side script form** (`test/nvmeof-auth-test.ipxe`, can be embedded in the main repository boot chain):

```ipxe
#!ipxe
dhcp || goto failed
chain --autofree http://10.0.2.2:8000/boot-vars?mac=${mac}&hostname=${hostname} \
  && echo CRED-FETCH-OK || goto cred-failed
sanboot nvme://10.0.2.2:4420/nqn.2026-07.com.kurrent:test?secret=${nbft-secret}
:cred-failed
shell
```

**Credential lifecycle**:
- Injection happens during boot chain execution (`chain --autofree` fetches it, and it is released automatically after execution)
- The variable is valid only for the current boot session; after a firmware reboot the DHCP → fetch flow runs again
- Key rotation: updating the endpoint response on the control plane is sufficient; **neither the firmware nor the server-side configfs needs a rebuild** (server-side key writing is managed by `nvmet-setup.sh`)

### 4.5 Control Plane Endpoint Contract (`/boot-vars`)

Endpoint the main repository must implement (reference implementation: `test/cred-server.py`, verification only):

| Item | Contract |
|---|---|
| Request | `GET /boot-vars?mac=<MAC>&hostname=<hostname>` (additional query parameters may be added) |
| Response header | `Content-Type: text/plain`, correct `Content-Length` |
| Response body | `#!ipxe` script body: `set nbft-secret <DHHC-1 key>` (may contain several `set` lines, i.e. the dynamic variable chain) |
| Error handling | Unknown client → non-200 (e.g. 404/403); the firmware-side `chain` then fails and takes the `:cred-failed` branch to the shell |
| Credential matching | Look up the key the client should receive by MAC/hostname (the test endpoint returns a fixed key) |

**Security boundary** (important):
- The test endpoint uses plaintext HTTP and is restricted to verification environments (noted at the top of `test/cred-server.py`)
- **In production this endpoint must sit behind strong authentication** (TLS/mTLS + client identity verification)—the key travels over the network and the firmware side has no additional encryption layer, so the endpoint itself is the only trust boundary
- The main repository should merge this endpoint into the existing control plane identity system (same TLS channel, same client registry)

### 4.6 Key Consistency and Management

The key is **fixed independently in three locations and must be identical everywhere**:

| Location | Role | Notes |
|---|---|---|
| `test/nvmet-setup.sh` (`DHHCP_KEY`) | Written to the server configfs | `hosts/<HOSTNQN>/dhchap_key` |
| `test/cred-server.py` (`SECRET`) | Delivered to the firmware | `/boot-vars` response body |
| `test/nvme-host-diagnose.sh` (`KEY`) | Host-side direct connection verification | nvme-cli `--dhchap-secret` |

Correspondence on the main repository side: server-side key configuration (corresponds to 1) + control plane endpoint key store (corresponds to 2). **Key rotation procedure**: update both ends (configfs + control plane) in sync; no client change is required (the key is fetched anew on every boot). All scripts embed the self-check; after modifying a key, first run the self-check in `bash test/nvmet-setup.sh` to confirm.

### 4.7 Host Identity Matching (Host NQN)

- Firmware Host NQN construction (verified in `nvmetcp.c`): the prefix is fixed to `nqn.2014-08.org.ipxe:`
  - **With SMBIOS UUID**: `nqn.2014-08.org.ipxe:<uuid>` (`uuid_ntoa` format, with hyphens)
  - **Without UUID** (measured with QEMU+OVMF): falls back to the fixed value `nqn.2014-08.org.ipxe:ipxe`
- Server configfs: the `hosts/<HOSTNQN>/` directory name must match what the client actually sends, otherwise authentication either has no effect or is rejected
- Main repository integration note: on real hardware (with a SMBIOS UUID) the NQN is unique per machine—the control plane should be able to deliver the corresponding key per machine identity; manage `hosts/` along the UUID dimension

### 4.8 Kernel-Side NBFT Path: Current State and Gap

The main repository ecosystem contains two NVMe-oF paths:

| Path | Component | Authentication credential handling |
|---|---|---|
| **Firmware layer** (iPXE sanboot) | Patch 0005 in this repository + control plane `/boot-vars` | **Closed loop** (all of this chapter) |
| **Kernel layer** (NBFT consumption) | Seed module under `initramfs-nbft/` (`nbft-connect` + hooks/local-top, automatic consumption through `nbft_auto`, `nvme connect-all --nbft`) | **Not covered**: nbft-connect has no dhchap key handling logic |

Authentication key injection on the kernel path (a key field inside the NBFT table or injection through boot parameters) **awaits design in the main repository and alignment with upstream** (the SUSE dracut 95nvmf / nvme-cli autoconnect ecosystem); the firmware-layer path can serve as a verified reference implementation for the main repository.

### 4.9 Complete Sequence Diagram (Authentication Chain, Wire View)

```text
iPXE                                        nvmet(TCP:4420)         control plane(:8000)
  |  DHCP                                       |                        |
  |-------------------------------------------->|                        |
  |  chain http://10.0.2.2:8000/boot-vars       |                        |
  |---------------------------------------------------------->|         |
  |  #!ipxe / set nbft-secret DHHC-1:01:...     |                        |
  |<----------------------------------------------------------|         |
  |  ICReq/ICResp                               |                        |
  |  CMD cid=1 Connect                          |                        |
  |<-- RSP status=0x0 result=0x00020001(ATR)    |                        |
  |  AuthSend(Negotiate) / AuthReceive(Challenge)                      |
  |  AuthSend(Reply) / AuthReceive(Success1)                           |
  |  CMD cid=7 PropSet (CC.EN=1)                |                        |
  |<-- RSP status=0x0                           |                        |
  |  Identify(Controller/NS) → I/O queues       |                        |
  |  sanboot succeeds → GRUB on disk            |                        |
```

## 5. Other Capability Implementation References

### 5.1 Device Information Collection (Patch 0004)

- SMBIOS type 17 memory settings: `mem-total` (aggregated over all slots), `mem-type`/`mem-speed` (first slot)
- PCI `driver_name` population: `${net0/chip}` prints the device table name (e.g. `RTL8125`)
- Purpose: the device-side data source for the main repository's dynamic variable chain and for node registration. For the full list see [device-info-reporting.md](reference/device-info-reporting.md)

### 5.2 NIC Adaptation (Patches 0001-0003)

- RTL8125 (2.5GbE) and RTL8126 (5GbE, ICVerID detection + PHY configuration dispatch) driver customization
- `snponly.efi`: when chainloading fails it falls back to taking over all SNP/NII/MNP devices, excluding the SNP handles installed by iPXE itself (patch 0003; this prevents local boot from creating NICs recursively and exhausting the heap)
- For the support matrix see [network-support.md](reference/network-support.md)

### 5.3 Build and Deployment

- Patch chain `0001-0012` (baseline `e6e51ccb`); `build/build.sh` resets the working tree and applies the patches in order on every run, and the artifacts go to `dist/` (SHA256SUMS)
- Artifact form: UEFI only, 7 files in total—`ipxe.efi`, `ipxe-debug.efi`, `snponly.efi`, `snponly-debug.efi` under `pxe-uefi/`; `ipxe.efi`, `ipxe-debug.efi`, `snponly.efi` under `direct-uefi/` (all with `auto.ipxe` embedded)
- Debug builds: `DEBUG=nvmetcp,nvmetcp_auth:3` (authentication logs), `DEBUG=realtek:3` (NIC)
- `embed/auto.ipxe` is a configuration asset (not a source patch); changing it requires no patch regeneration

## 6. Verification and Test Reference (Reusable by the Main Repository)

| Means | Command/location | What it verifies |
|---|---|---|
| Unit tests | `make bin-x86_64-efi/tests.efi` → boot in QEMU/OVMF and read the serial console | All 11762 assertions (including the authentication state machine and the TLS 1.3 primitives and connection layer) |
| Target-side configuration | `sudo [AUTH=1] bash test/nvmet-setup.sh` | Idempotence, key self-check, `==> LISTENING on 4420` |
| Credential endpoint | `python3 test/cred-server.py` | `/boot-vars` injection |
| Boot disk | `bash test/make-grub-bootdisk.sh` | Bootable NVMe/TCP backend disk |
| QEMU rounds | `bash test/run-qemu-auth.sh [round]` (outside the sandbox) | Full-chain log `diag/qemu-<round>.log` + packet capture |
| pcap analysis | `python3 test/parse-pcap-auth.py` / `-stream.py` | Wire evidence chain: ATR, the four authentication messages, no 0x8018 throughout |

For the complete procedure see [nvmeof-test-procedure.md](guides/nvmeof-test-procedure.md). Log evidence chain:

```text
sending Connect (qid 0) → completion: cid 1 status 0x0
authentication required → sent Negotiate → authentication succeeded
sending Property Set (CC) → namespace 1: N blocks of 4096 bytes
I/O queue established → == GRUB BOOTED FROM NVME/TCP SAN DISK ==
```

## 7. Integration Checklist (Main Repository Side)

- [ ] The control plane implements `GET /boot-vars?mac=&hostname=`, returning an `#!ipxe` script body (`set nbft-secret ...`), placed behind TLS/mTLS in production
- [ ] The boot chain script (boot.ipxe chain) `chain`s `/boot-vars` to fetch variables before `sanboot`, and `sanboot` uses `${nbft-secret}`
- [ ] The key store matches `DHHCP_KEY` in `nvmet-setup.sh`; format `DHHC-1:XX:` (two-digit type) + CRC32 final value little-endian; reuse the self-check logic
- [ ] The server-side `hosts/<HostNQN>/` matches the NQN the client actually uses (SMBIOS UUID or fallback NQN)
- [ ] The firmware contains the complete patch chain 0001-0012 (the authentication fix is merged into 0005; with an older chain that lacks the fix, the authentication flow skips the Property Set and results in `0x8018`)
- [ ] Authentication chain verification: QEMU rounds + pcap evidence chain (Chapter 6)
- [ ] Plan authentication key injection for the kernel NBFT path (initramfs-nbft) according to the gap in 4.8

## 8. Related Document Index

| Document | Purpose |
|---|---|
| [nvmeof-usage.md](nvmeof-usage.md) | Usage guide (server configuration, sanboot usage, QEMU verification) |
| [nvmeof-test-procedure.md](guides/nvmeof-test-procedure.md) | Complete test procedure for the test/ scripts |
| [customizations.md](customizations.md) | Design and implementation of patch 0005 |
| [device-trust-usage.md](guides/device-trust-usage.md) | Usage of the device trust root capabilities (0006-0008, 0011: akgen/akpub/quote/nvclear, TPM attestation, TOFU, NVRAM settings) |
| [nvmeof-auth-debug-log.md](archive/nvmeof-auth-debug-log.md) | Full troubleshooting history of authentication (0x8018 root cause, wire evidence) |
| [nvmeof-research.md](archive/nvmeof-research.md) | Protocol research and design |
| [nvmeof-san-boot-verification.md](archive/nvmeof-san-boot-verification.md) | SAN boot verification record without authentication |
| `initramfs-nbft/README.md` | NBFT consumption seed module (kernel path) |
| [patches/README.md](../patches/README.md) | Patch chain, licensing (NVMe driver files GPL-2.0 only), upgrade procedure |

# Device Trust Root Capabilities Usage (Main Repository Reference)

[English](device-trust-usage.md) | [中文](device-trust-usage.zh-CN.md)

> Firmware-side capability notes for the Kurrent main repository: TPM 2.0 device
> identity (AK and PCR quote), TOFU HTTPS trust, NVRAM-persisted settings and the
> attestation interface contract. Corresponds to firmware patches
> 0006/0007/0008/0011 (see [patches/README.md](../../patches/README.md) and sections
> ## 6/7/8/11 of [customizations.md](../customizations.md)).

## 1. Capability Overview

The capabilities delivered by the firmware side (R1-R6) are all **command and
setting layer capabilities**—business logic (registration, challenge-issuance,
attestation verification) is implemented by the main repository boot scripts and
the control plane, and is not visible to the firmware.

| Requirement | Firmware capability | Entry point |
|---|---|---|
| R1 | HTTPS download (TLS 1.2, native iPXE implementation) | `imgfetch` / `chain` `https://...` |
| R2 | TOFU trust (first-contact acceptance + fingerprint pinning) | Automatic (no command) |
| R3 | EFI variable NVS backend (survives reboot) | `server-fingerprint` / `trust` settings |
| R4 | Create / reuse the device identity key inside the TPM | `akgen` command (idempotent) |
| R5 | Export the AK public key, name, algorithm and Secure Boot state | `akpub` command |
| R6 | SHA-256 quote over PCRs 0/2/4/7 | `quote <nonce>` command |

The device identity has **no software private key**: the AK private key is
generated and held by the TPM, cannot be exported, and the firmware exports only
the public key and signatures. Without a TPM these commands exit with a non-zero
status (`-ENODEV`); no software fallback exists.

## 2. Command Reference

### 2.1 `akgen` — Create / Reuse the AK

```
akgen
```

- **Behaviour**: creates a restricted signing key inside the TPM (ECC P-256
  preferred, falling back to RSA-2048 when the TPM rejects it), persists it to
  handle `0x81000001` with `TPM2_EvictControl`, then releases the transient
  handle. The private key never leaves the TPM, and the firmware never reads it.
- **Idempotence**: when an AK already exists it is only read and confirmed—never
  rebuilt or overwritten—printing `akgen: attestation key already present` and
  returning 0; the first creation prints `akgen: attestation key created`.
- **Persistence**: the AK lives in TPM NV and is independent of EFI variables—after
  wiping the OVMF variable store and rebooting, the same AK is still reused.
- **Typical use**: call it unconditionally once at the start of the boot script:
  `akgen || echo "identity: error"`.
- **Replacing the AK**: the firmware has no overwrite path. Only administrator
  recovery is available (delete the device registration and re-enrol the device),
  or clearing/replacing the TPM.

### 2.2 `akpub` — Export the Identity and Publish the Secure Boot State

```
akpub
```

- **Precondition**: `akgen` has succeeded (otherwise
  `akpub: no attestation key (run akgen first)`).
- **Outputs and settings** (in-memory settings for the current boot only, lost on
  reboot):

  | Output line | Setting name | Content |
  |---|---|---|
  | `ak-public:` | `ak-public` | Hex of the public key SubjectPublicKeyInfo DER |
  | `ak-name:` | `ak-name` | TPM2B_NAME, 68 hex (`000b` + SHA-256 of the public key structure) |
  | `ak-type:` | `ak-type` | `ecc_p256` or `rsa2048` (string) |
  | `sb:` | `sb` | `1` / `0`: derived from the EFI global variable `SecureBoot` |

- `sb` is written before the public key is exported, so even if the TPM is
  unavailable, `${sb}` has a value as long as `akpub` has been executed; without
  a TPM `${ak-public}` / `${ak-name}` / `${ak-type}` are empty.
- Access from scripts: `${ak-public}`, `${ak-name}`, `${ak-type}`, `${sb}`.

### 2.3 `quote <nonce>` — PCR Attestation

```
quote <nonce>
```

- **Precondition**: the AK exists.
- **Behaviour**: a single `TPM2_Quote` call reads and signs PCRs 0/2/4/7 (SHA-256
  bank); `nonce` is written verbatim as `qualifyingData` into `extraData` (64 hex
  characters = 64 ASCII bytes, **no hex decoding**).
- **Outputs and settings**:

  | Output line | Setting name | Content |
  |---|---|---|
  | `quote:` | `quote` | Hex of the raw TPMS_ATTEST bytes (without the TPM2B length prefix) |
  | `quote-sig:` | `quote-sig` | Hex of the signature over the raw quote bytes (ECC: ASN.1 DER; RSA: PKCS#1 v1.5) |

- Before exporting, the firmware self-checks: magic `0xFF544347`, type `0x8018`, a
  single SHA-256 selection, bitmap `95 00 00` (PCRs 0/2/4/7), 32-byte PCR digest.
- `nonce` length is limited to 1–64 bytes; the control plane always delivers 64
  hex characters.

### 2.4 `nvclear` — Clear the Device NVRAM

A single command clears every setting this project stores in non-volatile storage
(`server-fingerprint`, `trust`), restoring the device's TOFU state to factory
defaults. The device identity lives in the TPM and is unaffected by `nvclear`.

```
iPXE> nvclear
nvclear: server-fingerprint: cleared
nvclear: trust: not present
nvclear: device NVRAM cleared
```

- Each item is reported with one of three results: `cleared` / `not present`
  (already empty) / `could not clear: <errno>`; if any item fails, the last line
  reads `nvclear: incomplete` and the command returns non-zero so scripts can act
  on it.
- The clearing effect **persists across reboots** (patch 0006 makes zero-length
  option blocks actually issue a write; see §6 of
  [customizations.md](../customizations.md)).
- Only these two settings of this project are touched; no other UEFI variables are
  modified.
- The equivalent manual form is `clear nvo/<setting>` per item—**the `nvo/` block
  prefix is mandatory**; a bare `clear server-fingerprint` only clears the
  in-memory shadow, see §3 and §7.
- Acceptance: `test/nvs-clear.ipxe` + `test/run-qemu-nvclear.sh` (§8).

## 3. Settings Reference

| Setting name | Type | Tag | Persistence | Source |
|---|---|---|---|---|
| `server-fingerprint` | hexraw | DHCP 0x5f | **NVRAM (survives reboot)** | Defined by 0006, written by TOFU |
| `trust` | hex | DHCP 0x5a | Pre-existing upstream (NVRAM overrides the root certificate table) | TOFU mirror |
| `ak-public` | hexraw | DHCP 0x60 | Memory (current boot) | `akpub` |
| `quote` | hexraw | DHCP 0x61 | Memory (current boot) | `quote` |
| `quote-sig` | hexraw | DHCP 0x62 | Memory (current boot) | `quote` |
| `ak-name` | hexraw | DHCP 0x63 | Memory (current boot) | `akpub` |
| `ak-type` | string | DHCP 0x64 | Memory (current boot) | `akpub` |
| `sb` | string | DHCP 0x65 | Memory (current boot) | `akpub` |

- Access from scripts: `${server-fingerprint}`, `${trust}`, `${ak-public}`,
  `${quote}`, `${quote-sig}`, `${ak-name}`, `${ak-type}`, `${sb}`.
- Identity and attestation settings are command outputs staged **within the same
  boot** and never reach NVRAM.
- Clearing a persistent setting means deleting it, and **the `nvo/` block prefix is
  mandatory** (NVO settings are all encapsulated tags and do not match from the
  root route): `clear nvo/server-fingerprint` deletes the fingerprint. A bare
  `clear server-fingerprint` or `set server-fingerprint` (no value) has **no
  effect** on the NVS backend (measured), see §7. To clear both at once use
  `nvclear` (§2.4).
- When assigning `trust` manually, note that its type is `hex` (`33:33:…`,
  colon-separated), not `hexraw`; an unseparated `3333…` is rejected
  (`Invalid argument`).

## 4. TOFU (HTTPS Trust) Behaviour

TOFU takes effect automatically in the TLS handshake path (no command, no
configuration); the state machine is as follows:

| Phase | Condition | Behaviour |
|---|---|---|
| First contact | No `server-fingerprint` and certificate verification fails | **Handshake accepted**; the SHA-256 fingerprint of the leaf certificate is written to `server-fingerprint` (NVRAM) and mirrored to `trust` |
| Pinned and matching | Fingerprint present; the server certificate fingerprint matches | `trust` overrides the root certificate table (`ALLOW_TRUST_OVERRIDE`), certificate verification succeeds, download proceeds normally |
| Pinned and mismatched | Fingerprint present; the server certificate fingerprint differs | Verification fails → **rejected** (the existing fingerprint is not overwritten) |

Key points:

- **The fingerprint is the SHA-256 of the leaf certificate DER** (identical to the
  result of `openssl x509 -outform DER | sha256sum`).
- After the first-contact window the server certificate is **pinned**; changing the
  certificate (e.g. on rotation) requires clearing the NVRAM fingerprint first
  (reset the device, or a reset procedure delivered by the control plane).
- In production the server certificate may be self-signed (TOFU removes the CA
  hierarchy), but **TLS version ≤ 1.2** (the upper limit of the native iPXE TLS
  implementation).
- Both fingerprint writing and pinning decisions happen at the handshake layer: on
  mismatch the HTTP request is never sent.
- **Pinning is a single global anchor**: once `server-fingerprint` exists, any TLS
  verification failure is fatal—the firmware can only trust the certificate pinned
  by the first https connection. All HTTPS targets must therefore share that trust
  anchor: a unified ingress gateway (multiple domains sharing one certificate) or a
  certificate chain that terminates at the pinned certificate; other traffic can
  use TFTP/HTTP.
- Clearing `server-fingerprint` (`clear nvo/server-fingerprint`) releases the pin;
  the next https connection re-enters the registration window (see §6.4).

## 5. Attestation Interface Contract (Verification Side, Main Repository)

### 5.1 `quote` Contents

`quote` holds the raw TPMS_ATTEST bytes (hex transport, **without** the 2-byte
length prefix of TPM2B_ATTEST), produced by a single `TPM2_Quote`:

| Field | Value |
|---|---|
| `magic` | `0xFF544347` |
| `type` | `0x8018` (TPM_ST_ATTEST_QUOTE) |
| `qualifiedSigner` | TPM2B_NAME of the AK (34 bytes) |
| `extraData` | ASCII bytes of the `nonce` string (64 hex characters = 64 bytes) |
| PCR selection | SHA-256 only, bitmap `95 00 00` (PCRs 0/2/4/7) |
| `pcrDigest` | 32-byte SHA-256 |
| `firmwareVersion` / `clockInfo` | TPM's own information, skipped by the verification side |

PCR reading and signing complete within the same TPM call, so no measurement
change can occur between the two reads.

### 5.2 Signature and Encoding

| AK algorithm | Signature encoding |
|---|---|
| `ecc_p256` | ASN.1 DER (`SEQUENCE { INTEGER r, INTEGER s }`), ECDSA-SHA256 |
| `rsa2048` | PKCS#1 v1.5, SHA-256 |

The signed object is the **complete TPMS_ATTEST byte string** (i.e. the decoded
`quote` bytes); the transport encoding is hex.

### 5.3 Public Key and Name

- `ak-public` is SubjectPublicKeyInfo DER: `id-ecPublicKey + prime256v1` for ECC
  (91 bytes), `rsaEncryption` for RSA (294 bytes).
- `ak-name` is TPM2B_NAME: `000b` + SHA-256 of the public key structure (34 bytes /
  68 hex in total); the control plane only verifies the length and the algorithm
  prefix.
- `ak-type` must match the actual public key algorithm, otherwise the identity is
  considered invalid.

### 5.4 Host-Side Verification Example (Python + cryptography)

```python
#!/usr/bin/env python3
"""Verify the signature, nonce binding and PCR selection of a firmware quote"""
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.serialization import load_der_public_key

PCR_BITMAP = bytes([0x95, 0x00, 0x00])

def verify(ak_public_hex, ak_type, quote_hex, sig_hex, nonce):
    quote = bytes.fromhex(quote_hex)
    sig = bytes.fromhex(sig_hex)
    key = load_der_public_key(bytes.fromhex(ak_public_hex))
    if ak_type == "ecc_p256":
        key.verify(sig, quote, ec.ECDSA(hashes.SHA256()))
    else:
        key.verify(sig, quote, padding.PKCS1v15(), hashes.SHA256())
    # Structural checks: magic/type/extraData/PCR selection/digest length
    assert quote[:4] == bytes.fromhex("ff544347")
    # ... (full implementation in the control plane attestation module)
    return True
```

A standalone verifier that can be run directly from the repository:
`test/verify-ak-quote.py` (§8).

## 6. Integration Examples (Main Repository boot.ipxe Reference Patterns)

> General convention: every `https://` endpoint triggers TOFU pinning on first
> connection; make sure all HTTPS targets share the same trust anchor (see §4);
> `chain --autofree` releases a download once it has been fetched and executed.

### 6.1 Device Identity and Registration Report (First Boot)

```ipxe
# Idempotent: the AK is created on first use and reused afterwards; a failure (no TPM) does not affect subsequent script lines
akgen || echo "identity: no TPM"

# Export the identity; without a TPM go to the identity-less report path
akpub || goto report-fingerprint

chain --autofree \
    https://mgmt.example.com/devices/report?mac=${netX/mac}&ak_public=${ak-public}&ak_name=${ak-name}&ak_type=${ak-type}&sb=${sb} \
    || goto report-done

:report-fingerprint
# A report without an AK makes the control plane record the device as no_tpm; the fingerprint is still merged
chain --autofree \
    https://mgmt.example.com/devices/report?mac=${netX/mac}&sb=${sb} ||
:report-done
```

### 6.2 Challenge-Attestation (Boot Credential Delivery)

```ipxe
# 1. Obtain a one-time nonce (response body is #!ipxe: set nonce <64hex>)
:challenge
chain --autofree https://mgmt.example.com/devices/challenge?mac=${mac} \
    && goto quoted || goto bootvars

# 2. Perform a PCR quote over the nonce (writes ${quote} / ${quote-sig})
:quoted
quote ${nonce} || goto bootvars
chain --autofree https://mgmt.example.com/boot-vars?mac=${mac}&hostname=${hostname}&nonce=${nonce}&quote=${quote}&quote_sig=${quote-sig} \
    || goto retry
goto vars-done

# 3. If authentication/TLS handshake fails, fetch again with the same nonce/quote, at most once
:retry
chain --autofree https://mgmt.example.com/boot-vars?mac=${mac}&hostname=${hostname}&nonce=${nonce}&quote=${quote}&quote_sig=${quote-sig} \
    || goto bootvars
goto vars-done

# Fallback path: no attestation, the control plane delivers no credentials
:bootvars
chain --autofree https://mgmt.example.com/boot-vars?mac=${mac}&hostname=${hostname} \
    || goto vars-done
```

Example control plane `/devices/challenge` response (an `#!ipxe` script body):

```ipxe
set nonce 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

### 6.3 HTTPS Asset Fetch and Boot (TOFU in Effect)

```ipxe
# First contact: the handshake is accepted by TOFU and the fingerprint lands in NVRAM; the certificate is pinned from then on
imgfetch --name vmlinuz \
    https://boot.example.com/assets/vmlinuz || goto fail
imgload vmlinuz || goto fail
chain vmlinuz initrd=initrd.img || goto fail
```

### 6.4 Status Query and TOFU Reset (Operations)

```ipxe
# Status query (produces no private key output)
isset ${ak-type} && echo "identity: ${ak-type} ${ak-name}" \
    || echo "identity: no TPM"
isset ${server-fingerprint} && echo "tofu: pinned" \
    || echo "tofu: not pinned"

# Show the fingerprint (can be compared with an independent openssl calculation)
show server-fingerprint

# ---- TOFU reset (sensitive; requires the management plane authorization flow, see §9) ----
nvclear
# Or an individual item as needed: NVO settings are encapsulated tags and require the nvo/ block prefix; a bare clear has no effect
# clear nvo/server-fingerprint # release the TOFU pin: the next https connection re-enters the registration window
```

The AK cannot be reset from here: replacing the AK requires deleting the control
plane registration and re-enrolling, or replacing the TPM.

### 6.5 Complete Boot Chain Reference Template

```ipxe
#!ipxe
# Complete device trust root boot chain (main repository reference template)

# Stage 0: network ready
dhcp || goto fail

# Stage 1: TPM identity (idempotent)
akgen || echo "identity: no TPM"

# Stage 2: identity export and registration report
akpub || goto report-fingerprint
chain --autofree \
    https://mgmt.example.com/devices/report?mac=${netX/mac}&ak_public=${ak-public}&ak_name=${ak-name}&ak_type=${ak-type}&sb=${sb} \
    || goto report-done
:report-fingerprint
chain --autofree https://mgmt.example.com/devices/report?mac=${netX/mac}&sb=${sb} ||
:report-done

# Stage 3: challenge-attestation to obtain boot credentials
:challenge
chain --autofree https://mgmt.example.com/devices/challenge?mac=${mac} \
    && goto quoted || goto bootvars
:quoted
quote ${nonce} || goto bootvars
chain --autofree \
    "https://mgmt.example.com/boot-vars?mac=${mac}&hostname=${hostname}&nonce=${nonce}&quote=${quote}&quote_sig=${quote-sig}" \
    || goto bootvars
# After the attestation passes, /boot-vars delivers the boot script (sets nbft-secret, kernel parameters, etc.)
:bootvars
chain --autofree https://mgmt.example.com/boot-vars?mac=${mac}&hostname=${hostname} \
    || goto fail

:fail
echo TRUSTROOT-BOOT-FAILED
```

## 7. Troubleshooting

| Symptom | Cause | Remedy |
|---|---|---|
| `akgen: No such device` | The platform has no TPM, or the firmware cannot obtain `EFI_TCG2_PROTOCOL` | Confirm the TPM is enabled in the firmware and its settings; handle TPM-less devices through the no_tpm path |
| `akgen: Input/output error` | The TPM rejects `CreatePrimary`/`EvictControl` (e.g. the handle is occupied) | Capture the TPM return code from the serial log; confirm `0x81000001` is not occupied by another object |
| `akgen: attestation key already present` | An AK already exists (normal idempotent path) | No action needed; replacing the AK requires administrator recovery (§2.1) |
| `akpub: no attestation key` | `akgen` has never run, or the TPM was cleared | Run `akgen` first |
| `quote: no attestation key` | Same as above | Same as above |
| `quote: nonce must be 1 to 64 bytes` | The nonce passed in is too long or empty | Use the 64 hex characters delivered by the control plane |
| `${ak-public}` / `${quote}` empty | The command failed or the setting was not written | Check the command output; these settings are valid only within the same boot |
| Control plane reports `quote_invalid` | The quote structure/signature/`ak_type` does not match | Re-verify locally with `test/verify-ak-quote.py` |
| Control plane reports `nonce_invalid` | The nonce expired or was already consumed (replay) | Request a new challenge; do not reuse a quote |
| Control plane reports `pcr_mismatch` | The PCR 0/2/4/7 digest differs from the baseline (firmware/Secure Boot configuration change) | Confirm the platform change; an administrator can approve a new baseline |
| Control plane reports `no_tpm` | The report carried no valid AK | Confirm the TPM is available and `akpub` succeeded |
| Control plane reports `sb_disabled` | The device self-reported `sb=0`, and new devices require Secure Boot | Enable Secure Boot and re-enrol the device |
| HTTPS fetch rejected (`TOFU-FETCH-FAIL` class of symptom) | The server certificate does not match the fingerprint pinned in NVRAM | Confirm the server certificate has not been rotated; if rotation is required, reset the NVRAM fingerprint |
| Access to a second HTTPS host rejected | Pinning is a single global anchor: the firmware only trusts the certificate pinned by the first https connection | Unify the HTTPS ingress/certificate and send other traffic over TFTP/HTTP (see §4) |
| TLS handshake fails | Server TLS > 1.2, or the cipher suite is unsupported | Restrict the server to `TLS ≤ 1.2` (see the cipher suite list in [test/https-server.py](../../test/https-server.py)) |
| Fingerprint still present after `clear server-fingerprint` | A bare `clear`/`set` has no effect on NVS encapsulated tags | Use `clear nvo/server-fingerprint` (block prefix, see §6.4) or `nvclear` (§2.4) |
| `nvclear` reports `not present` | The item was already empty | Normal, no action needed |
| `nvclear` reports `could not clear` / last line `incomplete` | Backend write failure (EFI `SetVariable` error) | Capture the serial log for the specific errno; check NVRAM space and read-only policy |
| After clearing, a reboot brings the setting back | Older firmware issues no write when an option block length drops to zero (`nvo_save` no-op) | Upgrade to firmware containing that fix from patch 0006; accept with `test/run-qemu-nvclear.sh` |

## 8. Verification and Test Assets (Inside the Firmware Repository)

- `test/ak-test.ipxe` + `test/run-qemu-ak.sh`: two-round AK self-test (round 1
  creates the AK on a fresh swtpm state; round 2 still reuses the same AK after
  `--clean-nvram` wipes the OVMF variables); `--no-tpm` verifies that the three
  commands fail without a TPM but do not crash.
- `test/ak-e2e.ipxe`: connects to a running control plane and walks the complete
  attestation chain report → challenge → `quote` → `/boot-vars`.
- `test/verify-ak-quote.py`: standalone verifier that checks the quote structure,
  `extraData` against the nonce, the PCR selection, the signature and
  (optionally) the baseline.
- `test/tofu-test.ipxe` + `test/run-qemu-tofu.sh`: three-round TOFU verification
  (first contact accepted + fingerprint persisted → download with matching
  fingerprint → certificate replacement rejected).
- `test/https-server.py`: TLS 1.2 HTTPS test endpoint (implemented with the Python
  standard library, with cipher suites compatible with iPXE).
- `test/dump-nvram.py`: inspection of OVMF NVRAM variable contents (verifies that
  the persisted fingerprint bytes match an independent openssl calculation).
- `test/nvs-clear.ipxe` + `test/run-qemu-nvclear.sh`: three-round `nvclear`
  verification (write two items → clear → read back; absence of both items on the
  third boot proves the clearing was persisted).

## 9. Security Boundaries

- **The AK private key never leaves the TPM**: the firmware does not generate,
  read or export it; the exported material is only the public key, TPM2B_NAME,
  quote and signature.
- **Replay protection for attestation depends on the nonce**: the control plane
  must guarantee a one-time nonce, a short TTL and binding to the MAC; the quote
  covers PCRs 0/2/4/7 and does not cover runtime state.
- **The AK cannot be overwritten**: the firmware has no rebuild path; replacing
  the AK requires deleting the registration and re-enrolling, or replacing/clearing
  the TPM.
- **TOFU trust anchor**: first contact is unauthenticated—the man-in-the-middle
  risk inside the registration window is borne by deployment network isolation;
  once pinned, integrity verification is in place.
- **`sb` is a self-reported value**: the control plane uses it only to admit
  registration; boot-time admission is based on TPM attestation and does not trust
  self-reporting.
- **Production endpoint constraints**: `/devices/report`, `/devices/challenge` and
  `/boot-vars` should sit on a controlled internal network with rate limiting; the
  firmware side has no additional encryption layer.
- **Reset authorization**: `nvclear` (clears the TOFU state) and
  `clear nvo/server-fingerprint` (releases the pin and reopens the registration
  window) are both sensitive operations and should only be triggered by a
  management plane authorization flow (e.g. a dedicated reset script delivered by
  the control plane).

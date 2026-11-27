# Firmware Interface Contract

[English](interface.md) | [中文](../zh/interface.md)

This page is the single contract between the firmware and the Kurrent control
plane. It lists what the firmware sends and consumes; implementation detail
lives in the patch chain and the archive.

## Boot chain

Default firmware (`embed/auto.ipxe`):

```
dhcp → chain tftp://${next-server}/boot.ipxe
```

`next-server` is provided by DHCP and, in a co-located deployment, is the
control plane address. Everything after `boot.ipxe` is served by the control
plane, so the firmware embeds no business scripts.

Secure Boot firmware (`embed/secureboot/`): `auto.ipxe` chains the embedded
`sb-boot.ipxe.cfg` (key-enrollment gate + TPM attestation flow) and
`sb-menu.ipxe` (NVMe-oF system boot, shell, reboot, exit).

## Control plane endpoints

All endpoints below are anonymous and rate-limited; they are read-only with
respect to registration (registration happens only during a window, through
`/devices/report`).

| Endpoint | Request | Response |
|---|---|---|
| `GET /boot/phase` | — | `#!ipxe` body running `sbenroll` when a platform registration window is open; empty body otherwise |
| `GET /devices/enroll-report` | `mac`, `result` | consumed after `sbenroll` |
| `GET /devices/report` | see below | empty `#!ipxe` body |
| `GET /devices/challenge` | `mac` | `#!ipxe` body `set nonce <64 hex>` |
| `GET /boot-vars` | see below | `#!ipxe` body setting boot variables (`?format=json` returns JSON) |

### `GET /devices/report`

Firmware device reporting (patch 0004 + TPM identity):

```
mac, uuid, manufacturer, product, serial, cpumodel,
mem-total, mem-type, mem-speed, chip, busid,
ak_public, ak_name, ak_type, sb
```

`mem-total` / `mem-type` / `mem-speed` come from SMBIOS type 17; `chip` is the
PCI NIC device name (`${net0/chip}`). `ak_public` / `ak_name` / `ak_type` are
the TPM attestation key identity and `sb` is the EFI Secure Boot state (`1`/`0`).

### `GET /boot-vars`

```
mac, hostname, nonce, quote, quote_sig
```

Identification is `mac → device ledger → bound worker`; `hostname` is only a
lookup fallback, never the identity for the data plane. The credential
variables are released only after the TPM quote over the issued nonce verifies;
without them the response carries only the menu variables.

Variables set by the response body:

| Variable | Meaning |
|---|---|
| `disk-nqn` | full NVMe subsystem NQN of the default disk |
| `base-iqn` | iSCSI base prefix derived from the disk IQN (for `initiator-iqn`) |
| `storager-ip` | storage node data-plane address |
| `iscsi-sep` | iSCSI root connector (`:::1:` for stgt, `::::` for LIO); nvmet only |
| `hostnqn` | host NQN override for the firmware connection |
| `nbft-secret` | DH-HMAC-CHAP key (`DHHC-1:…`) |
| `nbft-tls-psk` | TLS 1.3 PSK (64 hex), derived from the auth key |
| `nbft-tls-port` | NVMe/TCP TLS data-plane port |
| `os`, `os-version` | default system label for the menu |
| `menu-default`, `menu-timeout` | menu behavior |

## TPM attestation

The firmware creates an attestation key inside the TPM (`TPM2_CreatePrimary`,
attributes `restricted | sign`, persistent at `0x81000001`; ECC P-256 preferred,
RSA-2048 fallback). There is no software fallback: without a TPM the commands
fail with `-ENODEV` / `-ENOENT`.

| Command | Result |
|---|---|
| `akgen` | create or report the existing key |
| `akpub` | export `ak-public`, `ak-name`, `ak-type`, `sb` |
| `quote <nonce>` | one `TPM2_Quote` over PCR 0/2/4/7, exporting `quote` and `quote-sig` |
| `nvclear` | clear `server-fingerprint` and `trust` from non-volatile storage |

The six attestation settings are exposed as DHCP tags 0x60-0x65 for the current
boot only; `sbenroll` publishes `sbenroll-result` as tag 0x66.

## NVMe-oF connection

URI form:

```
nvme://<traddr>:<trsvcid>/<nqn>[?secret=<DHHC-1 key>][&tls_psk=<hex>][&tls_trsvcid=<port>]
```

When the URI port equals `tls_trsvcid`, the firmware performs a TLS 1.3 PSK
handshake on that connection (identity `NVMe0R01 <hostnqn> <subsysnqn>`);
otherwise the connection is plaintext, which is only used by the local test
targets. Production uses the single TLS port; a missing port or key means the
control plane does not provision the boot variables, and there is no plaintext
fallback.

## NBCT credential handoff

For authenticated boot, the firmware installs an in-memory ACPI table signed
`NBCT` carrying, per session, `traddr` / `trsvcid` / `nqn` / `hostnqn` /
`secret` / `tls_trsvcid` / `tls_psk`. The initramfs seed module
(`initramfs-nbft/nbft-connect`) reads it and reconnects with
`nvme connect --dhchap-secret` or `--tls`, so the kernel stage never fetches
credentials over the network a second time.

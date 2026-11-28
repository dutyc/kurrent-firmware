#!/usr/bin/env python3
"""Generate a minimal NBFT (NVMe Boot Firmware Table) ACPI binary.

Layout follows NVMe Boot Spec rev 1.0/1.1 structures as parsed by
libnvme (src/nvme/nbft.c + nvme-types-nbft.h):

    Header (64B) + Control (64B) + Host (32B) + HFI (128B)
    + SSNS (128B) + [heap range] HFI Transport Info TCP (128B) + strings

Notes on constraints learned from libnvme's parser (nbft.c):
  - Byte 9 of the header is the Minor Revision (must be 0), NOT the
    ACPI checksum byte; libnvme instead verifies that the whole table
    sums to zero (csum()), so a trailing pad byte absorbs the checksum.
  - HFI/SSNS descriptors are fixed 128 bytes (spec includes IP fields).
  - Every referenced object (including the HFI trinfo descriptor) must
    lie within [heap_offset, heap_offset + heap_length), so the heap
    range starts at the TRINFO descriptor.
  - secondary_hfi_assoc_obj must have length > 0 (length 0 fails the
    get_heap_obj() call), so an empty (zero) 1-byte object is provided.

The table is injected into QEMU with `-acpitable file=...` to simulate
the firmware-generated NBFT that iPXE will later install via
EFI_ACPI_TABLE_PROTOCOL (the gap this tool fills for the pre-iPXE phase).

Usage:
    python3 test/manual/nbft/gen-nbft-table.py [--mac 52:54:00:12:34:56] \
        [--traddr 10.0.2.2] [--trsvcid 4420] \
        [--nqn nqn.2026-07.com.kurrent:test] \
        [--host-nqn nqn.2014-08.org.ipxe:ipxe] \
        [--out diag/nbft-qemu.bin]

No root required; the generated table is verified by re-parsing it.
"""

import argparse
import socket
import struct
import sys

# NBFT descriptor structure ids (nbft_desc_type)
DESC_CONTROL, DESC_HOST, DESC_HFI, DESC_SSNS = 1, 2, 3, 4
DESC_HFI_TRINFO = 7
TRTYPE_TCP = 3

# Offsets (all structures are fixed-size, packed, 8-byte aligned)
OFF_HEADER = 0x00
OFF_CONTROL = 0x40
OFF_HOST = 0x80
OFF_HFI = 0xA0
OFF_SSNS = 0x120
OFF_HFI_TRINFO = 0x1A0
# The heap range starts at the TRINFO descriptor: libnvme's in_heap()
# requires every referenced object (strings, trinfo, ...) to live within
# [heap_offset, heap_offset + heap_length).
OFF_HEAP = 0x1A0

SZ_HEADER = 64
SZ_CONTROL = 64
SZ_HOST = 32
SZ_HFI = 128
SZ_HFI_TRINFO = 128
SZ_SSNS = 128

# Strings follow the TRINFO descriptor inside the heap range.
OFF_STRINGS = OFF_HEAP + SZ_HFI_TRINFO


def hdr(length: int, heap_offset: int, heap_length: int) -> bytes:
    b = bytearray(SZ_HEADER)
    b[0:4] = b"NBFT"
    struct.pack_into("<I", b, 4, length)
    b[8] = 1                     # major revision
    # NBFT spec: byte 9 is the Minor Revision (must be 0), NOT the ACPI
    # checksum byte.  libnvme verifies that the WHOLE table sums to zero
    # instead, which the trailing pad byte in main() absorbs.
    b[9] = 0                     # minor revision
    b[10:16] = b"IPXE  "         # oem_id
    b[16:24] = b"IPXENBFT"       # oem_table_id
    struct.pack_into("<I", b, 24, 1)   # oem_revision
    struct.pack_into("<I", b, 28, 0x49505845)  # creator_id "IPXE" LE
    struct.pack_into("<I", b, 32, 1)   # creator_revision
    struct.pack_into("<I", b, 36, heap_offset)
    struct.pack_into("<I", b, 40, heap_length)
    # driver_dev_path_sig (16B) + reserved (4B): zero (absent)
    return bytes(b)


def control(hfio, hfil, ssnso, ssnsl) -> bytes:
    b = bytearray(SZ_CONTROL)
    b[0] = DESC_CONTROL
    b[1], b[2] = 1, 0           # major/minor revision
    struct.pack_into("<H", b, 4, SZ_CONTROL)   # csl
    b[6] = 1                    # flags: VALID
    struct.pack_into("<I", b, 8, OFF_HOST)     # hdesc.offset
    struct.pack_into("<H", b, 12, SZ_HOST)     # hdesc.length
    b[14] = 1                   # hsv
    struct.pack_into("<I", b, 16, hfio)        # hfio
    struct.pack_into("<H", b, 20, hfil)        # hfil
    b[22], b[23] = 1, 1         # hfiv, num_hfi
    struct.pack_into("<I", b, 24, ssnso)       # ssnso
    struct.pack_into("<H", b, 28, ssnsl)       # ssnsl
    b[30], b[31] = 1, 1         # ssnsv, num_ssns
    # seco/secl/secv/num_sec/disco/discl/discv/num_disc: zero (absent)
    return bytes(b)


def host(host_nqn_obj) -> bytes:
    b = bytearray(SZ_HOST)
    b[0] = DESC_HOST
    b[1] = 0x07                 # flags: VALID | HOSTID_CONFIGURED | HOSTNQN_CONFIGURED
    # Fixed host id (test environment; iPXE in QEMU has no SMBIOS UUID).
    # First byte MUST NOT be 0x00: nvme-cli's discover_from_nbft() gates the
    # host_id on `*nbft->host.id` (first byte), so 00.. values are treated as
    # "no host id" and the kernel falls back to its default host, which
    # collides with nvmf_default_host (same hostid, different hostnqn) and
    # fails with -EINVAL ("found same hostid ... but different hostnqn").
    b[2:18] = bytes.fromhex("123456789abcdef0123456789abcdef0")
    struct.pack_into("<I", b, 18, host_nqn_obj[0])
    struct.pack_into("<H", b, 22, host_nqn_obj[1])
    return bytes(b)


def hfi(trinfo_obj) -> bytes:
    b = bytearray(SZ_HFI)       # 128B per spec (libnvme reads fields at
                                # spec offsets; length matters for in_heap)
    b[0] = DESC_HFI
    b[1] = 1                    # index
    b[2] = 1                    # flags: VALID
    b[3] = TRTYPE_TCP
    # pci_sbdf: zero
    struct.pack_into("<I", b, 16, trinfo_obj[0])
    struct.pack_into("<H", b, 20, trinfo_obj[1])
    b[22] = 1                   # hfi spec version
    # vlan/ip_origin/ip addresses etc: zero (all in the TRINFO descriptor)
    return bytes(b)


def hfi_trinfo(mac: bytes, ip: str) -> bytes:
    b = bytearray(SZ_HFI_TRINFO)
    b[0] = DESC_HFI_TRINFO
    b[1] = 1                    # version
    b[2] = TRTYPE_TCP
    b[3] = 2                    # trinfo_version (rev 1.1)
    struct.pack_into("<H", b, 4, 1)   # hfi_index
    b[6] = 0x07                 # flags: VALID | GLOBAL_ROUTE | DHCP_OVERRIDE
    # NOTE: libnvme's nbft_hfi_info_tcp has NO reserved byte between flags
    # and pci_sbdf, so every field after flags sits one byte earlier than
    # the spec's offset table: pci_sbdf@7, mac@11, vlan@17, ip_origin@19,
    # ip_address@20...  (verified against `nvme nbft show` output)
    # pci_sbdf: zero
    b[11:17] = mac
    # vlan zero; ip_origin = 3 (DHCP)
    b[19] = 3
    # ip_address: the address DHCP assigns (UEFI firmware records the
    # leased address back into the table; nvme-cli passes it as
    # host_traddr, so an all-zero address would bind the NVMe/TCP socket
    # to "::" and fail with EAFNOSUPPORT).  IPv4-mapped IPv6 format.
    b[20:36] = b"\x00" * 10 + b"\xff\xff" + socket.inet_aton(ip)
    # subnet/gateway/dns/dhcp_server: zero (DHCP fills at runtime)
    return bytes(b)


def ssns(traddr_obj, trsvcid_obj, subsys_nqn_obj, sec_hfi_obj) -> bytes:
    b = bytearray(SZ_SSNS)      # 128B per spec
    b[0] = DESC_SSNS
    struct.pack_into("<H", b, 1, 1)   # index
    struct.pack_into("<H", b, 3, 1)   # flags: VALID
    b[5] = TRTYPE_TCP
    # trflags (6) zero, primary_discovery_ctrl_index (8) zero
    struct.pack_into("<I", b, 10, traddr_obj[0])
    struct.pack_into("<H", b, 14, traddr_obj[1])
    struct.pack_into("<I", b, 16, trsvcid_obj[0])
    struct.pack_into("<H", b, 20, trsvcid_obj[1])
    # subsys_port_id (22): zero
    struct.pack_into("<I", b, 24, 1)  # nsid
    # nidt (28) / nid (29-44): zero (absent)
    # security_desc_index (45): zero
    b[46] = 1                   # primary_hfi_desc_index
    # secondary_hfi_assoc_obj (48): empty object, length must be > 0 or
    # libnvme's get_heap_obj() fails the whole SSNS descriptor
    struct.pack_into("<I", b, 48, sec_hfi_obj[0])
    struct.pack_into("<H", b, 52, sec_hfi_obj[1])
    struct.pack_into("<I", b, 54, subsys_nqn_obj[0])
    struct.pack_into("<H", b, 58, subsys_nqn_obj[1])
    # ssns_extended_info_desc_obj (60) + reserved: zero
    return bytes(b)


def heap_add(heap: bytearray, s: str) -> tuple:
    """Append a NUL-terminated string (4-byte aligned), return (offset, len)."""
    while len(heap) % 4:
        heap.append(0)
    off = OFF_STRINGS + len(heap)   # strings start after the TRINFO descriptor
    data = s.encode() + b"\0"
    heap += data
    return off, len(data)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac", default="52:54:00:12:34:56")
    ap.add_argument("--traddr", default="10.0.2.2")
    ap.add_argument("--trsvcid", default="4420")
    ap.add_argument("--nqn", default="nqn.2026-07.com.kurrent:test")
    ap.add_argument("--host-nqn", default="nqn.2014-08.org.ipxe:ipxe")
    ap.add_argument("--hfi-ip", default="10.0.2.15")
    ap.add_argument("--out", default="diag/nbft-qemu.bin")
    args = ap.parse_args()

    mac = bytes(int(x, 16) for x in args.mac.split(":"))

    # Build heap strings first (offsets are absolute from table start)
    heap = bytearray()
    host_nqn_obj = heap_add(heap, args.host_nqn)
    # traddr is a BINARY IP address in the heap, not ASCII: libnvme's
    # read_ssns() passes the raw bytes to format_ip_addr() (inet_ntop on
    # 16 bytes), so IPv4 must be stored IPv4-mapped (::ffff:a.b.c.d).
    while len(heap) % 4:
        heap.append(0)
    traddr_off = OFF_STRINGS + len(heap)
    heap += b"\x00" * 10 + b"\xff\xff" + socket.inet_aton(args.traddr)
    traddr_obj = (traddr_off, 16)
    trsvcid_obj = heap_add(heap, args.trsvcid)
    subsys_nqn_obj = heap_add(heap, args.nqn)
    # Secondary-HFI association: libnvme's read_ssns() treats a nonzero-
    # length object as an index list and, for element 0, stores a NULL
    # hfis[] entry while still bumping num_hfis (its bug) -- the JSON
    # output then dereferences the NULL and crashes.  A single byte equal
    # to the primary HFI index (1) is skipped as a duplicate instead, so
    # num_hfis stays 1.  Built by hand: heap_add() would append a NUL,
    # making element 1 a zero that triggers the same bug.
    while len(heap) % 4:
        heap.append(0)
    sec_hfi_off = OFF_STRINGS + len(heap)
    heap.append(0x01)
    sec_hfi_obj = (sec_hfi_off, 1)

    table = bytearray()
    table += hdr(0, 0, 0)
    table += control(OFF_HFI, SZ_HFI, OFF_SSNS, SZ_SSNS)
    table += host(host_nqn_obj)
    table += hfi((OFF_HFI_TRINFO, SZ_HFI_TRINFO))
    table += ssns(traddr_obj, trsvcid_obj, subsys_nqn_obj, sec_hfi_obj)
    table += hfi_trinfo(mac, args.hfi_ip)    # inside the heap range (OFF_HEAP)
    table += heap

    # Fix header length/heap fields.  Byte 9 is the minor revision (0),
    # so the whole-table-zero checksum is absorbed by a trailing pad byte
    # (libnvme verifies csum(table) == 0; 4 bytes keep the length aligned).
    # Order matters: the pad must exist before the length fields are
    # written, and the checksum is computed after them (they affect it).
    table += bytearray(4)
    struct.pack_into("<I", table, 4, len(table))
    struct.pack_into("<I", table, 36, OFF_HEAP)
    struct.pack_into("<I", table, 40, len(table) - OFF_HEAP)
    table[-1] = (-sum(table)) & 0xFF

    with open(args.out, "wb") as f:
        f.write(table)
    print(f"NBFT table written: {args.out} ({len(table)} bytes)")

    # Self-verify: re-parse and print the fields that matter
    assert table[0:4] == b"NBFT"
    assert sum(table) % 256 == 0, "ACPI checksum invalid"
    hlen = struct.unpack_from("<I", table, 4)[0]
    assert hlen == len(table)
    print(f"  length={hlen} minor_revision=0x{table[9]:02x} (sum mod 256 = {sum(table) % 256})")
    print(f"  mac={args.mac} traddr={args.traddr}:{args.trsvcid} nqn={args.nqn}")
    print(f"  host_nqn={args.host_nqn} host_id=12345678-9abc-def0-1234-56789abcdef0")
    print(f"  hfi_ip={args.hfi_ip} (host_traddr for the NVMe/TCP socket)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

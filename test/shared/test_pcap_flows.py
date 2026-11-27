#!/usr/bin/env python3
"""Regression tests for test/shared/pcap-flows.py.

The analyzer must aggregate by TCP connection (SYN start, tuple reuse aware)
and must not treat mid-stream records after a sequence gap as a new flow.
Fixtures are generated in a temporary directory; no real capture is needed.

Run directly:  python3 test/shared/test_pcap_flows.py
Mutation check: PCAP_FLOWS=/tmp/old-pcap-flows.py python3 test/shared/test_pcap_flows.py
"""
import os
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.environ.get("PCAP_FLOWS", os.path.join(HERE, "pcap-flows.py"))
PORT = 4422
CLIENT = "10.0.0.2"
TARGET = "10.0.0.1"


def ip_bytes(addr):
    return bytes(int(x) for x in addr.split("."))


def tcp_packet(sport, seq, flags, payload=b"", dport=PORT):
    eth = b"\x02\x00\x00\x00\x00\x02" + b"\x02\x00\x00\x00\x00\x01" + b"\x08\x00"
    total = 20 + 20 + len(payload)
    ip = struct.pack(
        "!BBHHHBBH4s4s",
        0x45, 0, total, 0, 0x4000, 64, 6, 0,
        ip_bytes(CLIENT), ip_bytes(TARGET),
    )
    tcp = struct.pack(
        "!HHIIBBHHH",
        sport, dport, seq, 0, 5 << 4, flags, 65535, 0, 0,
    )
    return eth + ip + tcp + payload


def write_pcap(path, records):
    """records: list of (packet_bytes, incl_len_or_None)."""
    with open(path, "wb") as f:
        f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
        ts = 1
        for pkt, incl in records:
            if incl is None:
                incl = len(pkt)
            f.write(struct.pack("<IIII", ts, 0, incl, len(pkt)))
            f.write(pkt[:incl])
            ts += 1


def run_tool(path, *extra):
    return subprocess.run(
        [sys.executable, TOOL, path, "--port", str(PORT), *extra],
        capture_output=True, text=True,
    )


class PcapFlowsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def pcap(self, name, records):
        path = os.path.join(self.tmp.name, name)
        write_pcap(path, records)
        return path

    def test_gap_and_appdata_stay_one_tls_connection(self):
        path = self.pcap("gap.pcap", [
            (tcp_packet(40000, 1000, 0x02), None),
            (tcp_packet(40000, 1001, 0x18, b"\x16" + b"\x03\x03" + b"A" * 97), None),
            (tcp_packet(40000, 9000, 0x18, b"\x17" + b"B" * 49), None),
            (tcp_packet(40000, 9100, 0x18, b"\x30" + b"C" * 9), None),
        ])
        r = run_tool(path)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"client_connections_to_{PORT}=1", r.stdout)
        self.assertIn("conn1: sport=40000 first=0x16", r.stdout)
        self.assertIn("ALL_TLS_HANDSHAKE", r.stdout)

    def test_plaintext_first_payload_fails(self):
        path = self.pcap("plain.pcap", [
            (tcp_packet(40001, 1000, 0x02), None),
            (tcp_packet(40001, 1001, 0x18, b"\x17" + b"D" * 31), None),
        ])
        r = run_tool(path)
        self.assertEqual(r.returncode, 1)
        self.assertIn("NON_TLS_STREAM_PRESENT", r.stdout)
        self.assertIn("conn1: sport=40001 first=0x17", r.stdout)

    def test_tuple_reuse_with_new_syn_is_a_new_connection(self):
        path = self.pcap("reuse.pcap", [
            (tcp_packet(40002, 1000, 0x02), None),
            (tcp_packet(40002, 1001, 0x18, b"\x16" + b"E" * 63), None),
            (tcp_packet(40002, 7000, 0x02), None),
            (tcp_packet(40002, 7001, 0x18, b"\x16" + b"F" * 63), None),
        ])
        r = run_tool(path)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"client_connections_to_{PORT}=2", r.stdout)
        self.assertIn("conn1: sport=40002 first=0x16", r.stdout)
        self.assertIn("conn2: sport=40002 first=0x16", r.stdout)

    def test_retransmitted_syn_does_not_split(self):
        path = self.pcap("syn-retx.pcap", [
            (tcp_packet(40003, 1000, 0x02), None),
            (tcp_packet(40003, 1000, 0x02), None),
            (tcp_packet(40003, 1001, 0x18, b"\x16" + b"G" * 63), None),
        ])
        r = run_tool(path)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"client_connections_to_{PORT}=1", r.stdout)

    def test_truncated_packet_without_payload_does_not_crash(self):
        full = tcp_packet(40004, 1001, 0x18, b"\x16" + b"H" * 99)
        header_only = len(full) - 100          # IP/TCP headers, payload cut
        path = self.pcap("truncated.pcap", [
            (tcp_packet(40004, 1000, 0x02), None),
            (full, header_only),
            (tcp_packet(40004, 1101, 0x18, b"\x16" + b"I" * 63), None),
        ])
        r = run_tool(path)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"client_connections_to_{PORT}=1", r.stdout)
        self.assertIn("truncated_packets=1", r.stdout)
        self.assertIn("conn1: sport=40004 first=0x16", r.stdout)

    def test_mid_capture_without_syn_is_analyzed(self):
        ok = self.pcap("nosyn.pcap", [
            (tcp_packet(40005, 5000, 0x18, b"\x16" + b"J" * 63), None),
        ])
        r = run_tool(ok)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f"client_connections_to_{PORT}=1", r.stdout)

        bad = self.pcap("nosyn-plain.pcap", [
            (tcp_packet(40006, 5000, 0x18, b"\x17" + b"K" * 63), None),
        ])
        r = run_tool(bad)
        self.assertEqual(r.returncode, 1)
        self.assertIn("NON_TLS_STREAM_PRESENT", r.stdout)

    def test_marker_and_plaintext_port_criteria(self):
        secret = "DHHC-1:01:test-only-placeholder"
        path = self.pcap("markers.pcap", [
            (tcp_packet(40007, 1000, 0x02), None),
            (tcp_packet(40007, 1001, 0x18, b"\x16" + b"L" * 63), None),
            (tcp_packet(40008, 1, 0x18, secret.encode()),
             None),
            (tcp_packet(40009, 1, 0x18, b"nvme", dport=4420), None),
        ])
        r = run_tool(path, "--secret", secret)
        self.assertEqual(r.returncode, 1)
        self.assertIn("dhhc-secret", r.stdout)
        self.assertIn("packets_to_4420=1", r.stdout)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""分析冷启动抓包：客户端流首字节、明文凭据泄漏、明文端口流量。

用法:
  python3 test/shared/pcap-flows.py <pcap> [--port 4422] [--secret DHHC-1:..] [--psk HEX]

判据（NVMe/TCP TLS 验收）:
  - 每条到目标端口的客户端 TCP 流，首个载荷字节必须是 0x16（TLS handshake）；
  - --secret/--psk 给出的明文不得出现在任何 TCP 载荷中；
  - 到 --plain-port（默认 4420）的包数应为 0（生产单口收敛，无明文回退）。
只依赖标准库；pcap 需为经典格式（QEMU filter-dump 产物）。
"""
import argparse
import collections
import struct
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pcap")
    ap.add_argument("--port", type=int, default=4422)
    ap.add_argument("--plain-port", type=int, default=4420)
    ap.add_argument("--secret")
    ap.add_argument("--psk")
    args = ap.parse_args()

    markers = {}
    if args.secret:
        markers[args.secret.encode()] = "dhhc-secret"
    if args.psk:
        markers[args.psk.encode()] = "psk-hex"

    f = open(args.pcap, "rb")
    gh = f.read(24)
    if gh[:4] in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        endian = "<"
    elif gh[:4] in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        endian = ">"
    else:
        sys.exit("ERROR: 不是经典 pcap（filter-dump 产物）")

    flows = {}
    hits = collections.Counter()
    plain_pkts = 0
    packets = 0
    truncated = 0
    while True:
        h = f.read(16)
        if len(h) < 16:
            break
        _, _, incl, _ = struct.unpack(endian + "IIII", h)
        pkt = f.read(incl)
        packets += 1
        if len(pkt) < 34 or pkt[12:14] != b"\x08\x00":
            continue
        ip = pkt[14:]
        if ip[0] >> 4 != 4 or ip[9] != 6:
            continue
        ihl = (ip[0] & 0xF) * 4
        tcp = ip[ihl:]
        sport, dport = struct.unpack(">HH", tcp[:4])
        doff = (tcp[12] >> 4) * 4
        payload = tcp[doff:]
        # snaplen 截断时 incl_len < 原始 IP 长度：按 IP 总长推进 seq，
        # 否则每条包都被当成新流（PCAP_MAXLEN 场景）。
        ip_total = struct.unpack(">H", ip[2:4])[0]
        data_len = ip_total - ihl - doff
        if len(pkt) < 14 + ip_total:
            truncated += 1
        if dport == args.plain_port:
            plain_pkts += 1
        for marker, tag in markers.items():
            if marker in payload:
                hits[tag] += 1
        if dport != args.port or data_len <= 0:
            continue
        seq = struct.unpack(">I", tcp[4:8])[0]
        key = None
        for k, v in flows.items():
            if k[0] == sport and v["next"] == seq:
                key = k
                break
        if key is None:
            key = (sport, seq)
            flows[key] = {"first": payload[0], "bytes": 0, "next": seq}
        flows[key]["bytes"] += data_len
        flows[key]["next"] = seq + data_len

    print(f"packets={packets} client_flows_to_{args.port}={len(flows)}")
    for i, (k, v) in enumerate(flows.items(), 1):
        print(f"  flow{i}: sport={k[0]} first=0x{v['first']:02x} client_bytes={v['bytes']}")
    firsts = sorted({v["first"] for v in flows.values()})
    ok_tls = bool(firsts) and all(b == 0x16 for b in firsts)
    print("first_bytes=" + ",".join(f"0x{b:02x}" for b in firsts),
          "->", "ALL_TLS_HANDSHAKE" if ok_tls else "NON_TLS_STREAM_PRESENT")
    print("plaintext_markers=" + (str(dict(hits)) if hits else "none")
          + (" (partial: truncated packets)" if truncated else ""))
    print(f"packets_to_{args.plain_port}={plain_pkts} truncated_packets={truncated}")
    sys.exit(0 if ok_tls and not hits and plain_pkts == 0 else 1)


if __name__ == "__main__":
    main()

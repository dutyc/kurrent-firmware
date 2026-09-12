#!/usr/bin/env python3
"""QMP -> HMP sendkey 键盘注入(VM 无 serial/ssh 时的登录/装包通道)。

用法:
  golden-vm-sendkey.py [--sock S] --combo ctrl,alt,f3   # 组合键(切换 TTY)
  golden-vm-sendkey.py [--sock S] 'dutyc\\n'            # 逐键文本(\\n=回车)
支持: 小写字母/数字/空格/- . / = | : _ " ' 大写(shift) \\n(ret)
默认 socket: /tmp/golden-qmp.sock(与 golden-vm-run.sh 配对)
"""
import argparse
import json
import socket
import time

parser = argparse.ArgumentParser()
parser.add_argument("--sock", default="/tmp/golden-qmp.sock")
parser.add_argument("--combo", help="组合键, 逗号分隔 qcode(如 ctrl,alt,f3)")
parser.add_argument("text", nargs="?", default="", help="逐键注入的文本(\\n=回车)")
args = parser.parse_args()


def hmp(command_line):
    s = socket.socket(socket.AF_UNIX)
    s.connect(args.sock)
    f = s.makefile("rw")
    f.readline()  # greeting
    f.write('{"execute":"qmp_capabilities"}\n')
    f.flush()
    f.readline()
    f.write(json.dumps({"execute": "human-monitor-command",
                        "arguments": {"command-line": command_line}}) + "\n")
    f.flush()
    while True:
        line = f.readline()
        if '"return"' in line:
            s.close()
            return
        if '"error"' in line:
            s.close()
            raise RuntimeError(line.strip())


def char_combo(ch):
    special = {" ": "spc", "-": "minus", "=": "equal", ".": "dot", "/": "slash",
               "\\": "backslash", ",": "comma", ";": "semicolon"}
    if ch == "\n":
        return ["ret"]
    if ch in special:
        return [special[ch]]
    if ch == "|":
        return ["shift", "backslash"]
    if ch == ":":
        return ["shift", "semicolon"]
    if ch == "_":
        return ["shift", "minus"]
    if ch == '"':
        return ["shift", "apostrophe"]
    if ch == "'":
        return ["apostrophe"]
    if ch.isupper():
        return ["shift", ch.lower()]
    return [ch]


if args.combo:
    combo = args.combo.split(",")
    hmp("sendkey " + "-".join(combo))
    print(f"combo: {combo}")
else:
    for ch in args.text:
        combo = char_combo(ch)
        hmp("sendkey " + "-".join(combo))
        time.sleep(0.04)
    print(f"typed {len(args.text)} chars")

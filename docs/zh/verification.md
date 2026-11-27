# 验证

[English](../en/verification.md) | [中文](verification.md)

验证分两层：仓库门禁（无需环境）与隔离的宿主侧冷启动验收（QEMU/OVMF + nvmet
TLS 目标）。

## 仓库门禁

`test/ci-gates.sh` 运行 CI 与本地共享的检查：

```bash
bash test/ci-gates.sh syntax     # 每个受跟踪脚本的 bash -n / sh -n
bash test/ci-gates.sh shellcheck # ShellCheck error 级
bash test/ci-gates.sh embed      # 每个内嵌载荷与其源一致
bash test/ci-gates.sh boot       # initramfs TLS 接线（tlshd 配置、kTLS 密码）
bash test/ci-gates.sh pcap       # pcap 流聚合测试
bash test/ci-gates.sh replay     # 补丁 0001..0012 对固定基线重放
bash test/ci-gates.sh build      # 完整构建 + dist/SHA256SUMS
```

单测编入固件测试镜像并在 QEMU/OVMF 下运行：

```bash
make -C .cache/ipxe-upstream/src bin-x86_64-efi/tests.efi
```

全量套件在串口报告 `all 11762 tests passed`（`tls13` 110、`tls13conn` 27、
`nvmetcp` 101，加基线索）。

## 隔离冷启动验收

隔离桥不动生产 `br0/4421`：

```bash
sudo bash test/shared/fwtest-net.sh setup            # br-fwtest + tap0fw
sudo bash test/shared/fwtest-nvmet-tls.sh setup <raw> <subnqn> <hostnqn> <DHHC> \
      192.168.81.1 4422 3                            # tls1.3 / required
TRSVCID=4422 bash test/shared/fwtest-boot.sh --nqn <subnqn> \
     --secret '<DHHC-1:..>' --psk <hex> --serial diag/x.serial --pcap diag/x.pcap
python3 test/shared/pcap-flows.py diag/x.pcap --port 4422 --secret '<DHHC-1:..>' --psk <hex>
```

通过判据：串口出现 `login:`；目标 dmesg 出现两行
`nvmet: Created nvm controller … , TLS.`；抓包脚本报告 `ALL_TLS_HANDSHAKE`、
`plaintext_markers=none`、`packets_to_4420=0`。

各发行版的历史验收记录（pcap、串口日志与验证说明）保留在
`docs/zh/archive/` 中。

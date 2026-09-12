#!/bin/bash
# golden-nvmet-enable.sh - 在宿主 mount namespace 下启用 nvmet namespace(指向母盘 raw)
# 用法: sudo bash golden-nvmet-enable.sh <raw-img> [子系统NQN]
# 说明:
#   - enable 的 backing file open 发生在调用者进程的 mount namespace:必须用宿主 ns
#     (docker exec 进容器写会因容器看不到 /run/media 路径而 -2 失败,kern.log 指纹:
#      "nvmet: failed to open block device <路径>: (-2)")
#   - open 成功后 IO 由内核线程执行,不再受 ns 影响
set -e

IMG=${1:?用法: golden-nvmet-enable.sh <raw-img> [子系统NQN]}
NQN=${2:-nqn.2026-07.com.kurrent:worker-01.debian.ec8d921633bb}
NS=/sys/kernel/config/nvmet/subsystems/$NQN/namespaces/1

[ "$(id -u)" = 0 ] || { echo "ERROR: 请以 root 运行"; exit 1; }
[ -f "$IMG" ] || { echo "ERROR: 缺少 $IMG"; exit 1; }
[ -d "$NS" ] || { echo "ERROR: namespace 目录不存在($NS)"; exit 1; }

# 幂等: 先 disable(换盘场景),再写 device_path 并重新 enable
# (enable 状态下 device_path 不可写)
echo 0 > "$NS/enable" 2>/dev/null || true
echo -n "$IMG" > "$NS/device_path"
echo 1 > "$NS/enable"
echo "enable OK"
echo "device_path: $(cat "$NS/device_path")"

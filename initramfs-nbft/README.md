# initramfs-nbft — NBFT 消费模块（种子实现）

Debian 系（initramfs-tools）的 NBFT（NVMe Boot Firmware Table）消费模块。
**种子定位**：实现仅供参考与上游提案，目标是由各发行版官方包自行纳入
（iBFT 先例：open-iscsi 包自带 `local-top/iscsi` + `iscsi_auto`，Debian/Ubuntu
同源继承，上游一处维护）。

## 组件结构

```
nbft-connect                    核心脚本（框架无关，POSIX sh）
initramfs/hooks/nbft           initramfs-tools hook（打包依赖 + 模块）
initramfs/scripts/local-top/nbft  initramfs-tools local-top（网络 + 连接）
```

设计对齐：

- SUSE dracut `95nvmf`（thirdparty/dracut/modules.d/95nvmf/）：NBFT 消费逻辑
  （`nvme nbft show -o json` 解析、DHCP/静态判定、VLAN）
- open-iscsi `local-top/iscsi`（/usr/share/initramfs-tools/）：initramfs-tools
  集成形态（`iscsi_auto` 开关、`/run/net-*.conf` 写法、configure_networking）
- nvme-cli 上游 `nvmf-autoconnect/`（thirdparty/nvme-cli/）：连接命令
  `nvme connect-all --nbft` 与 `nbft*` 接口命名生态

## 工作原理

内核启动参数 `nbft_auto`（对齐 `iscsi_auto`）启用自动消费：

1. 检测 ACPI 表 `/sys/firmware/acpi/tables/NBFT*`（内核已导出）
2. `nvme nbft show -H -o json` 解析（libnvme），逐 HFI 生成记录：
   MAC → 内核接口名（/sys/class/net 匹配）、DHCP/静态判定、VLAN、地址
3. 网络应用：DHCP 交 `configure_networking`（dhcpcd/ipconfig）；静态手动应用
   + 写 `/run/net-<iface>.conf`（标记网络就绪，与 ipconfig/dhcpcd 同格式）
4. 连接 NVMe-oF 子系统：检测固件注入的 NBCT 凭证表
   （`/sys/firmware/acpi/tables/NBCT*`，见 `patches/0012`）——存在则逐条
   `nvme connect` 并附加 `--dhchap-secret`/`--hostnqn`（密钥不落盘、仅随引导
   会话存活，避免内核侧二次 HTTP 取凭证）；无 NBCT 表时回退
   `nvme connect-all --nbft`（nvme-cli 2.5+；旧版自动降级 `connect-nbft`）

## 母盘安装（一次定制，克隆即用）

```sh
# 1. 安装依赖
sudo apt install nvme-cli jq

# 2. 部署种子组件
sudo install -m 0755 nbft-connect /usr/local/sbin/
sudo install -m 0755 initramfs/hooks/nbft /usr/share/initramfs-tools/hooks/
sudo install -m 0755 initramfs/scripts/local-top/nbft \
    /usr/share/initramfs-tools/scripts/local-top/

# 3. GRUB 加启动参数（追加到 GRUB_CMDLINE_LINUX_DEFAULT）
#    ip=dhcp nbft_auto
#    静态场景：ip=<addr>::<gw>:<prefix>:<host>:<iface>:off
sudo update-grub && sudo update-initramfs -u
```

可选：`/etc/initramfs-tools/conf.d/nvme-cli` 写 `NO_NBFT_IN_INITRAMFS=yes`
可在打包时禁用（对齐 open-iscsi 的 `NO_ISCSI_IN_INITRAMFS`）。

## 测试

```sh
# 语法 + 辅助函数自检（无需 NBFT 表；NBCT 解析用合成表验证）
sh -n nbft-connect initramfs/hooks/nbft initramfs/scripts/local-top/nbft
./nbft-connect --selftest

# mock 驱动单测：NBCT 逐条 connect（带/不带密钥）、NBFT 回退、坏条目跳过
bash ../test/test-nbft-connect-nbct.sh

# mock 解析测试（无 NBFT 表环境）
# 见 diag/tmp/nbft-test/bin/nvme 的 mock（SUSE 95nvmf 样例 JSON 形态）
PATH=<mock-bin>:$PATH NBFT_SYSFS_PATH=<mock-firmware> ./nbft-connect --entries
```

全链路验证（QEMU + nvmet + 装有本模块的 initramfs）见仓库验证记录。

注意：`nbft-connect` 须以 dash/ash 运行（initramfs 默认 `/bin/sh`）——NBCT
字段提取依赖命令替换在首个 NUL 字节截断的语义，bash 4.4+ 会保留 NUL 导致
空字段误判。

## 上游纳入路径（种子退役条件）

- **主路径**：随 nvme-cli（linux-nvme）打包 initramfs 集成——仿 open-iscsi
  的打包形态（hooks/scripts 随应用包安装到 /usr/share/initramfs-tools/）。
  nvme-cli 上游已含用户态组件（nvmf-autoconnect：systemd units、
  65-persistent-net-nbft.rules），缺的正是 initramfs-tools 集成。
- **并行**：SUSE dracut 95nvmf NBFT 扩展上游化到 dracut-ng（覆盖 dracut 系
  发行版），本种子逻辑与其一致可交叉验证。
- **退役条件**：任一发行版官方包纳入后，薄适配层退役，核心脚本并入官方包。

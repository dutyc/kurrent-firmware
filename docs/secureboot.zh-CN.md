# Secure Boot 引导配置

[English](secureboot.md) | [中文](secureboot.zh-CN.md)

这是**可选**的构建配置。默认的 L1 固件（网络边界 + TOFU）保持不变；`build/build.sh` 从不应用 `patches/secureboot/` 中的任何内容。

## 变更内容

| 层面 | L1（默认） | Secure Boot 配置 |
|---|---|---|
| 首段代码 | 经 TFTP/USB 下发的未经验证 EFI 二进制 | 经签名的 `snponly-sb.efi`，由 UEFI `db` 验证 |
| 引导脚本 | 经 TFTP 下发 `auto.ipxe`，随后走 HTTPS | 内嵌于已签名二进制中的三份静态脚本 |
| 服务器身份 | 首次接触时 TOFU，此后固定叶证书 | 引导 CA 证书与指纹内嵌于固件 |
| 443 管理入口 | 不变 | 不变（该配置使用独立的引导 HTTPS 端口） |
| 设备身份 | `akgen` / `akpub` / `report` / `challenge` / `quote` | 同一套 TPM 证明流程，在签名代码内执行 |

静态脚本为：

```
auto.ipxe          dhcp -> chain sb-boot.ipxe.cfg -> chain sb-menu.ipxe
sb-boot.ipxe.cfg   端点 + 密钥注册门控（boot/phase）+ TPM 证明流程
sb-menu.ipxe       NVMe-oF 系统启动、shell、重启、退出
```

TFTP 或 DHCP 仍可替换控制器地址或造成拒绝服务，但无法注入未签名代码或其他服务器证书。

## 信任链

```
UEFI db：产物签名证书
  └─ snponly-sb.efi（sbsign）
       ├─ auto.ipxe + sb-boot.ipxe.cfg + sb-menu.ipxe
       ├─ 内嵌的引导 CA 证书及其 SHA-256 指纹
       ├─ TPM：证明密钥（0x81000001）+ PCR 0/2/4/7 引用（quote）
       └─ 至引导端点的 HTTPS
            ├─ /devices/report
            ├─ /devices/challenge
            ├─ /boot-vars
            └─ /file/...（操作系统资产）
```

两个相互独立的锚点：

- **平台锚点**——UEFI `db` 中的产物签名证书。
- **网络锚点**——内嵌于二进制中的引导 CA。

`TRUST=<boot-ca.pem>` 固定指纹。`CERT=<boot-ca.pem>` 内嵌证书本身，以便在 TLS 服务器不下发根证书时（通常情况）仍能构建证书链。二者均为必需；仅有指纹无法验证服务器叶证书的签名。

`patches/secureboot/0001-no-tofu.patch` 覆盖层在本构建中禁用 TOFU。缺少该覆盖层时，错误 CA 的握手会在首次接触时被接受并被固定，从而使固定 CA 失效。

## 构建

依赖：`sbsign`、`sbverify`、`openssl`、`python3`、`realpath`，以及常规工具链。

```bash
SB_KEY=/secure/offline/artifact-signing.key \
SB_CERT=/secure/offline/artifact-signing.crt \
BOOT_CA_CERT=/secure/boot-ca.crt \
BOOT_HTTPS_PORT=4443 \
./build/build-sb.sh
```

| 变量 | 含义 |
|---|---|
| `SB_KEY`, `SB_CERT` | 产物签名私钥/证书；离线保存，不得进入仓库或容器。构建切换目录前会规范化路径 |
| `SB_PK_KEY`, `SB_PK_CERT`, `SB_KEK_KEY`, `SB_KEK_CERT` | 可选的注册密钥材料。四项全部设置时，`build/sbenroll-gen.py` 会签名 PK/KEK/db 描述符并将其内嵌；否则 `sbenroll` 报告 `failed`。只有证书与签名进入镜像 |
| `SB_MS_UEFI_CA_CERT` | 加入 db 的 Microsoft UEFI CA 2011 证书（默认 `build/certs/MicrosoftUEFI-CA-2011.pem`） |
| `SB_OWNER_GUID` | 内嵌签名列表中使用的签名所有者 GUID |
| `BOOT_CA_CERT` | PEM 格式的引导 CA，`basicConstraints CA:TRUE`；以证书与指纹两种形式内嵌 |
| `BOOT_HTTPS_PORT` | 内嵌于镜像的引导端点端口（默认 `4443`，范围 1-65535） |
| `CONTROLLER_IP` | 固定的控制器 IPv4 地址；默认取 DHCP `next-server`。IPv6 字面量被拒绝 |
| `KURRENT_SB_TARGET` | UEFI 构建目标：`snponly`（默认）或 `ipxe`（全驱动首跳）。产物命名为 `<target>-sb.efi` |
| `KURRENT_SB_SRC_DIR` | 源码缓存；默认 `.cache/ipxe-sb` |
| `KURRENT_SB_OUT_DIR` | 输出目录；默认 `dist/secureboot` |
| `KURRENT_SB_ALLOW_CUSTOM_OUT` | 设为 `1` 时允许删除 `dist/` 之外的输出目录 |
| `UPSTREAM_COMMIT`, `JOBS` | 与常规构建含义相同 |

Secure Boot 构建使用独立的源码缓存 `.cache/ipxe-sb`，与 L1 缓存 `.cache/ipxe-upstream` 相互独立。两者持有相同的上游基线，但只有 Secure Boot 缓存会应用 TOFU 覆盖层，因此 L1 构建不会误拾取它。

Secure Boot 缓存与 `dist/secureboot/` 在使用前会被重置。仅当其 `origin` 远端等于 `UPSTREAM_URL` 时才接受 `.cache/` 之外的自定义源码目录；`dist/` 之外的自定义输出目录需要 `KURRENT_SB_ALLOW_CUSTOM_OUT=1`。

输出：

```
dist/secureboot/
  snponly-sb.efi
  pxe-uefi/snponly-sb.efi
  direct-uefi/snponly-sb.efi
  manifest.json
  SHA256SUMS
```

以上为默认 `snponly` 目标的列表；`KURRENT_SB_TARGET=ipxe` 以相同布局产出 `ipxe-sb.efi`。两个目录副本与根产物逐字节一致：同一份已签名二进制分别以 PXE 与直接引导布局交付，使使用方可以采用统一的路径约定。

`manifest.json` 记录产物哈希与大小、签名者主题、引导 CA 的 SHA-256、端口与上游基线。`verify-sb.sh` 校验每个签名、校验清单、清单一致性（产物哈希/大小、签名者主题、`tofu == false`，以及在给出第三个参数时的引导 CA 指纹），确认未混入未签名的 `.efi`，并确认输出中不含任何密钥或 PEM 文件：

```bash
./tools/verify-sb.sh /secure/offline/artifact-signing.crt
./tools/verify-sb.sh /secure/offline/artifact-signing.crt dist/secureboot /secure/boot-ca.crt
```

## 服务端要求

- 引导 HTTPS 端点必须出示由引导 CA 签发的证书，其 SAN 与 DHCP 或 `CONTROLLER_IP` 所使用的控制器地址匹配。
- 该端口只应暴露引导端点。管理入口保持在 443 及其现有证书上；替换该证书会破坏已固定旧叶证书的 L1 设备。
- 引导 CA 与管理 CA、节点 CA 相互独立。轮换引导 CA 需要重新构建并重新刷写固件。

## 置备

1. 通过 USB、BMC 虚拟介质/Redfish 或固件密钥管理界面，将产物签名证书写入 UEFI `db`。
2. 启用 Secure Boot 并禁用 CSM。
3. 从本地介质或经 PXE 路径引导已签名产物。

固件更新可能清空 `db`；此类更新后需重新导入产物签名证书。签名密钥丢失的机器按以下方式恢复：清空 `db` 并重新刷写新的已签名产物；引导 CA 不存在在线吊销路径。

PXE 网络引导栈并非全部校验所下载的 NBP。当平台已知会跳过该项校验时，使用本地介质或固件 HTTP Boot 路径。

## 验证

正常路径：已签名产物被 OVMF Secure Boot 接受，内嵌脚本执行，`/devices/report` 与 `/boot-vars` 经固定端点成功，菜单出现。

注册路径：在全新变量存储（Setup Mode）且注册窗口开启时，`/boot/phase` 返回执行 `sbenroll`（PK/KEK/db）的脚本，上报 `sbenroll-result` 并重启。重启后的镜像以新安装的 db 验签，上报 `sb=1`，下一次阶段拉取返回空脚本。第二次执行注册报告 `ok (already enrolled)` 且不写变量；预置厂商 PK 时结果为 `foreign`，变量不变。db 变量使用 image security database GUID；固件可能追加其他证书，因此是否需要写入由是否包含我们的描述符决定，而非字节相等。

必须在任何 HTTP 请求成功之前失败的负向用例：

- 未签名产物，或签名后被修改的产物；
- 来自其他 CA 的证书（即使在正确端口上）；
- 叶证书正确但构建时缺少 `CERT=` 导致证书链无法补全：标准构建内嵌引导 CA，故该用例需要刻意修改控制面构建，且必须失败。

QEMU 参考运行（测试密钥，不用于生产）：

```bash
qemu-system-x86_64 \
  -machine q35,smm=on,accel=kvm -cpu host -m 2048 \
  -drive if=pflash,unit=0,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
  -drive if=pflash,unit=1,format=raw,file=vars.fd \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=virtio,format=raw,file=fat:rw:esp \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -serial file:serial.log -display none -no-reboot
```

`vars.fd` 的 `db` 中必须包含签名证书；`esp/EFI/BOOT/BOOTX64.EFI` 必须是已签名产物。

## 威胁模型边界

该配置保护网络引导路径，使其免受未签名代码与被替换的引导服务器影响。其前提是本机平台不处于攻击者控制之下。

- 本地控制台与固件 Setup 必须锁定（Setup 密码、固定引导顺序、启用 Secure Boot、`db` 写保护）。任何能够修改 `db`、关闭 Secure Boot 或从可移动介质引导的人员，均已超出本配置的防护范围。
- `shell` 菜单项仅用于诊断。它不是受支持的本地镜像加载方式：iPXE 自身的镜像加载器不查询 UEFI Secure Boot，因而绕过平台锚点。
- DHCP/TFTP 欺骗仍可更改控制器地址或造成拒绝服务。至固定引导 CA 的 TLS 使这类攻击表现为引导失败，而非注入代码。

## 不在范围内

- TPM 密封与密钥释放（quote 证明 PCR 状态，不释放机密）。
- 防回滚、BMC 被攻陷与拒绝服务。
- Linux 内核/initramfs 的 Secure Boot 链与第三方安装器。
- 发行版签名的操作系统加载器：`sanboot` 之后固件会拒绝未签名的 shim/GRUB；母盘必须携带由 `db` 中对应 CA 支持的发行版自签名链。
- 引导 CA 的在线吊销。

该配置保证首段代码与引导服务器可被识别。它不能使整条引导链在平台被攻陷时仍然可度量或可恢复。

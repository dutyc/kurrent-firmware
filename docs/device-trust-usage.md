# 设备信任根能力使用文档（主仓库参考）

> 面向 Kurrent 主仓库的固件侧能力使用说明：设备身份密钥命令、TOFU
> HTTPS 信任、NVRAM 持久化设置与签名接口契约。对应固件补丁 0008/0009/0010
> （见 [patches/README.md](../patches/README.md) 与
> [customizations.md](customizations.md) 的 ## 8/9/10）。

## 1. 能力总览

固件侧交付的能力（R1-R5），全部为**命令/设置层能力**——业务逻辑（注册、
挑战-响应、验签）由主仓库引导脚本（boot.ipxe 链）实现，固件不感知。

| 需求 | 固件能力 | 使用入口 |
|---|---|---|
| R1 | HTTPS 下载（TLS 1.2，iPXE 原生实现） | `imgfetch` / `chain` `https://...` |
| R2 | TOFU 信任（首次接触放行 + 指纹 pin） | 自动生效（无命令） |
| R3 | EFI 变量 NVS 后端（重启保留） | `device-key` / `server-fingerprint` 设置 |
| R4 | 设备密钥生成 / 公钥导出 | `keygen` / `pubkey` 命令 |
| R5 | ECDSA 签名 | `sign` 命令 |

## 2. 命令参考

### 2.1 `keygen` —— 生成设备身份密钥

```
keygen
```

- **行为**：生成 32 字节 ECDSA P-256 私钥，写入非易失设置 `device-key`。
  熵源为 EFI RNG（经 DRBG 机制），私钥**永不出设备**。
- **幂等性**：若 `device-key` 已存在则**拒绝覆盖**，输出
  `keygen: device key already exists` 并以 `-EEXIST` 退出。
- **持久化**：写入 EFI NVRAM 变量（项目命名空间 GUID），重启保留。
- **典型用法**：引导脚本开头无条件调用一次——首次启动生成，之后启动
  自动跳过（失败不影响后续命令执行：`keygen || true` 或直接忽略退出码）。

**控制台交互示例**（QEMU 串口 / iPXE shell）：

```
iPXE> keygen
keygen: device key generated

iPXE> keygen          # 再次执行：密钥已存在，拒绝覆盖，退出码非零
keygen: device key already exists
```

### 2.2 `pubkey` —— 导出公钥

```
pubkey
```

- **前置条件**：`device-key` 已存在（未生成时报
  `pubkey: no device key (run keygen first)`）。
- **输出**：标准输出打印 130 个 hex 字符（65 字节未压缩点
  `0x04 ‖ X(32B) ‖ Y(32B)`），例如：
  ```
  04fe4ce89557ac97d1894273c71ccd296e3bdf4559bbe097ae74b55c27499f006f40a77a4fbbe1608a85ccc8452e55e038da0843e4e141ae73b9cf01296d90f140
  ```
- **设置**：同时写入临时设置 `pubkey`（hexraw 类型），脚本内可用
  `${pubkey}` 引用。该设置仅存内存，**不持久化**。
- **典型用法**：注册上报——设备首次开机时把 `${pubkey}` POST 到控制面。

**控制台交互示例**（输出为实测格式）：

```
iPXE> pubkey
04ae1a4df0cf8243b591d835b71d16de07150e254fbafa06e9b397dd63dfd7ad45fce952f618d41122afc0dacd81eaeea3ef7529d3325a38daa31f3ed8cf57fc2f
```

### 2.3 `sign` —— 签名

```
sign <data...>
```

- **前置条件**：`device-key` 已存在。
- **数据拼接规则**：所有参数按顺序**无分隔拼接**（UTF-8 字节），如
  `sign 0123...host123` 等价于对字符串
  `0123456789abcdef52:54:00:12:34:56host123` 签名。推荐调用形态：
  `sign ${nonce}${net0/mac}${hostname}`（nonce 由控制面下发）。
- **签名流程**：数据 → SHA-256 → ECDSA P-256 → DER 编码签名。
- **输出**：标准输出打印 **base64(DER)** 签名，例如：
  ```
  MEUCIQCx...EQIgaR...
  ```
- **设置**：同时写入临时设置 `sig`（string 类型），脚本内可用 `${sig}`
  引用。该设置仅存内存，**不持久化**。
- **错误**：`sign: no device key (run keygen first)`（未生成密钥）；
  `sign: could not sign: <err>`（密码学错误，见 §7 排查）。

**控制台交互示例**（数据为 `0123456789abcdef` + `52:54:00:12:34:56` +
`host123` 无分隔拼接）：

```
iPXE> sign 0123456789abcdef52:54:00:12:34:56host123
MEQCIHgtBUiiwEqaAE8XGNlDdfmZvM/kxuio7p2F341rDupuAiAoa4Gd8tfI3JV6tqoU4M0+Xijj65IKzVEUCmO3Qb9eqg==
```

## 3. 设置项参考

| 设置名 | 类型 | 标签 | 持久性 | 来源 |
|---|---|---|---|---|
| `device-key` | hexraw | DHCP 0x5e | **NVRAM（重启保留）** | 0008 定义，`keygen` 写入 |
| `server-fingerprint` | hexraw | DHCP 0x5f | **NVRAM（重启保留）** | 0008 定义，TOFU 写入 |
| `trust` | hexraw | DHCP 0x5a | 上游既有（NVRAM 覆盖根证书表） | TOFU 镜像 |
| `pubkey` | hexraw | DHCP 0x60 | 内存（临时） | `pubkey` 命令 |
| `sig` | string | DHCP 0x61 | 内存（临时） | `sign` 命令 |

- 脚本内访问：`${device-key}`、`${server-fingerprint}`、`${trust}`、
  `${pubkey}`、`${sig}`。
- `pubkey`/`sig` 为**同一次启动内**的命令输出暂存，重启即失——不可
  依赖跨启动读取。
- `device-key` 为敏感设置：仅固件内部使用，脚本侧可读但不应回显到
  不受信任的通道。
- 清空持久设置即删除，**必须带 `nvo/` 块前缀**（NVO 设置均为封装
  tag，从根路由不匹配）：`clear nvo/device-key` 删除密钥、
  `clear nvo/server-fingerprint` 删除指纹。裸 `clear device-key`
  或 `set device-key`（无值）对 NVS 后端**无效**（实测），见 §7。

## 4. TOFU（HTTPS 信任）行为

TOFU 在 TLS 握手路径自动生效（无命令、无配置），状态机如下：

| 阶段 | 条件 | 行为 |
|---|---|---|
| 首次接触 | 无 `server-fingerprint` 且证书校验失败 | **接受握手**，将叶证书 SHA-256 指纹写入 `server-fingerprint`（NVRAM）并镜像至 `trust` |
| 已 pin 且匹配 | 指纹存在，服务器证书指纹一致 | `trust` 覆盖根证书表（`ALLOW_TRUST_OVERRIDE`），证书校验通过，正常下载 |
| 已 pin 且不匹配 | 指纹存在，服务器证书指纹不一致 | 校验失败 → **拒绝**（不覆盖已有指纹） |

要点：

- **指纹 = 叶证书 DER 的 SHA-256**（与 `openssl x509 -outform DER |
  sha256sum` 结果一致）。
- 首次接触窗口期后，服务器证书被**固定**；换证书（如证书轮换）需先
  清除 NVRAM 指纹（重置设备或控制面下发重置流程）。
- 生产环境服务端证书可自签（TOFU 消解 CA 层级），但 **TLS 版本 ≤ 1.2**
  （iPXE 原生 TLS 实现上限）。
- 指纹写入与 pin 判定均在握手层完成：不匹配时 HTTP 请求不会发出。
- **pin 为全局单锚**：`server-fingerprint` 一旦存在，任何 TLS 校验失败
  都致命——固件只能信任首个 https 连接中被 pin 的那个证书。因此
  所有 HTTPS 目标必须共享该信任锚：统一入口网关（多域名共用同一
  证书）或证书链可链到被 pin 证书；其余流量可走 TFTP/HTTP。
- 清空 `server-fingerprint`（`clear nvo/server-fingerprint`）即解除
  pin，下次 https 连接重新进入注册窗口（见 §6.4）。

## 5. 签名接口契约（主仓库验签侧）

### 5.1 数据格式

```
data = nonce ‖ mac ‖ hostname
```

- `nonce`：控制面下发，64 个 hex 字符（32 字节随机数），一次性。
- `mac`：小写冒号格式 MAC（`52:54:00:12:34:56`），来自 `${net0/mac}`。
- `hostname`：设备主机名（UTF-8）。
- 拼接**无分隔符**；固件侧 `sign` 命令的参数即最终字节序列。

### 5.2 签名与编码

- 摘要：`SHA-256(data)`
- 算法：`ECDSA with P-256`（`prime256v1`，OID 1.2.840.10045.3.1.7）
- 签名编码：ASN.1 DER（`SEQUENCE { INTEGER r, INTEGER s }`）
- 传输编码：base64（标准字母表，无换行）

### 5.3 主机侧验签示例（Python + cryptography）

```python
#!/usr/bin/env python3
"""固件 sign 命令输出的验签示例（已在 QEMU 实测通过）"""
import base64, hashlib
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

def verify(pub_hex: str, sig_b64: str, data: bytes) -> bool:
    # 1. 公钥：130 hex 未压缩点 → 曲线点对象
    point = bytes.fromhex(pub_hex)
    pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), point)
    # 2. 签名：base64(DER) → 原始字节（cryptography 接受 DER 编码）
    sig_der = base64.b64decode(sig_b64)
    # 3. 验签（hashing 模式：库内部对 data 做 SHA-256）
    try:
        pub.verify(sig_der, data, ec.ECDSA(hashes.SHA256()))
        return True
    except Exception:
        return False

# 使用示例：控制面拿到固件上报的 pubkey 与 sig 后
pubkey = "04fe4c..."            # pubkey 命令输出（130 hex）
sig = "MEUCIQCx..."             # sign 命令输出（base64 DER）
nonce, mac, hostname = "0123456789abcdef" * 4, "52:54:00:12:34:56", "host123"
data = (nonce + mac + hostname).encode("utf-8")
print("verify:", verify(pubkey, sig, data))
```

若控制面已持有数据摘要而非原始数据，改用 prehashed 模式
（注意：cryptography ≥ 42 要求 `Prehashed(algorithm)` 显式传参）：

```python
from cryptography.hazmat.primitives.asymmetric import utils
digest = hashlib.sha256(data).digest()
pub.verify(sig_der, digest, ec.ECDSA(utils.Prehashed(hashes.SHA256())))
```

## 6. 集成示例（主仓库 boot.ipxe 参考模式）

> 通用约定：`${hostname}` 来自 DHCP 主机名（或脚本内 `set hostname ...`）；
> 所有 `https://` 端点首次连接时触发 TOFU pin，务必保证全部 HTTPS 目标
> 共享同一信任锚（见 §4）；`chain --autofree` 下载并执行完即释放。

### 6.1 设备注册（首次开机，公钥上报）

```ipxe
# 幂等：首次生成，之后 keygen 拒绝并退出非零，用 || 容忍
keygen || echo "identity: already provisioned"

# 导出公钥（命令同时写入 ${pubkey} 供引用）
pubkey || goto fail

# 上报公钥；控制面返回 #!ipxe 脚本体（已登记设备返回 set registered 1）
chain --autofree \
    https://mgmt.example.com/register?mac=${net0/mac}&pubkey=${pubkey} \
    || goto fail
echo REGISTER-OK
:fail
echo REGISTER-FAILED
```

控制面 `/register` 响应示例（`#!ipxe` 脚本体）：

```ipxe
# 已登记：跳过后续注册阶段（若未登记则登记该 MAC→公钥映射）
set registered 1
```

### 6.2 挑战-响应（引导凭证下发）

```ipxe
# 1. 获取一次性 nonce（响应体为 #!ipxe：set nonce <64hex>）
:challenge
chain --autofree https://mgmt.example.com/challenge?mac=${net0/mac} \
    || goto fail
isset ${nonce} || goto fail

# 2. 签名 nonce‖mac‖hostname（无分隔拼接）
sign ${nonce}${net0/mac}${hostname} || goto fail

# 3. 回传签名；控制面验签通过后下发引导脚本
#    （含 nbft-secret、内核参数等敏感变量，仅验签通过者可见）
chain --autofree https://mgmt.example.com/authorize?mac=${net0/mac}&sig=${sig} \
    || goto fail
echo CHALLENGE-OK
:fail
echo CHALLENGE-FAILED
```

控制面 `/challenge` 响应示例（`#!ipxe` 脚本体）：

```ipxe
set nonce 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

### 6.3 HTTPS 资产拉取与启动（TOFU 生效）

```ipxe
# 首次接触：握手被 TOFU 接受，指纹落 NVRAM；此后固定该证书
imgfetch --name vmlinuz \
    https://boot.example.com/assets/vmlinuz || goto fail
imgload vmlinuz || goto fail
chain vmlinuz initrd=initrd.img || goto fail
```

### 6.4 状态查询与身份重置（运维）

```ipxe
# 状态查询（不显示私钥值）
isset ${device-key} && echo "identity: provisioned" \
    || echo "identity: missing"
isset ${server-fingerprint} && echo "tofu: pinned" \
    || echo "tofu: not pinned"

# 显示指纹（可与 openssl 独立计算结果比对）
show server-fingerprint

# ---- 重置操作（敏感，需管理面授权流程，见 §9） ----
# 重置设备身份：删除私钥，下次启动 keygen 生成新密钥（需重新注册）
# 注意：NVO 设置是封装 tag，必须带 nvo/ 块前缀；裸 clear 无效
clear nvo/device-key
# 解除 TOFU pin：下次 https 连接重新进入注册窗口
clear nvo/server-fingerprint
```

### 6.5 完整引导链参考模板

```ipxe
#!ipxe
# 设备信任根完整引导链（主仓库参考模板）

# 阶段 0：网络就绪
dhcp || goto fail

# 阶段 1：设备身份（幂等）
keygen || echo "identity: already provisioned"

# 阶段 2：公钥导出与注册
pubkey || goto fail
chain --autofree \
    https://mgmt.example.com/register?mac=${net0/mac}&pubkey=${pubkey} \
    || goto fail

# 阶段 3：挑战-响应获取引导凭证
:challenge
chain --autofree https://mgmt.example.com/challenge?mac=${net0/mac} \
    || goto fail
isset ${nonce} || goto fail
sign ${nonce}${net0/mac}${hostname} || goto fail
chain --autofree \
    https://mgmt.example.com/authorize?mac=${net0/mac}&sig=${sig} \
    || goto fail
# /authorize 验签通过后下发引导脚本（设置 nbft-secret、内核参数等）

# 阶段 4：由 authorize 下发的引导脚本继续（资产拉取见 6.3）
:fail
echo TRUSTROOT-BOOT-FAILED
```

## 7. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `keygen: device key already exists` | 密钥已存在（正常幂等路径） | 无需处理；确需重置则清 NVRAM（如删除 OVMF_VARS 变量或重置设备） |
| `pubkey: no device key (run keygen first)` | 未执行过 keygen 或 NVRAM 被清 | 先执行 `keygen` |
| `sign: no device key (run keygen first)` | 同上 | 同上 |
| `sign: could not sign: Invalid argument` | 内部密码学错误（正常情况下不应出现） | 检查固件版本；复现时抓串口日志 |
| HTTPS 拉取被拒（`TOFU-FETCH-FAIL` 类现象） | 服务器证书与 NVRAM 中 pin 的指纹不一致 | 确认服务器证书未轮换；需轮换时重置 NVRAM 指纹 |
| 访问第二个 HTTPS 主机被拒 | pin 为全局单锚：固件只信任首个 https 连接被 pin 的证书 | 统一 HTTPS 入口/证书，其余流量走 TFTP/HTTP（见 §4） |
| TLS 握手失败 | 服务端 TLS > 1.2 或密码套件不受支持 | 服务端限制 `TLS ≤ 1.2`（见 [test/https-server.py](../test/https-server.py) 的套件清单） |
| 脚本中 `${pubkey}` / `${sig}` 为空 | 命令失败或设置未写入 | 检查命令输出；`pubkey`/`sig` 仅同次启动内有效 |
| `clear device-key` 后密钥仍在 | 裸 `clear`/`set` 对 NVS 封装 tag 无效 | 必须用 `clear nvo/device-key`（块前缀，见 §6.4） |

## 8. 验证与测试资产（固件仓库内）

- `test/devicekey-test.ipxe` + `test/run-qemu-devicekey.sh`：keygen →
  pubkey → sign 两轮自测（round 1 清 NVRAM 生成；round 2 验证持久化与
  防覆盖）。
- `test/tofu-test.ipxe` + `test/run-qemu-tofu.sh`：TOFU 三轮验证
  （首次接受 + 指纹落盘 → 指纹匹配下载 → 证书更换拒绝）。
- `test/https-server.py`：TLS 1.2 HTTPS 测试端点（Python 标准库实现，
  密码套件与 iPXE 兼容）。
- `test/dump-nvram.py`：OVMF NVRAM 变量内容检查（验证指纹/密钥落盘
  字节与 openssl 独立计算结果一致）。

## 9. 安全边界

- **私钥不出设备**：`device-key` 仅固件内部使用；公钥与签名可导出。
- **签名可重放防护依赖 nonce**：控制面必须保证 nonce 一次性、短 TTL、
  绑定 MAC。
- **TOFU 信任锚**：首次接触无认证——注册窗口内的中间人风险由部署
  网络隔离承担；pin 之后具备完整性校验。
- **生产端点约束**：`/challenge`、`/register` 等控制面端点应置于强
  认证之后（TLS/mTLS + 客户端身份校验）；固件侧无额外加密层。
- **重置操作授权**：`clear nvo/device-key`（身份重置，需重新注册）与
  `clear nvo/server-fingerprint`（解除 pin，重开注册窗口）均为敏感
  操作，应只由管理面授权流程触发（如控制面下发专用重置脚本）。
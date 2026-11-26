# 设备信任根能力使用文档（主仓库参考）

[English](device-trust-usage.md) | [中文](device-trust-usage.zh-CN.md)

> 面向 Kurrent 主仓库的固件侧能力使用说明：TPM 2.0 设备身份（AK 与
> PCR quote）、TOFU HTTPS 信任、NVRAM 持久化设置与证明接口契约。对应
> 固件补丁 0006/0007/0008/0011（见 [patches/README.md](../patches/README.md)
> 与 [customizations.md](customizations.md) 的 ## 6/7/8/11）。

## 1. 能力总览

固件侧交付的能力（R1-R6），全部为**命令/设置层能力**——业务逻辑（注册、
挑战-签发、证明校验）由主仓库引导脚本与控制面实现，固件不感知。

| 需求 | 固件能力 | 使用入口 |
|---|---|---|
| R1 | HTTPS 下载（TLS 1.2，iPXE 原生实现） | `imgfetch` / `chain` `https://...` |
| R2 | TOFU 信任（首次接触放行 + 指纹固定） | 自动生效（无命令） |
| R3 | EFI 变量 NVS 后端（重启保留） | `server-fingerprint` / `trust` 设置 |
| R4 | TPM 内创建 / 复用设备身份密钥 | `akgen` 命令（幂等） |
| R5 | 导出 AK 公钥、名称、算法与 Secure Boot 状态 | `akpub` 命令 |
| R6 | 对 PCR 0/2/4/7 做 SHA-256 quote | `quote <nonce>` 命令 |

设备身份**没有软件私钥**：AK 的私钥由 TPM 生成并保管、不可导出，固件
只导出公钥与签名。没有 TPM 时上述命令以非零状态退出（`-ENODEV`），
不存在软件回退。

## 2. 命令参考

### 2.1 `akgen` —— 创建 / 复用 AK

```
akgen
```

- **行为**：在 TPM 内创建 restricted signing 密钥（优先 ECC P-256，
  TPM 拒绝时回退 RSA-2048），用 `TPM2_EvictControl` 持久化到句柄
  `0x81000001`，随后释放临时句柄。私钥永不出 TPM，固件也不读取。
- **幂等性**：已存在 AK 时只读确认、不重建、不覆盖，输出
  `akgen: attestation key already present` 并返回 0；首次创建输出
  `akgen: attestation key created`。
- **持久化**：AK 在 TPM NV 中，与 EFI 变量无关——清空 OVMF 变量存储
  后重启仍复用同一把 AK。
- **典型用法**：引导脚本开头无条件调用一次：`akgen || echo "identity: 错误"`。
- **换 AK**：固件无覆盖路径。只能走管理员恢复（删除设备登记后重新
  入池），或清除/更换 TPM。

### 2.2 `akpub` —— 导出身份并发布 Secure Boot 状态

```
akpub
```

- **前置条件**：`akgen` 已成功（否则
  `akpub: no attestation key (run akgen first)`）。
- **输出与设置**（仅本次启动的内存设置，重启即失）：

  | 输出行 | 设置名 | 内容 |
  |---|---|---|
  | `ak-public:` | `ak-public` | 公钥 SubjectPublicKeyInfo DER 的 hex |
  | `ak-name:` | `ak-name` | TPM2B_NAME，68 hex（`000b` + 公钥结构 SHA-256） |
  | `ak-type:` | `ak-type` | `ecc_p256` 或 `rsa2048`（字符串） |
  | `sb:` | `sb` | `1` / `0`：读取 EFI 全局变量 `SecureBoot` 得出 |

- `sb` 在导出公钥之前写入，因此即便 TPM 不可用，只要 `akpub` 被执行过，
  `${sb}` 也有值；无 TPM 时 `${ak-public}` / `${ak-name}` / `${ak-type}` 为空。
- 脚本内访问：`${ak-public}`、`${ak-name}`、`${ak-type}`、`${sb}`。

### 2.3 `quote <nonce>` —— PCR 证明

```
quote <nonce>
```

- **前置条件**：AK 已存在。
- **行为**：一次 `TPM2_Quote` 调用内完成 PCR 0/2/4/7（SHA-256 银行）的
  读取与签名；`nonce` 原样作为 `qualifyingData` 写入 `extraData`（64 个
  hex 字符 = 64 个 ASCII 字节，**不做 hex 解码**）。
- **输出与设置**：

  | 输出行 | 设置名 | 内容 |
  |---|---|---|
  | `quote:` | `quote` | TPMS_ATTEST 原始字节 hex（不含 TPM2B 长度前缀） |
  | `quote-sig:` | `quote-sig` | 对 quote 原始字节的签名 hex（ECC：ASN.1 DER；RSA：PKCS#1 v1.5） |

- 固件在导出前自检：magic `0xFF544347`、type `0x8018`、单条 SHA-256 选择、
  位图 `95 00 00`（PCR 0/2/4/7）、32 字节 PCR 摘要。
- `nonce` 长度限制 1–64 字节；控制面固定下发 64 个 hex 字符。

### 2.4 `nvclear` —— 清空设备 NVRAM

一条命令清空本项目在非易失存储里的全部设置（`server-fingerprint`、
`trust`），把设备的 TOFU 状态还原到出厂态。设备身份在 TPM 中，不受
`nvclear` 影响。

```
iPXE> nvclear
nvclear: server-fingerprint: cleared
nvclear: trust: not present
nvclear: device NVRAM cleared
```

- 逐项报告三种结果：`cleared` / `not present`（本就为空）/ `could not
  clear: <errno>`；任一项失败时末行输出 `nvclear: incomplete` 并返回
  非零，供脚本判定。
- 清理效果**重启后仍然成立**（补丁 0006 让长度归零的选项块也真正下发
  写操作，见 [customizations.md](customizations.md) 的 §6）。
- 只动本项目这两个设置，不触碰其它 UEFI 变量。
- 等价的手工写法是逐项 `clear nvo/<设置名>`——**必须带 `nvo/` 块前缀**；
  裸 `clear server-fingerprint` 只清掉内存影子，见 §3 与 §7。
- 验收：`test/nvs-clear.ipxe` + `test/run-qemu-nvclear.sh`（§8）。

## 3. 设置项参考

| 设置名 | 类型 | 标签 | 持久性 | 来源 |
|---|---|---|---|---|
| `server-fingerprint` | hexraw | DHCP 0x5f | **NVRAM（重启保留）** | 0006 定义，TOFU 写入 |
| `trust` | hex | DHCP 0x5a | 上游既有（NVRAM 覆盖根证书表） | TOFU 镜像 |
| `ak-public` | hexraw | DHCP 0x60 | 内存（本次启动） | `akpub` |
| `quote` | hexraw | DHCP 0x61 | 内存（本次启动） | `quote` |
| `quote-sig` | hexraw | DHCP 0x62 | 内存（本次启动） | `quote` |
| `ak-name` | hexraw | DHCP 0x63 | 内存（本次启动） | `akpub` |
| `ak-type` | string | DHCP 0x64 | 内存（本次启动） | `akpub` |
| `sb` | string | DHCP 0x65 | 内存（本次启动） | `akpub` |

- 脚本内访问：`${server-fingerprint}`、`${trust}`、`${ak-public}`、
  `${quote}`、`${quote-sig}`、`${ak-name}`、`${ak-type}`、`${sb}`。
- 身份与证明设置均为**同一次启动内**的命令输出暂存，不落 NVRAM。
- 清空持久设置即删除，**必须带 `nvo/` 块前缀**（NVO 设置均为封装
  tag，从根路由不匹配）：`clear nvo/server-fingerprint` 删除指纹。
  裸 `clear server-fingerprint` 或 `set server-fingerprint`（无值）对
  NVS 后端**无效**（实测），见 §7。一次清空两项用 `nvclear`（§2.4）。
- 手工给 `trust` 赋值时要注意类型是 `hex`（`33:33:…` 冒号分隔），
  不是 `hexraw`；写成无分隔的 `3333…` 会被拒（`Invalid argument`）。

## 4. TOFU（HTTPS 信任）行为

TOFU 在 TLS 握手路径自动生效（无命令、无配置），状态机如下：

| 阶段 | 条件 | 行为 |
|---|---|---|
| 首次接触 | 无 `server-fingerprint` 且证书校验失败 | **接受握手**，将叶证书 SHA-256 指纹写入 `server-fingerprint`（NVRAM）并镜像至 `trust` |
| 已固定且匹配 | 指纹存在，服务器证书指纹一致 | `trust` 覆盖根证书表（`ALLOW_TRUST_OVERRIDE`），证书校验通过，正常下载 |
| 已固定且不匹配 | 指纹存在，服务器证书指纹不一致 | 校验失败 → **拒绝**（不覆盖已有指纹） |

要点：

- **指纹 = 叶证书 DER 的 SHA-256**（与 `openssl x509 -outform DER |
  sha256sum` 结果一致）。
- 首次接触窗口期后，服务器证书被**固定**；换证书（如证书轮换）需先
  清除 NVRAM 指纹（重置设备或控制面下发重置流程）。
- 生产环境服务端证书可自签（TOFU 消解 CA 层级），但 **TLS 版本 ≤ 1.2**
  （iPXE 原生 TLS 实现上限）。
- 指纹写入与固定判定均在握手层完成：不匹配时 HTTP 请求不会发出。
- **固定为全局单锚**：`server-fingerprint` 一旦存在，任何 TLS 校验失败
  都致命——固件只能信任首个 https 连接中被固定的那个证书。因此
  所有 HTTPS 目标必须共享该信任锚：统一入口网关（多域名共用同一
  证书）或证书链可链到已固定证书；其余流量可走 TFTP/HTTP。
- 清空 `server-fingerprint`（`clear nvo/server-fingerprint`）即解除
  固定，下次 https 连接重新进入注册窗口（见 §6.4）。

## 5. 证明接口契约（主仓库验证侧）

### 5.1 `quote` 内容

`quote` 是 TPMS_ATTEST 的原始字节（hex 传输，**不含** TPM2B_ATTEST 的
2 字节长度前缀），由一次 `TPM2_Quote` 产生：

| 字段 | 值 |
|---|---|
| `magic` | `0xFF544347` |
| `type` | `0x8018`（TPM_ST_ATTEST_QUOTE） |
| `qualifiedSigner` | AK 的 TPM2B_NAME（34 字节） |
| `extraData` | `nonce` 字符串的 ASCII 字节（64 个 hex 字符 = 64 字节） |
| PCR 选择 | 仅 SHA-256，位图 `95 00 00`（PCR 0/2/4/7） |
| `pcrDigest` | 32 字节 SHA-256 |
| `firmwareVersion` / `clockInfo` | TPM 自身信息，验证侧跳过 |

PCR 读取与签名在同一次 TPM 调用内完成，两次读取之间的测量变化不存在。

### 5.2 签名与编码

| AK 算法 | 签名编码 |
|---|---|
| `ecc_p256` | ASN.1 DER（`SEQUENCE { INTEGER r, INTEGER s }`），ECDSA-SHA256 |
| `rsa2048` | PKCS#1 v1.5，SHA-256 |

签名对象是**完整的 TPMS_ATTEST 字节**（即 `quote` 解码后的字节），
传输编码为 hex。

### 5.3 公钥与名称

- `ak-public` 是 SubjectPublicKeyInfo DER：ECC 为
  `id-ecPublicKey + prime256v1`（91 字节），RSA 为 `rsaEncryption`
  （294 字节）。
- `ak-name` 是 TPM2B_NAME：`000b` + 公钥结构的 SHA-256（共 34 字节 /
  68 hex），控制面只校验长度与算法前缀。
- `ak-type` 必须与实际公钥算法一致，否则身份视为无效。

### 5.4 主机侧验证示例（Python + cryptography）

```python
#!/usr/bin/env python3
"""验证固件 quote 的签名、nonce 绑定与 PCR 选择"""
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.serialization import load_der_public_key

PCR_BITMAP = bytes([0x95, 0x00, 0x00])

def verify(ak_public_hex, ak_type, quote_hex, sig_hex, nonce):
    quote = bytes.fromhex(quote_hex)
    sig = bytes.fromhex(sig_hex)
    key = load_der_public_key(bytes.fromhex(ak_public_hex))
    if ak_type == "ecc_p256":
        key.verify(sig, quote, ec.ECDSA(hashes.SHA256()))
    else:
        key.verify(sig, quote, padding.PKCS1v15(), hashes.SHA256())
    # 结构校验：magic/type/extraData/PCR 选择/摘要长度
    assert quote[:4] == bytes.fromhex("ff544347")
    # ...（完整实现见控制面 attestation 模块）
    return True
```

仓库内可直接运行的独立校验器：`test/verify-ak-quote.py`（§8）。

## 6. 集成示例（主仓库 boot.ipxe 参考模式）

> 通用约定：所有 `https://` 端点首次连接时触发 TOFU 固定，务必保证全部
> HTTPS 目标共享同一信任锚（见 §4）；`chain --autofree` 下载并执行完即释放。

### 6.1 设备身份与注册上报（首次开机）

```ipxe
# 幂等：首次创建 AK，之后复用；失败（无 TPM）不影响后续脚本
akgen || echo "identity: no TPM"

# 导出身份；无 TPM 时转到无身份上报路径
akpub || goto report-fingerprint

chain --autofree \
    https://mgmt.example.com/devices/report?mac=${netX/mac}&ak_public=${ak-public}&ak_name=${ak-name}&ak_type=${ak-type}&sb=${sb} \
    || goto report-done

:report-fingerprint
# 无 AK 的上报让控制面把设备记为 no_tpm；指纹仍会被合并
chain --autofree \
    https://mgmt.example.com/devices/report?mac=${netX/mac}&sb=${sb} ||
:report-done
```

### 6.2 挑战-证明（引导凭证下发）

```ipxe
# 1. 获取一次性 nonce（响应体为 #!ipxe：set nonce <64hex>）
:challenge
chain --autofree https://mgmt.example.com/devices/challenge?mac=${mac} \
    && goto quoted || goto bootvars

# 2. 对 nonce 做 PCR quote（写入 ${quote} / ${quote-sig}）
:quoted
quote ${nonce} || goto bootvars
chain --autofree https://mgmt.example.com/boot-vars?mac=${mac}&hostname=${hostname}&nonce=${nonce}&quote=${quote}&quote_sig=${quote-sig} \
    || goto retry
goto vars-done

# 3. 认证/TLS 握手失败时用同一 nonce/quote 重取一次，最多一次
:retry
chain --autofree https://mgmt.example.com/boot-vars?mac=${mac}&hostname=${hostname}&nonce=${nonce}&quote=${quote}&quote_sig=${quote-sig} \
    || goto bootvars
goto vars-done

# 降级路径：无证明，控制面不下发凭据
:bootvars
chain --autofree https://mgmt.example.com/boot-vars?mac=${mac}&hostname=${hostname} \
    || goto vars-done
```

控制面 `/devices/challenge` 响应示例（`#!ipxe` 脚本体）：

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

### 6.4 状态查询与 TOFU 重置（运维）

```ipxe
# 状态查询（不产生任何私钥输出）
isset ${ak-type} && echo "identity: ${ak-type} ${ak-name}" \
    || echo "identity: no TPM"
isset ${server-fingerprint} && echo "tofu: pinned" \
    || echo "tofu: not pinned"

# 显示指纹（可与 openssl 独立计算结果比对）
show server-fingerprint

# ---- TOFU 重置（敏感，需管理面授权流程，见 §9） ----
nvclear
# 或按需单项：NVO 设置是封装 tag，必须带 nvo/ 块前缀；裸 clear 无效
# clear nvo/server-fingerprint # 解除 TOFU 固定：下次 https 连接重新进入注册窗口
```

AK 不能从这里重置：换 AK 只能删除控制面登记后重新入池，或更换 TPM。

### 6.5 完整引导链参考模板

```ipxe
#!ipxe
# 设备信任根完整引导链（主仓库参考模板）

# 阶段 0：网络就绪
dhcp || goto fail

# 阶段 1：TPM 身份（幂等）
akgen || echo "identity: no TPM"

# 阶段 2：身份导出与注册上报
akpub || goto report-fingerprint
chain --autofree \
    https://mgmt.example.com/devices/report?mac=${netX/mac}&ak_public=${ak-public}&ak_name=${ak-name}&ak_type=${ak-type}&sb=${sb} \
    || goto report-done
:report-fingerprint
chain --autofree https://mgmt.example.com/devices/report?mac=${netX/mac}&sb=${sb} ||
:report-done

# 阶段 3：挑战-证明获取引导凭证
:challenge
chain --autofree https://mgmt.example.com/devices/challenge?mac=${mac} \
    && goto quoted || goto bootvars
:quoted
quote ${nonce} || goto bootvars
chain --autofree \
    "https://mgmt.example.com/boot-vars?mac=${mac}&hostname=${hostname}&nonce=${nonce}&quote=${quote}&quote_sig=${quote-sig}" \
    || goto bootvars
# /boot-vars 证明通过后下发引导脚本（设置 nbft-secret、内核参数等）
:bootvars
chain --autofree https://mgmt.example.com/boot-vars?mac=${mac}&hostname=${hostname} \
    || goto fail

:fail
echo TRUSTROOT-BOOT-FAILED
```

## 7. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `akgen: No such device` | 平台没有 TPM，或固件拿不到 `EFI_TCG2_PROTOCOL` | 确认固件与固件设置中的 TPM 已启用；无 TPM 设备按 no_tpm 路径处理 |
| `akgen: Input/output error` | TPM 拒绝 `CreatePrimary`/`EvictControl`（如句柄被占用） | 抓串口日志中的 TPM 返回码；确认 `0x81000001` 未被其它对象占用 |
| `akgen: attestation key already present` | 已存在 AK（正常幂等路径） | 无需处理；换 AK 走管理员恢复（§2.1） |
| `akpub: no attestation key` | 未执行过 `akgen` 或 TPM 被清除 | 先执行 `akgen` |
| `quote: no attestation key` | 同上 | 同上 |
| `quote: nonce must be 1 to 64 bytes` | 传入的 nonce 超长/为空 | 使用控制面下发的 64 hex 字符 |
| `${ak-public}` / `${quote}` 为空 | 命令失败或设置未写入 | 检查命令输出；这些设置仅同次启动内有效 |
| 控制面报 `quote_invalid` | quote 结构/签名/`ak_type` 不符 | 用 `test/verify-ak-quote.py` 本地复验 |
| 控制面报 `nonce_invalid` | nonce 过期或已消费（重放） | 重新取 challenge；不要复用 quote |
| 控制面报 `pcr_mismatch` | PCR 0/2/4/7 摘要与基线不同（固件/安全启动配置变化） | 确认平台变更；管理员可重新批准基线 |
| 控制面报 `no_tpm` | 上报未携带有效 AK | 确认 TPM 可用且 `akpub` 成功 |
| 控制面报 `sb_disabled` | 自报 `sb=0`，新设备需 Secure Boot 开启 | 开启 Secure Boot 并重新入池 |
| HTTPS 拉取被拒（`TOFU-FETCH-FAIL` 类现象） | 服务器证书与 NVRAM 中已固定的指纹不一致 | 确认服务器证书未轮换；需轮换时重置 NVRAM 指纹 |
| 访问第二个 HTTPS 主机被拒 | 固定为全局单锚：固件只信任首个 https 连接中被固定的证书 | 统一 HTTPS 入口/证书，其余流量走 TFTP/HTTP（见 §4） |
| TLS 握手失败 | 服务端 TLS > 1.2 或密码套件不受支持 | 服务端限制 `TLS ≤ 1.2`（见 [test/https-server.py](../test/https-server.py) 的套件清单） |
| `clear server-fingerprint` 后指纹仍在 | 裸 `clear`/`set` 对 NVS 封装 tag 无效 | 必须用 `clear nvo/server-fingerprint`（块前缀，见 §6.4）或 `nvclear`（§2.4） |
| `nvclear` 报 `not present` | 该项本就为空 | 正常，无需处理 |
| `nvclear` 报 `could not clear` / 末行 `incomplete` | 后端写失败（EFI `SetVariable` 出错） | 抓串口日志看具体 errno；检查 NVRAM 空间与只读策略 |
| 清空后重启，设置又回来了 | 旧固件在选项块长度归零时不下发写操作（`nvo_save` 空转） | 升级到含补丁 0006 该修复的固件；验收 `test/run-qemu-nvclear.sh` |

## 8. 验证与测试资产（固件仓库内）

- `test/ak-test.ipxe` + `test/run-qemu-ak.sh`：AK 两轮自测（round 1 在
  全新 swtpm 状态上创建；round 2 用 `--clean-nvram` 清空 OVMF 变量后
  仍复用同一 AK）；`--no-tpm` 验证无 TPM 时三个命令失败但不崩溃。
- `test/ak-e2e.ipxe`：连接运行中的控制面，走
  report → challenge → `quote` → `/boot-vars` 的完整证明链。
- `test/verify-ak-quote.py`：独立校验器，检查 quote 结构、`extraData`
  与 nonce、PCR 选择、签名与（可选）基线。
- `test/tofu-test.ipxe` + `test/run-qemu-tofu.sh`：TOFU 三轮验证
  （首次接受 + 指纹落盘 → 指纹匹配下载 → 证书更换拒绝）。
- `test/https-server.py`：TLS 1.2 HTTPS 测试端点（Python 标准库实现，
  密码套件与 iPXE 兼容）。
- `test/dump-nvram.py`：OVMF NVRAM 变量内容检查（验证指纹落盘字节与
  openssl 独立计算结果一致）。
- `test/nvs-clear.ipxe` + `test/run-qemu-nvclear.sh`：`nvclear` 三轮
  验证（写入两项 → 清理 → 复读；第 3 轮开机两项都不存在即证明清理
  已落盘）。

## 9. 安全边界

- **AK 私钥不出 TPM**：固件不生成、不读取、不导出私钥；导出物只有
  公钥、TPM2B_NAME、quote 与签名。
- **证明可重放防护依赖 nonce**：控制面必须保证 nonce 一次性、短 TTL、
  绑定 MAC；quote 覆盖 PCR 0/2/4/7，不覆盖运行期。
- **AK 不可覆盖**：固件没有重建路径；换 AK 只能删除登记后重新入池，
  或更换/清除 TPM。
- **TOFU 信任锚**：首次接触无认证——注册窗口内的中间人风险由部署
  网络隔离承担；固定之后具备完整性校验。
- **`sb` 是自报值**：控制面只把它用于注册放行，启动期准入以 TPM 证明
  为准，不信任自报。
- **生产端点约束**：`/devices/report`、`/devices/challenge`、
  `/boot-vars` 应置于受控内网并限速；固件侧无额外加密层。
- **重置操作授权**：`nvclear`（清空 TOFU 状态）与
  `clear nvo/server-fingerprint`（解除固定，重开注册窗口）均为敏感
  操作，应只由管理面授权流程触发（如控制面下发专用重置脚本）。

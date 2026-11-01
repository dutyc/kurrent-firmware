# Secure Boot boot profile

This is an **optional** build profile. The default L1 firmware (network
boundary + TOFU) is unchanged; `build/build.sh` never applies anything from
`patches/secureboot/`.

## What it changes

| Layer | L1 (default) | Secure Boot profile |
|---|---|---|
| First-stage code | Unverified EFI binary over TFTP/USB | Signed `snponly-sb.efi`, verified by UEFI `db` |
| Boot scripts | `auto.ipxe` over TFTP, then HTTPS | Three static scripts embedded in the signed binary |
| Server identity | TOFU on first contact, leaf pin afterwards | Boot CA certificate and fingerprint baked into the firmware |
| 443 management entry | Unchanged | Unchanged (the profile uses a separate boot HTTPS port) |
| Device identity | `keygen` / `report` / `challenge` / `sign` | Same semantics, executed inside signed code |

The static scripts are:

```
auto.ipxe          dhcp -> chain sb-boot.ipxe.cfg -> chain sb-menu.ipxe
sb-boot.ipxe.cfg   endpoint + device identity flow (report/challenge/sign/boot-vars)
sb-menu.ipxe       NVMe-oF system boot, shell, reboot, exit
```

TFTP or DHCP can still replace the controller address or cause a denial of
service, but they cannot inject unsigned code or a different server
certificate.

## Trust chain

```
UEFI db: artifact signing certificate
  └─ snponly-sb.efi (sbsign)
       ├─ auto.ipxe + sb-boot.ipxe.cfg + sb-menu.ipxe
       ├─ embedded boot CA certificate + its SHA-256 fingerprint
       └─ HTTPS to the boot endpoint
            ├─ /devices/report
            ├─ /devices/challenge
            ├─ /boot-vars
            └─ /file/... (OS assets)
```

Two independent anchors:

- **Platform anchor** — the artifact signing certificate in UEFI `db`.
- **Network anchor** — the boot CA embedded in the binary.

`TRUST=<boot-ca.pem>` pins the fingerprint. `CERT=<boot-ca.pem>` embeds the
certificate itself so the chain can be built when the TLS server does not send
the root certificate (the usual case). Both are required; a fingerprint alone
cannot verify the server leaf's signature.

The `patches/secureboot/0001-no-tofu.patch` overlay disables TOFU in this
build. Without it, a wrong-CA handshake would be accepted and pinned on first
contact, defeating the fixed CA.

## Build

Requirements: `sbsign`, `sbverify`, `openssl`, `python3`, `realpath`, plus the
normal toolchain.

```bash
SB_KEY=/secure/offline/artifact-signing.key \
SB_CERT=/secure/offline/artifact-signing.crt \
BOOT_CA_CERT=/secure/boot-ca.crt \
BOOT_HTTPS_PORT=4443 \
./build/build-sb.sh
```

| Variable | Meaning |
|---|---|
| `SB_KEY`, `SB_CERT` | Artifact signing key/certificate; keep offline, never in the repository or a container. Paths are canonicalised before the build changes directory |
| `BOOT_CA_CERT` | Boot CA in PEM, `basicConstraints CA:TRUE`; embedded as both certificate and fingerprint |
| `BOOT_HTTPS_PORT` | Boot endpoint port baked into the image (default `4443`, range 1-65535) |
| `CONTROLLER_IP` | Fixed controller IPv4 address; default is DHCP `next-server`. IPv6 literals are rejected |
| `KURRENT_SB_SRC_DIR` | Source cache; default `.cache/ipxe-sb` |
| `KURRENT_SB_OUT_DIR` | Output directory; default `dist/secureboot` |
| `KURRENT_SB_ALLOW_CUSTOM_OUT` | Set to `1` to allow removing an output directory outside `dist/` |
| `UPSTREAM_COMMIT`, `JOBS` | Same meaning as the normal build |

The Secure Boot build uses its own source cache, `.cache/ipxe-sb`, independent
of the L1 cache `.cache/ipxe-upstream`. Both caches hold the same upstream
baseline, but only the Secure Boot cache receives the TOFU overlay, so an L1
build can never pick it up by accident.

The Secure Boot cache and `dist/secureboot/` are reset before use. A custom
source directory outside `.cache/` is accepted only if its `origin` remote
equals `UPSTREAM_URL`; a custom output directory outside `dist/` requires
`KURRENT_SB_ALLOW_CUSTOM_OUT=1`.

Output:

```
dist/secureboot/
  snponly-sb.efi
  pxe-uefi/snponly-sb.efi
  direct-uefi/snponly-sb.efi
  manifest.json
  SHA256SUMS
```

The two directory copies are byte-identical to the root `snponly-sb.efi`: one
signed binary delivered in both the PXE and direct-boot layouts so consumers
can use a single path convention.

`manifest.json` records the artifact hash and size, signer subject, boot CA
SHA-256, port and upstream baseline. `verify-sb.sh` checks every signature,
the checksum list, manifest consistency (artifact hash/size, signer subject,
`tofu == false`, and the boot CA fingerprint when the third argument is given),
that no unsigned `.efi` was mixed in, and that no key or PEM file ended up in
the output:

```bash
./tools/verify-sb.sh /secure/offline/artifact-signing.crt
./tools/verify-sb.sh /secure/offline/artifact-signing.crt dist/secureboot /secure/boot-ca.crt
```

## Server-side requirements

- The boot HTTPS endpoint must present a certificate issued by the boot CA,
  with a SAN matching the controller address used by DHCP or `CONTROLLER_IP`.
- The port must expose only the boot endpoints. Keep the management entry on
  443 with its existing certificate; replacing it would break L1 devices that
  pinned the old leaf certificate.
- The boot CA is independent of the management and node CAs. Rotating it
  requires rebuilding and reflashing the firmware.

## Provisioning

1. Put the artifact signing certificate into the UEFI `db` via USB, BMC virtual
   media/Redfish, or the firmware key-management UI.
2. Enable Secure Boot and disable CSM.
3. Boot the signed artifact from local media or through the PXE path.

Firmware updates may clear `db`; re-import the artifact signing certificate
after such updates. To recover a
machine with a lost signing key, clear `db` and reflash a new signed artifact;
there is no online revocation path for the boot CA.

PXE network boot stacks do not all verify the downloaded NBP. Use local media
or a firmware HTTP Boot path when the platform is known to skip that check.

## Verification

Positive path: signed artifact accepted by OVMF Secure Boot, embedded scripts
execute, `/devices/report` and `/boot-vars` succeed over the pinned endpoint,
and the menu appears.

Negative cases that must fail before any HTTP request succeeds:

- unsigned artifact, or an artifact modified after signing;
- a certificate from a different CA (even on the correct port);
- a correct leaf whose chain cannot be completed because the build omitted
  `CERT=`: the standard build embeds the boot CA, so this case requires a
  deliberately modified control build and must fail.

QEMU reference run (test keys, not for production):

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

`vars.fd` must contain the signing certificate in `db`; `esp/EFI/BOOT/BOOTX64.EFI`
must be the signed artifact.

## Threat model boundary

The profile secures the network boot path against unsigned code and a
substituted boot server. It assumes the local platform is not under attacker
control.

- The local console and firmware Setup must be locked (Setup password, fixed
  boot order, Secure Boot enabled, `db` write-protected). Anyone who can change
  `db`, disable Secure Boot or boot from removable media is outside this
  profile.
- The `shell` menu entry is diagnostic only. It is not a supported way to load
  local images: iPXE's own image loaders do not consult UEFI Secure Boot, so
  they bypass the platform anchor.
- DHCP/TFTP spoofing can still change the controller address or deny service.
  TLS to the pinned boot CA turns that into a failed boot rather than injected
  code.

## Out of scope

- TPM measurement/sealing and remote attestation (L3).
- Anti-rollback, BMC compromise and denial of service.
- Linux kernel/initramfs Secure Boot chains and third-party installers.
- Distribution-signed OS loaders: the firmware will reject an unsigned
  shim/GRUB after `sanboot`; the golden image must carry the distribution's own
  signed chain backed by the matching CA in `db`.
- Online revocation of the boot CA.

The profile guarantees that the first-stage code and the boot server are
identified. It does not make the whole boot chain measured or recoverable
against a compromised platform.

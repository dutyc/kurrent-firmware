# Golden Image Distribution Matrix

[English](golden-image-matrix.md) | [中文](golden-image-matrix.zh-CN.md)

The golden image assets in this repository are organized by distribution: each distribution has one
self-contained one-shot script, and all of them share the same six-stage A-F customization flow
(rationale and manual steps in
[golden-image-customization-debian12.md](golden-image-customization-debian12.md));
host-side helper scripts and the packer are collected under `test/shared/`.

Every `golden-image-setup-*.sh` embeds the three initramfs-nbft components and the GRUB 2.14 artifact
(base64), so a single file can be copied into a golden image and run; after the components or the GRUB
artifact change, re-run `python3 test/shared/embed-components.py` to re-embed them (idempotent).

## Directory Layout

```
test/
├── debian12/golden-image-setup-debian12.sh
├── debian13/golden-image-setup-debian13.sh
├── ubuntu2404/golden-image-setup-ubuntu2404.sh
├── ubuntu2604/golden-image-setup-ubuntu2604.sh
├── fedora44/golden-image-setup-fedora44.sh
├── almalinux10/                 # RHEL family
│   ├── almalinux10.ks.in        # kickstart template (public key injection)
│   ├── run-almalinux10-install.sh
│   └── golden-image-setup-almalinux10.sh
├── opensuse-leap16/             # SUSE family
│   ├── leap16-profile.json      # Agama profile template (public key injection)
│   ├── run-leap16-install.sh
│   └── golden-image-setup-leap16.sh
└── shared/                      # common to all distributions
    ├── embed-components.py      # single-file packer (component + GRUB artifact embedding)
    ├── golden-vm-run.sh         # customization-stage VM launch (OVMF + slirp + SSH 2222 + QMP)
    ├── golden-ubuntu-vm-run.sh  # Ubuntu customization VM (seed mount + automatic resize + SSH 2222)
    ├── golden-vm-sendkey.py     # QMP→HMP keyboard injection (interactive channel without sshd)
    ├── golden-net-rebuild.sh    # network rebuild after a host reboot (br0/tap0 + NAT)
    ├── golden-nvmet-enable.sh   # nvmet namespace enablement (host mount ns required)
    ├── golden-esp-verify.sh     # 4K ESP content verification (512-byte logical sectors + offset loop)
    ├── fwtest-net.sh            # isolated acceptance bridge br-fwtest + tap0fw (root)
    ├── fwtest-nvmet-tls.sh      # acceptance target: DH-HMAC-CHAP host + TLS1.3/required port + PSK
    ├── fwtest-boot.sh           # isolated PXE cold boot (dnsmasq container + QEMU/OVMF + capture)
    ├── pcap-flows.py            # capture criteria: connection first payload byte 0x16 / plaintext credentials / :4420 count
    └── assets/BOOTX64-2.14-generic.EFI   # GRUB 2.14 artifact (measured boot baseline)
```

## Adaptation Status Overview

| Distribution | Version | Installation medium | Unattended | Customization script | Software source | Kernel | Acceptance status |
|---|---|---|---|---|---|---|---|
| Debian 12 | bookworm | netinst ISO | preseed (d-i) | `test/debian12/` | Alibaba Cloud (bookworm + backports) | 6.12.95+deb12-amd64 (backports) | ⚠️ 2026-11-27 reinstall + PXE TLS cold boot → login; requires a source-built NVMe userspace, costs in the [verification record](archive/debian12-tls-coldboot-verification.md) |
| Debian 13 | 13.6.0 | netinst ISO | preseed (d-i) | `test/debian13/` | Alibaba Cloud (trixie, no backports) | 6.12.94+deb13 (shipped) | ✅ 2026-09-10 PXE authenticated cold boot → login |
| Ubuntu 24.04 | 24.04.4 LTS | live-server ISO | autoinstall (subiquity) | `test/ubuntu2404/` | noble (deb822 ubuntu.sources) | 6.8 series (GA) | ✅ 2026-11-27 reinstall + PXE TLS cold boot → login |
| Ubuntu 26.04 | 26.04.1 LTS | live-server ISO | autoinstall (subiquity) | `test/ubuntu2604/` | suite detected at runtime (deb822) | 7.0.0-31-generic | ✅ 2026-09-11 PXE authenticated cold boot → login |
| Fedora 44 | 44 (Server DVD 1.7) | DVD ISO | kickstart (Anaconda) | `test/fedora44/` | dnf: Alibaba Cloud (fedora + updates) | 6.19.10-300.fc44 (shipped) | ✅ 2026-11-27 reinstall + PXE TLS cold boot → login |
| AlmaLinux 10.2 | 10.2 (minimal ISO) | minimal ISO | kickstart (Anaconda, HTTP) | `test/almalinux10/` | dnf: Huawei Cloud (BaseOS/AppStream/CRB/Extras) | 6.12.0-211.7.3.el10_2 (shipped, `CONFIG_NVME_TCP_TLS=y`) | ✅ 2026-10-31 PXE TLS cold boot → login (two rounds) |
| openSUSE Leap 16.0 | 16.0 (online installer) | online ISO (Agama) | Agama profile (`inst.auto=`) | `test/opensuse-leap16/` | zypper: TUNA OSS | 6.12.0-160000 (shipped, `CONFIG_NVME_TCP_TLS=y`) | ✅ 2026-10-31 PXE TLS cold boot → login |

Acceptance criteria (identical across distributions): the target logs **two** controller records — one
for the firmware segment and one for the kernel segment; authentication/encryption follows the path
delivered by the control plane: the DH-HMAC-CHAP path records `..., DH-HMAC-CHAP` and the TLS 1.3 path
records `..., TLS.`. The serial console shows a login prompt.
The TLS path adds a packet-capture criterion: the first payload byte of every client TCP connection to the data
port (4422/4421) is `0x16`, PSK and DH-HMAC-CHAP keys do not appear in plaintext payloads, and the
packet count to plaintext port 4420 is 0 (decided automatically by `test/shared/pcap-flows.py`, which
starts a connection at the client SYN and keeps later payload in the same connection across sequence
gaps, retransmissions and snaplen truncation).

> Native NBFT consumption ≠ native authentication: RHEL's `nm-initrd-generator`/`95nvmf` and SUSE's
> dracut `nvmf` can both establish the connection automatically from NBFT, but **the standard NBFT
> table carries neither DH-HMAC-CHAP keys nor TLS-PSK**, and their code path is the credential-less
> `nvme connect-all --nbft`. The `95nbft` in this repository consumes the custom **NBCT** table (which
> carries credentials) and issues `nvme connect --dhchap-secret/--tls` per entry; the build explicitly
> passes `--omit nvmf` so that the native module cannot establish an unauthenticated connection first.

## Distribution Differences

| Difference | Debian family (12 / 13) | Ubuntu family (24.04 / 26.04) |
|---|---|---|
| Installer | debian-installer | subiquity |
| Unattended data | preseed.cfg (served over HTTP) | autoinstall user-data + meta-data (nocloud-net HTTP) |
| APT configuration format | `/etc/apt/sources.list` (three lines) | deb822 (`ubuntu.sources` overwritten, original backed up as `.golden-bak`) |
| Kernel policy | 12 uses backports (newer kernel + NVMe-oF fixes); 13 uses the shipped kernel | the distribution's shipped kernel already meets the requirement |
| Version adaptation | separate variant (trixie sources, no backports step, etc.) | suite detected at runtime (`VERSION_CODENAME`, so no per-release pinning) |
| Installer-medium kernel extraction | install.amd/vmlinuz inside the ISO (preseed boots it directly) | casper/vmlinuz + casper/initrd (the 26.04.1 initrd has no `.gz` suffix) |
| Other points | volid 0x43 fix; 4K ESP rebuild (953 MiB FAT32) | 24.04 original ESP 106 MiB → rebuilt to 953 MiB; 26.04 installs 953 MiB by default (4K conversion only) |

### RHEL / SUSE Family Differences (relative to the preceding five)

| Difference | RHEL family (AlmaLinux 10.2) | SUSE family (openSUSE Leap 16.0) |
|---|---|---|
| Installer / unattended | Anaconda + kickstart (`inst.ks=http://…`) | Agama + JSON profile (`inst.auto=http://…`, `inst.finish=poweroff`) |
| Package management / sources | dnf; four-section mapping for BaseOS/AppStream/CRB/Extras (mirror directories use CamelCase) | zypper; `$releasever` retained, OSS overwritten to TUNA |
| initrd networking | dracut-107 has no systemd-networkd → `35network-manager` + `nm-initrd-generator` + `ip=dhcp` | dracut 059+suse likewise uses `35network-manager` (NetworkManager) |
| Native NBFT module | `95nvmf` + `nm-initrd-generator` (NBFT ≈ Technology Preview) | dracut `95nvmf` (SUSE extension) |
| Authentication in the native module | none: `nvme connect-all --nbft` (does not read DH-HMAC-CHAP/TLS-PSK) | none: likewise `connect-all --nbft` |
| Approach in this repository | `--omit nvmf`, install `95nbft` (NBCT → `connect --dhchap-secret/--tls`) | as at left |
| Kernel-side TLS components | `keyutils` + `ktls-utils` (tlshd 1.2.1); configuration file `/etc/tlshd.conf` | `keyutils` + `ktls-utils`; `/etc/tlshd.conf` |
| GnuTLS system policy | **`/etc/crypto-policies/back-ends/gnutls.config` must be installed into the initrd**, otherwise tlshd exits at startup with `gnutls -50` | as at left (installed when the file exists; absence is not fatal) |
| initrd path | `/boot/initramfs-<KVER>.img` | `/boot/initrd-<KVER>` (renamed to `initramfs-<KVER>` when copied into the ESP) |
| GRUB tools | `grub2-mkimage` / `grub2-mkconfig` | as at left |
| Layout constraints | XFS (the installation disk must be a 4K logical-block disk); this variant uses plain partitions (no LVM) | XFS; the Agama target disk must be blank (a leftover GPT makes the default `spacePolicy=keep` conflict with the explicit layout) |

## Adaptation Notes per Distribution

### Debian 12 (first closed-loop version, baseline)
- Medium: netinst + preseed automated installation; backports kernel (6.12 series, required for NVMe-oF authentication)
- Source switch: bookworm + bookworm-backports + security (Alibaba Cloud, ForceIPv4)
- Acceptance trajectory: 2026-11-27 real install + A–F + PXE TLS cold boot to login; requires a source-built NVMe userspace (`ktls-utils` / `libnvme` / `nvme-cli`), costs and limits in [debian12-tls-coldboot-verification.md](archive/debian12-tls-coldboot-verification.md)

### Debian 13 (netinst + separate variant script)
- Medium: netinst 13.6.0 + preseed; the kernel is the distribution's own (trixie 6.12 already satisfies the requirement)
- Differences from the debian12 variant: three-line trixie sources, no backports step, `KVER=$(uname -r)`

### Ubuntu 24.04 (cloud form retired → standard installation)
- Medium: live-server ISO + autoinstall (standard installation form, identical to a manual installation)
- Source switch: deb822 `ubuntu.sources` overwritten (noble + noble-security)
- Stage E: the original 106 MiB ESP is rebuilt as a 953 MiB 4K FAT32 ESP

### Ubuntu 26.04 (adaptation to autoinstall data-source and subiquity changes)
- Medium: live-server 26.04.1 ISO + autoinstall
- Three changes in 26.04 (the installation script must adapt; see the comments in `.cache/run-ubuntu2604-install.sh`):
  1. subiquity adds a `source` section (interactive) — autoinstall must provide
     `source: {id: ubuntu-server}` explicitly, otherwise the installer stops at the "installation type" interactive screen;
  2. with a direct QEMU `-kernel/-append` boot (no GRUB layer) the `ds` parameter must not carry the `\;` escape —
     use a bare semicolon, `ds=nocloud-net;s=http://<gateway>:<port>/`;
  3. the enumeration order of the two cdroms may be reversed (sr0=cidata / sr1=ISO) — `ds=nocloud;s=/dev/srN`
     is unreliable by device name, whereas the HTTP method is independent of device names.
- Source switch: suite detected at runtime (deb822), so no per-release codename pinning

### Fedora 44 (first dracut / XFS / LVM distribution)
- Medium: Server DVD + kickstart (HTTP, `inst.ks=`); **the installation must run on a 4K logical-block virtual disk** —
  the XFS sector size is fixed at mkfs time (following the device logical block size at that moment), and a 512-byte-sector
  XFS cannot be mounted on a 4096 logical-block device (the SAN 4K export) (`XFS: device supports 4096 byte sectors (not 512)`);
- Layout: XFS on LVM (the anaconda default) → the kernel parameters need `rd.lvm.lv=<VG>/<LV>`;
- initramfs: dracut 95nbft module (`module-setup.sh` + `nbft.sh` hooking both
  `initqueue/settled` and `pre-mount`, deduplicated through `/run/nbft-done`); it depends on the
  `dracut-network` and `systemd-networkd` packages (base dracut has no initrd networking module), and
  networking inside the initrd uses `09-nbft.network` (networkd, DHCP + KeepConfiguration);
- LVM activation: dracut's 64-lvm.rules hooks `initqueue --settled` (not executed in this scenario) →
  the hook runs `lvm vgchange -ay` explicitly after connecting; the initrd tool set must include
  `dd` (required by the nbft-connect field extractor; `--no-hostonly` does not include it by default);
- Tool name differences: `grub2-mkimage` / `grub2-mkconfig`; the initrd file is named
  `initramfs-<KVER>.img`.

### AlmaLinux 10.2 (first RHEL family)
- Medium: AlmaLinux 10.2 minimal ISO + kickstart (served over HTTP); the target disk is a 4K logical-block
  virtio-blk device (the same XFS installation constraint as Fedora 44).
- Boundary between kickstart and the minimal ISO: the 10.2 minimal repository **does not contain ktls-utils**;
  the kickstart uses `%packages --ignoremissing` and does not list that package; stage A then installs
  `keyutils ktls-utils` from the full image.
- initrd: dracut-107 **has no systemd-networkd** → `--add "nbft network network-manager"`,
  and `nm-initrd-generator` configures networking from `ip=dhcp`; **`--omit nvmf`** disables the native
  credential-less connection; `95nbft` hooks both `initqueue/settled` and `pre-mount` and deduplicates
  through `/run/nbft-done`.
- **crypto-policies is a hard dependency of the initrd**: the GnuTLS `@SYSTEM` default priority list comes from
  `/etc/crypto-policies/back-ends/gnutls.config`; dracut does not package that file by default, and when it is
  missing tlshd reports `gnutls: The request is invalid. (-50)` at startup and exits, after which
  `nvme connect --tls` fails with `failed to start TLS: -3` and the system enters emergency mode.
  The `module-setup.sh` of `95nbft` now resolves the symlink with `readlink -f` before installing the file
  (measured: 3384 B).
- Source switch: the section names in `/etc/yum.repos.d/almalinux*.repo` are lowercase (baseos/appstream/crb/extras)
  while the mirror directories use CamelCase (BaseOS/AppStream/CRB/extras) — the script rewrites them through an
  explicit mapping and disables the remaining repositories (including debuginfo).
- Shell portability of `nbft-connect`: RHEL has no dash, so stage A installs the script as
  `/usr/libexec/nbft-connect` and invokes it with **bash**; fixed-width NBCT field extraction now uses
  `dd | tr -d '\000'` (independent of any particular shell's NUL truncation semantics), and the unit test
  passes under dash as well.
- Acceptance trajectory (2026-10-31, QEMU/OVMF + isolated bridge `br-fwtest`, target `192.168.81.1:4422`
  tls1.3/required): both PXE cold boots reached `login:`; each round produced two
  `nvmet: Created nvm controller … , TLS.` lines on the target (firmware segment + kernel segment); in the
  capture all 4 client streams start with `0x16`, no PSK/DHHC plaintext appears, and the packet count to
  `:4420` is 0. The second round first re-ran customization with `--skip-disk --yes` (validating the ESP
  content refresh path). Evidence (worktree `diag/`, credential fields redacted): `alma10-boot.serial`,
  `alma10-tls-handshake.pcap`, `target-dmesg.txt`.
- Version boundary: 10.x is the representative version (6.12 kernel, measured `CONFIG_NVME_TCP_TLS=y`). RHEL 9.7
  **was not measured** — its kernel is the 5.14 series, NVMe/TCP TLS is an upstream 6.7+ feature, and whether
  Red Hat has backported it is unverified; to adopt 9.x, check `CONFIG_NVME_TCP_TLS` and the ktls-utils version first.

### openSUSE Leap 16.0 (first SUSE family)
- Medium: Leap 16.0 online installer (Agama) + JSON profile; the target disk is 4K logical-block and **blank**.
- Agama boundary: `inst.auto=<URL>` loads the profile (`inst.finish=poweroff`);
  a profile passing the JSON Schema (`agama config validate`) ≠ a computable storage plan — if the target disk retains
  an old GPT partition, the default `spacePolicy=keep` conflicts with the explicit ESP/`/` layout and the installer reports
  `Cannot calculate a valid storage setup`; the disk must be wiped before installing the golden image.
- initrd: dracut `059+suse` likewise uses `35network-manager`; **`--omit nvmf`**,
  `95nbft` connects per entry with credentials; `/etc/tlshd.conf` and the crypto-policies file are installed into the initrd;
  the dracut artifact is `/boot/initrd-<KVER>`, renamed to `initramfs-<KVER>` when copied into the ESP
  (matching the `initrd` line of `grub.cfg`).
- Acceptance trajectory (2026-10-31, QEMU/OVMF + isolated bridge, target `192.168.81.1:4423`
  tls1.3/required): Agama unattended installation → local `-kernel/-initrd` boot of the golden image to run A-F
  (ESP rebuilt as 4K FAT32, 953 MiB) → PXE cold boot to `login:`; the target logged two
  `nvmet: Created nvm controller … , TLS.` lines (firmware segment + kernel segment); in the capture all 4 client streams
  start with `0x16`, no credential plaintext appears, and the packet count to `:4420` is 0. The kernel-side tlshd is SUSE's
  ktls-utils 1.0.0-pre and logs `Handshake … was successful`.
  Evidence (worktree `diag/`, credential fields redacted): `leap16-boot.serial`,
  `leap16-tls-handshake.pcap`, `target-dmesg.txt`.

## Adaptation Procedure for a New Distribution (quick reference)

1. Derive the script from the closest existing variant (`test/<distro>/golden-image-setup-<distro>.sh`) and
   check every parameter: medium kernel/initrd file names, preseed/autoinstall/kickstart boot parameters and
   the package-manager source format; **use a 4K logical-block virtual disk for the target** (the XFS installation constraint);
2. Prepare the installation VM and the target raw disk (blank for the SUSE family); run the unattended installation through to automatic power-off;
3. Start the customization VM with `test/shared/golden-vm-run.sh` (or `golden-ubuntu-vm-run.sh`),
   scp the script and run A-F; `--skip-disk --yes` skips only the GPT/ESP rebuild and **still refreshes the ESP content**
   (kernel/initrd/BOOTX64/grub.cfg), ensuring the new initrd always lands on the ESP;
4. Isolated host-side acceptance (leaving the production br0/4421 untouched):
   ```bash
   sudo bash test/shared/fwtest-net.sh setup          # br-fwtest + tap0fw
   sudo bash test/shared/fwtest-nvmet-tls.sh setup <raw> <subnqn> <hostnqn> <DHHC> \
        192.168.81.1 4422 3                          # tls1.3 / treq=required
   TRSVCID=4422 bash test/shared/fwtest-boot.sh --nqn <subnqn> \
        --secret '<DHHC-1:..>' --psk <hex> --serial diag/x.serial --pcap diag/x.pcap
   python3 test/shared/pcap-flows.py diag/x.pcap --port 4422 --secret '<DHHC-1:..>' --psk <hex>
   ```
   Criteria: `login:` on the serial console; two `nvmet: Created nvm controller … , TLS.` lines in the host dmesg;
   script output `ALL_TLS_HANDSHAKE`, `plaintext_markers=none`, `packets_to_4420=0`.
   When the capture is large, add `PCAP_MAXLEN=160` (keep only headers and the handshake prefix);
5. After component changes, re-run `test/shared/embed-components.py` to refresh the embedded sections, then run
   `test/test-nbft-connect-nbct.sh` (dash by default; `SHELL_UNDER_TEST=bash` overrides to bash).

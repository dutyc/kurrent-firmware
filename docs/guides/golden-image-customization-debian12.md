# Golden Image Customization Guide (NVMe-oF SAN boot: customize once, clone and boot)

[English](golden-image-customization-debian12.md) | [中文](golden-image-customization-debian12.zh-CN.md)

> Status: a measured operational checklist derived from full-chain validation of the production boot chain (2026-08-25, [production-boot-verification.md](../archive/production-boot-verification.md)).
>
> Scope: a freshly installed Debian 12 golden image (virtual machine or physical machine image); once customized it can be cloned and distributed as a stateless boot golden image — the client carries no local medium, no identity information is fixed on the disk, and identity and credentials are injected from outside the boot chain.
>
> Related documents: [initramfs-nbft/README.md](../../initramfs-nbft/README.md) (seed module components), [golden-image-matrix.md](../golden-image-matrix.md) (per-distribution matrix and script locations), [production-boot-verification.md](../archive/production-boot-verification.md) (full-chain verification record), [customizations.md](../customizations.md) (firmware patch design).
>
> **Supported baseline (decision of 2026-08-27)**: Debian 12 (+ backports 6.12) and later, Ubuntu 24.04 LTS and later, RHEL 9 and later (AlmaLinux 10 and later; 10.2 measured), SLES 15 and later, openSUSE Leap 16 and later, Fedora 44 and later, Arch rolling. **Distributions below the baseline are not adapted** (details in Section 10).
>
> **Automation (since 2026-09-02)**: the six stages A–F are wrapped in the one-shot script [test/debian12/golden-image-setup-debian12.sh](../../test/debian12/golden-image-setup-debian12.sh); running `sudo bash test/debian12/golden-image-setup-debian12.sh` inside the golden image system performs the whole customization automatically (idempotent, re-runnable). The sections below retain the manual steps and the rationale as a reference for script behavior. Validation status: **measured end to end inside the target golden image VM in single-file self-contained form since 2026-09-08 (stages A–F including E, followed by SAN cold-boot acceptance to GDM)**; earlier trajectory: A–D+F through chroot (2026-09-02), local bootability through QEMU (2026-09-02, see 8.1).

## 1. Customization Overview

```
Freshly installed Debian 12
  → A. System and kernel (6.12 backports, with NVMe authentication)
  → B. initramfs seed module (initramfs-nbft: NBFT/NBCT consumption)
  → C. System configuration (fstab / network / hostname)
  → D. GRUB boot parameters (complete cmdline)
  → E. Disk format (4K native GPT + 4K FAT32 ESP)
  → F. Stateless verification (no identity information fixed on the disk)
  → Clone and distribute
```

Each stage states the "why": the three historical blocking points (`0x7f22208e`, `ret=401`, connection drop) each map to a specific step, and omitting one step reproduces them.

### 1.1 One-Shot Script (recommended)

All stages A–F are automated; **run as root inside the golden image system**:

```bash
# The script and the initramfs-nbft components must live in the same repository tree
# (by default initramfs-nbft at the repository root, two levels above test/<distro>/)
sudo bash test/debian12/golden-image-setup-debian12.sh          # full flow (stage E asks for confirmation)
sudo bash test/debian12/golden-image-setup-debian12.sh --yes    # stage E without interaction
sudo bash test/debian12/golden-image-setup-debian12.sh --skip-disk --yes  # skip the GPT/ESP rebuild (ESP content is still refreshed)
sudo bash test/debian12/golden-image-setup-debian12.sh --grub-efi /path/to/BOOTX64.EFI --yes  # inject a host-built 2.14 GRUB (see 6.3)
sudo bash test/debian12/golden-image-setup-debian12.sh -d /path/to/initramfs-nbft -k 6.12.95+deb12-amd64
```

Script behavior maps one-to-one onto the manual steps below and additionally performs three kinds of automatic handling:

- Commenting out the `deb cdrom:` apt sources left behind by the installer (in an environment without an optical drive, `apt-get update` fails hard);
- **Removing `quiet`** at the same time as the SAN parameters are appended to `GRUB_CMDLINE_LINUX_DEFAULT` (see Section 5);
- Switching apt sources to Alibaba Cloud by default (including backports, with the security suite derived from the same prefix; `--mirror` sets a custom mirror and `--keep-sources` keeps the original sources) and forcing IPv4 — in environments whose host has no IPv6, apt downloads of large files hang (measured).

**Single-file distribution (recommended for running directly inside a VM, without chroot)**: the script already embeds the three `initramfs-nbft` components and the GRUB 2.14 BOOTX64 artifact (base64) — **zero host dependencies**; a single `.sh` copied into the golden image (shared directory, scp, any channel) is enough to run it:

```bash
# host: re-embed after the components are updated
python3 test/shared/embed-components.py

# inside the golden image: run the single file directly (the embedded GRUB artifact is the default; --grub-efi overrides it explicitly; repository components take precedence when the repository component directory exists)
sudo bash golden-image-setup-debian12.sh --yes
```

Validation boundary: **stage E (disk format) must run against the target disk** (after the 4K conversion the disk is no longer readable in a 512 environment, which is the expected outcome for the SAN form); on 2026-09-08 the single-file form was measured end to end inside the target golden image VM (stages A–F including E, followed by PXE cold-boot acceptance to GDM).

### 1.2 Helper Script Set (test/shared/, common to all distributions, all measured)

Host-side helper scripts for golden image customization and acceptance:

| Script | Purpose |
|---|---|
| `golden-vm-run.sh <raw>` | Start the customization-stage VM (OVMF UEFI + slirp + 2222→22 forwarding + QMP) |
| `golden-vm-sendkey.py` | QMP→HMP keyboard injection (login and package-install channel when the VM has no sshd) |
| `golden-net-rebuild.sh` | Network rebuild after a host reboot (br0/tap0 + NAT, egress detected automatically) |
| `golden-nvmet-enable.sh <raw>` | nvmet namespace enablement (must run in the host mount namespace; a container namespace fails with -2) |
| `golden-esp-verify.sh <raw>` | 4K ESP content verification (512-byte logical sectors + offset loop mount; on a loop device with 4096-byte logical sectors vfat falsely reports an empty directory) |
| `embed-components.py` | Single-file script component/GRUB artifact packer (scans test/*/golden-image-setup-*.sh) |
| `assets/BOOTX64-2.14-generic.EFI` | Embedded GRUB 2.14 artifact (measured boot baseline) |

Acceptance (PXE cold boot) reuses the full-chain test script `run-kurrent-e2e.sh`.

## 2. A. System and Kernel

```bash
# after a minimal Debian 12 installation:
sudo apt install nvme-cli jq initramfs-tools

# bookworm-backports 6.12 kernel (required; rationale below)
sudo apt install -t bookworm-backports linux-image-6.12.95+deb12-amd64
```

- **Why 6.12**: the 6.1 kernel reports `CONFIG_NVME_AUTH is not set` and answers the ATR bit set in the nvmet `AUTH=1` response with `-EOPNOTSUPP`, so kernel-side authentication fails with `ret=401` (0x191). From 6.12 on, `CONFIG_NVME_AUTH=m` and the kernel-side DH-HMAC-CHAP negotiation proceeds normally.
- Verification: `grep CONFIG_NVME_AUTH /boot/config-$(uname -r)` should report `=m`.

## 3. B. initramfs Seed Module (initramfs-nbft)

The components come from `initramfs-nbft/` (the nbft-connect core script plus the initramfs-tools hook and local-top script):

```bash
# the local-top directory may not exist; create it first
sudo mkdir -p /usr/share/initramfs-tools/scripts/local-top

sudo install -m 0755 nbft-connect /usr/local/sbin/
sudo install -m 0755 initramfs/hooks/nbft /usr/share/initramfs-tools/hooks/
sudo install -m 0755 initramfs/scripts/local-top/nbft \
    /usr/share/initramfs-tools/scripts/local-top/

sudo update-initramfs -u
# verify that the components are in place
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'nbft|local-top'
```

### 3.1 hostid Fix (required in measurement)

Kernel nvme-fabrics host tracking rejects a custom hostnqn under the DMI default hostid (`found same hostid but different hostnqn`). `nbft-connect` must:

1. Fallback default: `HOSTID="${HOSTID:-11111111-2222-3333-4444-555555555555}"`
2. Explicit injection: `[ -n "$HOSTID" ] && cmd="${cmd} --hostid '${HOSTID}'"`

### 3.2 Runtime Constraints

- `nbft-connect` must run under **dash/ash** (the initramfs default `/bin/sh`): NBCT field extraction relies on command substitution truncating at the first NUL byte, whereas bash 4.4+ retains the NUL, so empty fields are misjudged;
- Optional: writing `NO_NBFT_IN_INITRAMFS=yes` into `/etc/initramfs-tools/conf.d/nvme-cli` disables packaging (matching open-iscsi's `NO_ISCSI_IN_INITRAMFS`).

## 4. C. System Configuration

### 4.1 fstab: fixed root UUID and commented-out /boot/efi

- The root partition is pinned by **UUID** in fstab (statically writable after cloning), for example:
  ```
  UUID=d0a8ebeb-202b-4481-9f52-9eae81af44be / ext4 defaults 0 1
  ```
- **Comment out the `/boot/efi` line** (`#UUID=855B-91DF /boot/efi vfat umask=0077 0 1`):
  - Why: in the SAN scenario the ESP is read exclusively by the firmware (iPXE/GRUB), so mounting it inside the system serves no purpose; if the line is not commented out, systemd fails to mount the 4K FAT ESP, `local-fs.target` fails and the system enters **emergency mode** (lesson from the measured round 11; the boot chain itself is unaffected but login is impossible).

### 4.2 Network: DHCP throughout the chain, no secondary HTTP credential fetch

```ini
# /etc/systemd/network/10-dhcp.network
[Match]
Name=e*

[Network]
DHCP=yes
```

- Why: at the initramfs stage `configure_networking` needs the same DHCP behavior as the system stage; credentials travel **in band** through the NBCT table (firmware → kernel), and a secondary HTTP credential fetch on the kernel side is prohibited;
- The kernel cmdline carries `ip=dhcp` accordingly (see Section D).

### 4.3 Hostname: Not Pinned

- The hostname inside the golden image is only a placeholder (for example `debian`); the production hostname is delivered by the control plane and is not the responsibility of the golden image.

## 5. D. GRUB Boot Parameters (complete set; none may be omitted)

```bash
# /etc/default/grub: append to GRUB_CMDLINE_LINUX_DEFAULT:
# remove the default quiet at the same time: quiet raises the console log level to WARNING
# and suppresses info-level kernel messages (including the nvme authentication success
# log) — acceptance criterion 1 in Section 8 requires the kernel-side authenticated line on the serial console
GRUB_CMDLINE_LINUX_DEFAULT="net.ifnames=0 biosdevname=0 ip=dhcp nbft_auto \
systemd.mask=NetworkManager.service systemd.mask=systemd-networkd.service"
sudo update-grub
```

| Parameter | Effect |
|---|---|
| `net.ifnames=0 biosdevname=0` | Stable NIC naming (interface names agree between the initramfs and systemd stages) |
| `ip=dhcp` | initramfs network configuration entry point (matches `configure_networking`) |
| `nbft_auto` | Enables automatic NBFT consumption (matches the semantics of iSCSI's `iscsi_auto`) |
| `systemd.mask=NetworkManager.service` `systemd.mask=systemd-networkd.service` | **Prevents connection drops**: when networkd takes over the NIC it resets TCP, keep-alive times out and a `no usable path` disconnect loop follows (lesson from the measured round 10). After masking, the `systemd-networkd-wait-online` "Dependency failed" message is expected and harmless |

## 6. E. Disk Format (SAN form, the most critical stage)

The nvmet file backend exports the image with **4096 B logical blocks** (`i_blkbits`), so the disk must have 4K semantics:

### 6.1 4K Native GPT

- Why: with a 512-byte-sector GPT the backup header and partition table are misplaced under 4K block semantics, EDK2 PartitionDxe cannot find the GPT, the ESP is not enumerated and sanboot fails with `0x7f22208e` (EFI_NOT_FOUND);
- Layout: GPT header @4096, partition table @8192, backup header at the end of the disk; partition byte ranges are unchanged;
- Conversion: reference implementation `diag/convert-gpt-4k.sh` (rewrites the GPT in python, automatically backs up the old GPT to `.gpt-512.bak` before conversion, then verifies the signature and CRC and spot-checks the FAT32 BPB, the ext4 magic and SWAPSPACE2).

### 6.2 4K FAT32 ESP (p1)

- volid `855B-91DF` (the value referenced by fstab), containing:
  - `vmlinuz-6.12.95+deb12-amd64` (the 6.12 kernel, corresponding to Section B)
  - `initrd.img-6.12.95+deb12-amd64` (**hostid-fixed build**; the initrd is a multi-segment structure: a leading 148480 B microcode segment followed by a zstd-compressed cpio segment; the concatenation formula is `segment 1 offset + segment 2 length`, and when replacing segment 2 use `cat segment1 zstd > new-initrd` rather than appending with `>>`)
  - `EFI/BOOT/BOOTX64.EFI` (GRUB 2.14, customized with `grub-mkimage`; version requirements and steps in 6.3)
  - `EFI/BOOT/grub.cfg` (SAN boot menu, see below)

- **Why `EFI/BOOT/BOOTX64.EFI` is mandatory**: the Debian installer writes only `EFI/debian/` (shim/grub) and does not create the `EFI/BOOT/` removable-media fallback. When the firmware has no persistent boot entry (fresh NVRAM, after clearing CMOS, or when the firmware rescans disks after iPXE `sanboot` completes), it looks for a loader only at the standard fallback path `\EFI\BOOT\BOOTX64.EFI`; if that file is absent the disk is skipped (measured: OVMF reports `BdsDxe: failed to load Boot0002 ... Not Found` and falls through to PXE). Stage E rebuilds the ESP and writes `EFI/BOOT/BOOTX64.EFI` with `grub-mkimage`, which is both the entry point for SAN cold boot and the file that lets the golden image boot locally on any UEFI machine (the local-boot validation of 2026-09-02 depends on it).
```cfg
# EFI/BOOT/grub.cfg reference
set default=0
set timeout=5
menuentry 'Debian GNU/Linux 12 (SAN, 6.12.95+deb12-amd64)' {
    search --no-floppy --fs-uuid --set=root 855B-91DF
    linux /vmlinuz-6.12.95+deb12-amd64 root=UUID=d0a8ebeb-202b-4481-9f52-9eae81af44be ro console=ttyS0,115200 net.ifnames=0 biosdevname=0 ip=dhcp nbft_auto systemd.mask=NetworkManager.service systemd.mask=systemd-networkd.service
    initrd /initrd.img-6.12.95+deb12-amd64
}
```

- Note: GRUB locates the ESP through `search --fs-uuid 855B-91DF`, so the volume label/UUID of the 4K FAT filesystem must agree with the commented-out fstab line and with grub.cfg.

### 6.3 GRUB 2.14 Customization (mandatory for SAN boot, measured 2026-09-04)

- **Why the distribution grub-mkimage cannot be used**: on the SAN boot path the BOOTX64.EFI produced by GRUB 2.06 shipped with Debian 12 hangs in measurement — after the firmware hands over to GRUB the menu freezes (search hangs, the keyboard does not respond). On the same disk, a host-built grub-mkimage 2.14 version boots all the way to GDM (re-verified once with credentials and once in plaintext). **The root cause is a defect in the distribution GRUB 2.06 itself (shim chain) and is unrelated to 4K logical blocks** (the earlier "GRUB is not 4Kn compatible" conclusion has been disproved).

- **Host-side generation (grub 2.14+, recommended)**:

  ```bash
  grub-mkimage -O x86_64-efi -o BOOTX64.EFI -p /EFI/BOOT \
      normal search search_fs_uuid part_gpt ext2 fat linux serial \
      search_fs_file search_fs_label halt reboot
  ```

  The module list is the minimal set that passed in the 2026-09-04 exercise; the list built into the one-shot script is a superset (adding xzio/gzio/terminal/echo/ls/test/part_msdos), and either is acceptable.

- **Two grub.cfg forms** (both measured):
  - **Inline form** (the stage E default of the one-shot script; suited to a freshly installed golden image): the menu entry carries the `linux`/`initrd` lines inline, see the reference in 6.2;
  - **Relay form** (suited to an existing disk with Debian already installed; the form used on the 9/4 golden disk): the embedded configuration only locates and hands over, while the full menu remains the `/boot/grub/grub.cfg` maintained on the disk by `update-grub`:

    ```cfg
    serial --unit=0 --speed=115200
    terminal_input serial console
    terminal_output serial console
    set timeout=3
    set default=0
    search.fs_uuid d0a8ebeb-202b-4481-9f52-9eae81af44be root
    set prefix=($root)'/boot/grub'
    configfile $prefix/grub.cfg
    ```

    Note that `search.fs_uuid` takes the **root partition UUID** (the same source as fstab), not the ESP volid.

- **One-shot script behavior**: `--grub-efi <file>` injects a host-built BOOTX64.EFI (skipping mkimage inside the golden image); without an injection the script checks `grub-mkimage --version` and, if it is < 2.12, exits with an error and two alternatives — it no longer silently produces a defective loader.

## 7. F. Stateless Verification (acceptance)

```bash
# no identity information is fixed on the disk: the following greps should return no hits
grep -rn "hostnqn\|dhchap\|secret\|kurrent:host" /etc /usr/local/sbin /usr/share/initramfs-tools 2>/dev/null
grep -n "HOSTNAME\|hostname" /etc/hostname /etc/hosts   # placeholder values only
```

- Identity (hostnqn / key / hostid) is injected from outside the boot chain: the control plane delivers boot-vars → the iPXE firmware consumes them → the NBCT table carries them in band → the kernel reuses them;
- hostid is the exception: `nbft-connect` carries a built-in default hostid as a fallback (Section B, 3.1), which belongs to the firmware-side contract and does not create an identity file on disk.

## 8. Clone-and-Boot Verification

### 8.1 Local Boot Pre-check (optional, after customization and before the 4K conversion)

While the image is still 512 GPT it can be booted locally once under QEMU/VMware to confirm that the customization itself is sound (reducing the variables of SAN acceptance):

- Prerequisite: `EFI/BOOT/BOOTX64.EFI` exists on the ESP (Section 6.2; the installer's original ESP needs a manual copy, or the local pre-check is skipped by proceeding to stage E);
- Criteria: the GRUB menu appears → the 6.12 kernel boots → the system starts (the VGA console shows `debian login:`; `Ctrl+Alt+F2` confirms the tty2 login prompt);
- Note: with `systemd.mask=NetworkManager/networkd` from the cmdline in effect, the network is not configured automatically in a local boot (in the SAN scenario the initramfs NBFT flow takes over and is unaffected); tty1 may be occupied by a program left over from the template without affecting the system.

On 2026-09-02 one round was performed on a VMware Debian 12 image customized through chroot: the boot chain was complete (OVMF → GRUB → 6.12 → initramfs → systemd → getty). Since 2026-09-08, `test/shared/golden-vm-run.sh` (OVMF + slirp + SSH forwarding) can boot the raw image for the same pre-check, and the customization script can be run fully automatically together with `golden-vm-sendkey.py` / the SSH channel (see 1.1/1.2).

### 8.2 SAN Cold-boot Acceptance (the final round before delivery to the main project)

After the golden image is written back to a disk, one QEMU + nvmet cold boot is performed (reproduction steps and criteria in [production-boot-verification.md](../archive/production-boot-verification.md) §5):

- Criterion 1: the serial console shows `qid 0: authenticated with hash hmac(sha256) dhgroup ffdhe4096` (once for the firmware segment and once for the kernel segment);
- Criterion 2: `nvme0n1: p1 p2 p3` → rootfs mounted → `Welcome to Debian` → `debian login:`;
- Criterion 3: no keep-alive errors and no emergency mode;
- pcap-level criterion: dual ATR (Connect RSP result bit17 `0x20000`) plus two rounds of AuthSend/AuthReceive with 4 PDUs each, all with status=0.

**Delivery precondition for use by the main project**: once customization (A–F) is complete and the 8.2 SAN cold-boot acceptance has passed, the golden image can be cloned and distributed for use by the main project. Stage E (4K conversion + ESP rebuild) is a mandatory step for SAN bootability and must be executed against the target disk — **the full flow was measured end to end on 2026-09-08: the single-file script inside the VM ran A–F including E, followed by SAN cold-boot acceptance to GDM** (see the update records below).

> **2026-09-04 update**: the core artifact form of stage E has been proven in practice — 4K GPT + 4K FAT32 ESP + a customized GRUB 2.14 BOOTX64.EFI boots all the way to the Debian 12 GDM against nvmet in strict mode (AUTH=1) (one round with credentials and one in plaintext); swapping the distribution 2.06 artifact back onto the same disk hangs immediately, confirming the version requirement of Section 6.3.
>
> **2026-09-08 update**: the one-shot script (single-file self-contained form, including the embedded components and GRUB artifact, the Alibaba Cloud sources and the volid 0x43 fix) has been measured end to end inside the target golden image VM — stages A–F including E, followed by PXE cold-boot acceptance to GDM.

## 9. Troubleshooting Quick Reference (the three historical blocking points)

| Symptom | Root cause | Fix |
|---|---|---|
| sanboot `0x7f22208e` (EFI_NOT_FOUND) | 512-byte-sector GPT vs nvmet 4096 B blocks | 4K native GPT, Section 6.1 |
| Kernel segment `ret=401` (AUTH_REQUIRED) | the kernel lacks CONFIG_NVME_AUTH | 6.12 backports, Section 2 |
| keep-alive disconnect loop `-101` after login | the systemd network takeover resets TCP | cmdline mask, Section 5 |
| boot-efi.mount fails → emergency | fstab does not comment out /boot/efi | comment it out, Section 4.1 |
| OVMF reports `failed to load Boot0002 ... Not Found` and falls through to PXE | the ESP has no `EFI/BOOT/BOOTX64.EFI` fallback (the installer writes only `EFI/debian/`, confirmed by the local-boot validation of 2026-09-02) | stage E rebuilds the ESP and writes BOOTX64.EFI, Section 6.2 |
| the kernel-segment `authenticated` line is missing from the serial console (only one occurrence, for the firmware segment) | the cmdline carries `quiet` (console log level raised to WARNING) | remove quiet in stage D, Section 5 |
| GRUB hangs after the menu appears (search hangs, the keyboard does not respond) | defect in the distribution grub-mkimage 2.06 artifact (shim chain, SAN path; unrelated to 4K logical blocks, measured 2026-09-04) | 2.14 customization, Section 6.3 (`--grub-efi` injection or grub-efi ≥ 2.12 in the golden image) |

## 10. Cross-Distribution Support Status (supported baseline)

> **Decision (2026-08-27)**: distributions below the baseline in each row of the table are not adapted. Existing validation results are retained, but no new adaptation work is invested; when a distribution moves to a new major version, the baseline moves up with it.

| Distribution | Supported baseline | Kernel | Kernel-side authentication (NVME_AUTH) | NBFT/initramfs boot | Golden image conclusion |
|---|---|---|---|---|---|
| **Debian** 12 bookworm | 12.x | 6.1 (backports 6.12 required) | ✗ not enabled on 6.1 (measured `ret=401`), enabled from 6.12 | ✗ initramfs-tools has no NBFT | backports 6.12 + seed module required (the path measured in this project) |
| **Debian** 13 trixie | 13.x | 6.12.69+ (the 6.17 series is available) | ✓ `nvme_auth` module confirmed | ✗ as above | **no kernel change**, seed module only |
| **Ubuntu** 24.04 LTS | 24.04.x | 6.8 | ✓ | ✗ seed module required | seed module required |
| **Ubuntu** 26.04 LTS | 26.04 | **7.0** | ✓ (confirmed by local `lsmod` on the host) | ✗ | seed module required |
| **RHEL** 9 | 9.x | 5.14 | ✓ the official documentation includes an authentication configuration chapter | dracut 95nvmf conventional boot | relies on official components |
| **RHEL** 10 | 10.x | **6.12** | ✓ dedicated official chapter (Section 12.3, "Configuring NVMe host authentication") | as above | relies on official components |
| **SLES** 15 | SP5–SP7 | 6.4 | ✓ | ✓ official documentation: boots automatically once installed (nvme-stas 2.3+ as the NBFT configuration source) | **works out of the box** |
| **SLES** 16 | 16.x | **6.16** | ✓ | ✓ same origin | **works out of the box** |
| **openSUSE** Leap 16 | 16.x | 6.16 (updatable to 7.0) | ✓ | ✓ same origin as SLES | **works out of the box** |
| **openSUSE** Tumbleweed | rolling | 7.x | ✓ | ✓ | **works out of the box** |
| **Fedora** | 44+ | **7.0.9** | ✓ | dracut 74nvmf (dracut-network subpackage) + locally built 95nbft module | ✅ measured (2026-09-12 cold-boot acceptance, see the [distribution matrix](../golden-image-matrix.md)) |
| **Arch** | rolling | 7.x | ✓ | nvme-cli 2.16 `nvmf-autoconnect` | partial |

### Ecosystem-Level Facts (as of 2026-08)

- **Kernel authentication**: mainline has carried `CONFIG_NVME_AUTH` since 6.0, and every LTS (5.10/5.15/6.1/6.6/6.12) has backported it since 2023-09 — **whether a distribution enables it is the actual variable** (Debian 12's 6.1 is the counterexample, where it is not enabled);
- **NBFT consumption ecosystem**: led by SUSE (nvme-stas 2.3 uses NBFT as a configuration source; dracut 95nvmf includes NBFT parsing); nvme-cli 2.5+ provides `nvme nbft show`; NBFT support in the systemd initrd is still an unmerged RFE (systemd #36443);
- **For this project**: the seed module (initramfs-nbft) is mandatory on **every non-SUSE distribution**; Debian 13 and Ubuntu 26.04 can reuse the existing `nbft-connect` directly, without the 6.12 backports step; the Fedora 44, AlmaLinux 10.2 and openSUSE Leap 16.0 variants have been measured — a locally built dracut `95nbft` module wraps the same `nbft-connect` (Fedora uses `dracut-network` / `systemd-networkd`; the RHEL and SUSE families use NetworkManager; RHEL/SUSE must install crypto-policies' `gnutls.config` into the initrd; an XFS golden image must be installed on a 4K logical-block disk).

## 11. References

- `diag/convert-gpt-4k.sh` (4K GPT conversion reference implementation), `diag/esp4k-prod.img` (4K FAT32 ESP reference artifact), `diag/grub-prod.cfg` (GRUB menu reference), `diag/initrd-612-hostid.img` (hostid-fixed initrd reference)
- [production-boot-verification.md](../archive/production-boot-verification.md) (full-chain verification evidence)
- [initramfs-nbft/README.md](../../initramfs-nbft/README.md) (seed component installation and testing)

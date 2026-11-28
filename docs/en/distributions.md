# Distribution Matrix

[English](distributions.md) | [中文](../zh/distributions.md)

Each distribution has one self-contained `golden/<distro>/golden-image-setup-<distro>.sh`
that runs the shared A–F customization flow; the host-side helpers and the
packer live under `golden/shared/`. Every script embeds the `initramfs-nbft`
components and the GRUB 2.14 artifact, so a single file can be copied into a
golden image and run. After a component change, re-run
`python3 golden/shared/embed-components.py`.

## Supported distributions

| Distribution | Version | Kernel | Acceptance |
|---|---|---|---|
| Debian 12 | bookworm | 6.12 (backports) | ⚠️ TLS cold boot; source-built NVMe userspace required |
| Debian 13 | 13.6.0 | 6.12 (shipped) | ✅ authenticated cold boot |
| Ubuntu 24.04 | 24.04 LTS | 6.8 (GA) | ✅ TLS cold boot |
| Ubuntu 26.04 | 26.04 LTS | 7.0 (shipped) | ✅ authenticated cold boot |
| Fedora 44 | 44 | 6.19 (shipped) | ✅ TLS cold boot |
| AlmaLinux 10.2 | 10.2 | 6.12 (`CONFIG_NVME_TCP_TLS=y`) | ✅ TLS cold boot |
| openSUSE Leap 16.0 | 16.0 | 6.12 (`CONFIG_NVME_TCP_TLS=y`) | ✅ TLS cold boot |
| Arch Linux | rolling (2026.11.01 ISO) | 7.3.6-arch1-1 | ✅ TLS cold boot |

Acceptance runs use each distribution's native unattended installation, but
installer inputs are not deliverables of this repository. Three acceptance
fixtures stay in the tree: `golden/almalinux10/almalinux10.ks.in`,
`golden/archlinux/archinstall.json.in` and
`golden/opensuse-leap16/leap16-profile.json`. Installation follows the
operator's own process, and A–F starts from an installed system.

Debian 12 needs a source-built NVMe userspace (`ktls-utils` / `libnvme` /
`nvme-cli`) because bookworm has no packaged TLS-capable tooling; the costs are
recorded in the [verification record](../zh/archive/debian12-tls-coldboot-verification.md).

Arch Linux is rolling; the matrix pins the 2026.11.01 ISO and kernel
7.3.6-arch1-1 as the tested baseline. There is no TLS-capable `ktls-utils`
package either, so the setup script builds 1.5.0 from a pinned tag and commit.
The initramfs uses mkinitcpio hooks (`install/nbft`, `hooks/nbft`) with
`autodetect` removed and obtains its lease through `dhcpcd`.

## Acceptance criteria

The target logs **two** controller records — one for the firmware segment, one
for the kernel segment. The DH-HMAC-CHAP path records `..., DH-HMAC-CHAP`; the
TLS path records `..., TLS.` and adds a capture criterion: every client
connection to the data port starts with `0x16` and the packet count to
plaintext port 4420 is 0 (decided by `test/shared/pcap-flows.py`). The serial
console shows a login prompt.

## A–F customization flow

| Stage | Content |
|---|---|
| A | System and kernel (backports kernel where required; `ktls-utils` / `keyutils`) |
| B | `initramfs-nbft` seed module (NBFT/NBCT consumption, hostid fix) |
| C | System configuration (fstab root UUID, DHCP, hostname placeholder) |
| D | GRUB boot parameters (`net.ifnames=0 ip=dhcp nbft_auto` + initrd module masks) |
| E | Disk format (4K-native GPT + 4K FAT32 ESP + GRUB; interactive confirm) |
| F | Statelessness check (no hardcoded identity) |

Stage E converts the disk to 4K semantics; afterwards the disk is readable only
as a SAN 4K export or on a 4Kn device. `--skip-disk --yes` skips only the
GPT/ESP rebuild and still refreshes the ESP content.

## Adding a distribution

1. Derive the script from the closest existing variant and check every parameter
   (installer kernel/initrd names, boot arguments when using an unattended
   installer, package-manager source format). Use a 4K logical-block disk for the target.
2. Install with your own process and power off.
3. Start the customization VM with `golden/shared/golden-vm-run.sh` (or
   `golden-ubuntu-vm-run.sh`), copy the script in and run A–F.
4. Run the isolated host-side acceptance (see [verification.md](verification.md));
   the production bridge and port stay untouched.
5. Re-embed components after changes and run `test/test-nbft-connect-nbct.sh`.

Per-distribution troubleshooting notes are kept in the archive.

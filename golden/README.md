# golden

Provisioning assets for the distribution golden images. Each `golden/<distro>/`
directory holds that distribution's `golden-image-setup-*.sh`, which runs the
shared A–F customization stages; three directories also keep the installer
inputs used as acceptance fixtures, which are not deliverables.
`golden/shared/` holds the common library, the host-side VM helpers, the embed
tooling and the GRUB image that the scripts embed.

Tests, QEMU ranges, capture analysis and fixtures stay under `test/`. The
distribution matrix and the A–F flow are documented in
[docs/zh/distributions.md](../docs/zh/distributions.md) and
[docs/en/distributions.md](../docs/en/distributions.md).

After changing a component, re-embed the single-file payloads and verify them:

```bash
python3 golden/shared/embed-components.py
python3 test/shared/verify-embed.py
```

# golden

Provisioning assets for the distribution golden images. Each `golden/<distro>/`
directory holds that distribution's `golden-image-setup-*.sh` template, whose
`EMBED_B64_*` variables are empty. Build-time generation fills them from the
repository sources and the pinned GRUB image and writes a single-file script
under `dist/golden/`; the CI `golden` job uploads that directory with
`SHA256SUMS` as the `golden-image-setup` build artifact. `golden/archlinux/`
additionally ships `mkinitcpio-nbft/`. Installer inputs and local VM helpers are
not shipped with the repository. `golden/shared/` holds the common library,
the lock file, the build tooling and the generator.

The GRUB image is not tracked. `golden/shared/build-grub-efi.sh` downloads
`BOOTX64-2.14-generic.EFI` from the `grub-efi-2.14` Release and verifies the
SHA-256 recorded in `golden/shared/grub-efi.lock`; `--from-file` accepts a
local copy and `--rebuild` rebuilds it from the pinned Ubuntu package.

```bash
bash golden/shared/build-grub-efi.sh
python3 golden/shared/embed-components.py
python3 test/shared/verify-embed.py
```

Generated scripts remain self-contained: copy one into the golden image and run
it there. Tests, QEMU ranges, capture analysis and fixtures stay under `test/`.
The distribution matrix and the A–F flow are documented in
[docs/zh/distributions.md](../docs/zh/distributions.md) and
[docs/en/distributions.md](../docs/en/distributions.md).

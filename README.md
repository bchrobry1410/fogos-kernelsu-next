# KernelSU Next for Motorola fogos (VoltageOS 6.2 port by shipu07)

GitHub Actions setup that builds a KernelSU Next–enabled kernel for the
Moto G34 / G45 5G (`fogos`), using the same kernel base as the VoltageOS fogos
port by shipu07.

## What it does

1. Clones `Motorola-SM6375-Devs/android_kernel_motorola_sm6375` (branch
   `sixteen`, kernel 5.4.302).
2. Injects the official [`KernelSU-Next/KernelSU-Next`](https://github.com/KernelSU-Next/KernelSU-Next)
   driver using its own `setup.sh`, pinned to a **legacy** tag suitable for
   non-GKI 5.4 kernels (`v3.4.0-legacy` by default).
3. Applies 5.4 compatibility fixes (`<asm/pgtable.h>`, `strncpy_from_user`).
4. Enables `CONFIG_KSU=y` with syscall-table hooking (no manual kernel source
   hooks required) plus the defconfig options used by the VoltageOS port.
5. Builds with AOSP Clang and packages an AnyKernel3 flashable zip.

## Using it

Push this directory as a GitHub repository, then run **Actions → Build fogos
kernel with KernelSU Next → Run workflow**. Inputs:

| Input | Default | Notes |
| --- | --- | --- |
| `kernel_branch` | `sixteen` | `sixteen` = 5.4.302 (matches the stock `5.4.302-moto-g...` build) |
| `ksu_tag` | `v3.4.0-legacy` | Legacy tags are for non-GKI/5.4; `v3.4.2` is the current GKI-oriented release |
| `ksu_hook` | `syscall-table` | Works on ARM64 5.4 without source patches; `manual` needs hook patches |
| `enable_susfs` | `false` | Optional SuSFS 5.4 patches |

The flashable zip is uploaded as a workflow artifact named
`fogos-KernelSU-Next`.

## Manager

Install the matching KernelSU Next manager build for the selected tag
(e.g. v3.4.0). The driver and manager versions must agree.

## Notes / caveats

- The base tree is a unified holi/fogos kernel. The script auto-detects the
  first available defconfig among `vendor/fogos_defconfig`,
  `vendor/moto-holi-fogos.config`, `vendor/holi-perf_defconfig` and
  `vendor/holi-qgki_defconfig`; on branch `sixteen` it will pick
  `vendor/holi-qgki_defconfig`.
- A local build is possible with `bash scripts/integrate_and_build.sh` after
  installing the toolchain and exporting `CLANG_DIR`, but GitHub Actions is the
  intended path.
- Kernel source and modules remain GPLv2/GPLv3 as upstream; respect the
  licenses of all injected components.

#!/usr/bin/env bash
# Integrate KernelSU Next into the VoltageOS (shipu07) fogos kernel and build it.
# Intended to run inside GitHub Actions, but works in any Ubuntu-like environment
# with the toolchain already installed.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment variables)
# ---------------------------------------------------------------------------
BASE_REPO="${BASE_REPO:-Motorola-SM6375-Devs/android_kernel_motorola_sm6375}"
BASE_BRANCH="${BASE_BRANCH:-sixteen}"          # sixteen == 5.4.302
KSU_TAG="${KSU_TAG:-v3.4.0-legacy}"            # legacy tags target non-GKI 5.4
KSU_HOOK="${KSU_HOOK:-syscall-table}"          # syscall-table | manual
KERNEL_DIR="${KERNEL_DIR:-kernel}"
CLANG_DIR="${CLANG_DIR:-clang}"
OUTPUT_ZIP="${OUTPUT_ZIP:-fogos-KernelSU-Next.zip}"
ENABLE_SUSFS="${ENABLE_SUSFS:-false}"

log() { printf '\n[ksu-fogos] %s\n' "$*"; }
die() { printf '\n[ksu-fogos] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Base kernel source
# ---------------------------------------------------------------------------
log "Cloning base kernel ${BASE_REPO} (${BASE_BRANCH})"
if [ ! -d "${KERNEL_DIR}/.git" ]; then
    git clone --depth=1 -b "${BASE_BRANCH}" \
        "https://github.com/${BASE_REPO}.git" "${KERNEL_DIR}"
else
    log "Reusing existing checkout at ${KERNEL_DIR}"
fi

cd "${KERNEL_DIR}"

# ---------------------------------------------------------------------------
# 2. Inject official KernelSU Next
# ---------------------------------------------------------------------------
log "Injecting KernelSU Next ${KSU_TAG}"
curl -LSs \
    "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/${KSU_TAG}/kernel/setup.sh" \
    | bash -s "${KSU_TAG}"

[ -d drivers/kernelsu ] || die "KernelSU driver was not installed at drivers/kernelsu"

# Linux 5.4 compatibility adjustments used by the VoltageOS fogos kernel.
log "Applying Linux 5.4 compatibility fixes"
# -L is required because setup.sh installs drivers/kernelsu as a symlink.
find -L drivers/kernelsu -type f \( -name '*.c' -o -name '*.h' \) -print0 \
    | xargs -0 sed -i \
        -e 's|#include <linux/pgtable.h>|#include <asm/pgtable.h>|g' \
        -e 's/strncpy_from_user_nofault(\([^,]*\),\([^,]*\),\([^)]*\))/strncpy_from_user(\1, \2, \3)/g'

# Optional SuSFS (kept off by default; enable only if you have the matching manager).
if [ "${ENABLE_SUSFS}" = "true" ]; then
    log "Injecting SuSFS (5.4)"
    git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git -b kernel-5.4 susfs || \
        log "SuSFS clone failed; continuing without it"
    if [ -d susfs/kernel_patches ]; then
        cp -r susfs/kernel_patches/fs ./
        cp -r susfs/kernel_patches/include ./
        patch -p1 < susfs/kernel_patches/50_add_susfs_in_kernel-5.4.patch || \
            log "SuSFS patch did not apply cleanly; continuing"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Pick the device defconfig and append the KernelSU config fragment
# ---------------------------------------------------------------------------
DEFCONFIG_PATH=""
for candidate in \
    arch/arm64/configs/vendor/fogos_defconfig \
    arch/arm64/configs/vendor/moto-holi-fogos.config \
    arch/arm64/configs/vendor/holi-perf_defconfig \
    arch/arm64/configs/vendor/holi-qgki_defconfig; do
    if [ -f "${candidate}" ]; then
        DEFCONFIG_PATH="${candidate}"
        break
    fi
done
[ -n "${DEFCONFIG_PATH}" ] || die "No known fogos/holi defconfig found"
DEFCONFIG_NAME="${DEFCONFIG_PATH#arch/arm64/configs/}"
log "Using defconfig ${DEFCONFIG_NAME}"

# Avoid duplicate entries when the script is re-run on an existing tree.
sed -i '/^# >>> KernelSU Next >>>$/,/^# <<< KernelSU Next <<<$/{d}' "${DEFCONFIG_PATH}"
cat >> "${DEFCONFIG_PATH}" <<EOF
# >>> KernelSU Next >>>
CONFIG_KSU=y
CONFIG_KPROBES=y
CONFIG_EXT4_FS=y
EOF

case "${KSU_HOOK}" in
    syscall-table)
        cat >> "${DEFCONFIG_PATH}" <<'EOF'
CONFIG_KSU_SYSCALL_TABLE_HOOK=y
EOF
        ;;
    manual)
        cat >> "${DEFCONFIG_PATH}" <<'EOF'
CONFIG_KSU_MANUAL_HOOK=y
EOF
        ;;
    *)
        die "Unknown KSU_HOOK: ${KSU_HOOK}"
        ;;
esac

cat >> "${DEFCONFIG_PATH}" <<'EOF'
# Kernel / ROM extras
CONFIG_TCP_CONG_BBR=y
CONFIG_DEFAULT_BBR=y
CONFIG_WIREGUARD=y
CONFIG_ZRAM=y
CONFIG_CRYPTO_LZ4=y
CONFIG_LZ4_COMPRESS=y
CONFIG_LZ4_DECOMPRESS=y
CONFIG_ZRAM_DEF_COMP_LZ4=y
CONFIG_OVERLAY_FS=y
CONFIG_EROFS_FS=y
CONFIG_EROFS_FS_ZIP=y
CONFIG_EROFS_FS_LZ4=y
# <<< KernelSU Next <<<
EOF

# ---------------------------------------------------------------------------
# 4. Build
# ---------------------------------------------------------------------------
cd ..
export PATH="${PWD}/${CLANG_DIR}/bin:${PATH}"
export ARCH=arm64 SUBARCH=arm64
export CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm
export OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export CLANG_TRIPLE=aarch64-linux-gnu-

BUILD_ARGS=(
    -j"$(nproc --all)"
    O=out
    ARCH=arm64
    CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm
    OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
    CLANG_TRIPLE=aarch64-linux-gnu-
)

log "Generating defconfig"
make -C "${KERNEL_DIR}" "${BUILD_ARGS[@]}" "${DEFCONFIG_NAME}"

log "Compiling kernel"
if ! make -C "${KERNEL_DIR}" "${BUILD_ARGS[@]}" Image.gz-dtb; then
    log "Image.gz-dtb failed, retrying with Image"
    make -C "${KERNEL_DIR}" "${BUILD_ARGS[@]}" Image
fi

# ---------------------------------------------------------------------------
# 5. Package with AnyKernel3
# ---------------------------------------------------------------------------
log "Packaging ${OUTPUT_ZIP}"
[ -d AnyKernel3 ] || git clone --depth=1 https://github.com/osm0sis/AnyKernel3 AnyKernel3
cd AnyKernel3
sed -i 's/device.name1=.*/device.name1=fogos/' anykernel.sh
sed -i 's/device.name2=.*/device.name2=Moto G34 5G/' anykernel.sh

if [ -f "../${KERNEL_DIR}/out/arch/arm64/boot/Image.gz-dtb" ]; then
    cp "../${KERNEL_DIR}/out/arch/arm64/boot/Image.gz-dtb" ./
elif [ -f "../${KERNEL_DIR}/out/arch/arm64/boot/Image" ]; then
    cp "../${KERNEL_DIR}/out/arch/arm64/boot/Image" ./
else
    die "No kernel image was produced"
fi

rm -f "../${OUTPUT_ZIP}"
zip -r9 "../${OUTPUT_ZIP}" * -x .git README.md
cd ..
log "Done: ${OUTPUT_ZIP}"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"
KERNEL_DIR="$ROOT_DIR/common"
OUT_DIR="$KERNEL_DIR/out"
TOOLCHAIN_DIR="$ROOT_DIR/prebuilts/clang/host/linux-x86/clang-r450784e/bin"
KERNEL_TOOLS_DIR="$ROOT_DIR/prebuilts/kernel-build-tools/linux-x86/bin"
TARGET_DEFCONFIG="${TARGET_DEFCONFIG:-kalama_gki_defconfig}"
JOBS="${JOBS:-2}"
LTO="${LTO:-thin}"

# Stock SM-X710 / X710ZCU5CYH4 kernel identity captured from the device.
# Keep these separate from optimization choices: Thin/Full LTO must never
# leak into uname -r or Samsung Settings' kernel-version parser.
BUILD_NUMBER="${BUILD_NUMBER:-X710ZCU5CYH4}"
GOOGLE_BRANCH="${GOOGLE_BRANCH:-android13-5.15}"
KMI_GENERATION="${KMI_GENERATION:-8}"
STOCK_LOCALVERSION="${STOCK_LOCALVERSION:--2370170}"
STOCK_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Wed Aug 20 08:06:12 UTC 2025}"
KBUILD_BUILD_VERSION="${KBUILD_BUILD_VERSION:-1}"
EXPECTED_RELEASE="5.15.153-android13-${KMI_GENERATION}${STOCK_LOCALVERSION}-ab${BUILD_NUMBER}"
EXPECTED_UTS_VERSION="#${KBUILD_BUILD_VERSION} SMP PREEMPT ${STOCK_TIMESTAMP}"

export PATH="$TOOLCHAIN_DIR:$KERNEL_TOOLS_DIR:$PATH"
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export BUILD_NUMBER
export GOOGLE_BRANCH
export KMI_GENERATION
export KBUILD_BUILD_VERSION
export KBUILD_BUILD_TIMESTAMP="$STOCK_TIMESTAMP"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-wnotms}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-github-actions}"

# Deliberately keep the make-time LOCALVERSION empty. Samsung's
# scripts/setlocalversion constructs the stock suffix from GOOGLE_BRANCH,
# KMI_GENERATION, CONFIG_LOCALVERSION and BUILD_NUMBER.
export LOCALVERSION=""

case "$LTO" in
  thin|full)
    ;;
  *)
    echo "::error::Unsupported LTO mode: $LTO"
    exit 1
    ;;
esac

cd "$KERNEL_DIR"
rm -rf "$OUT_DIR"

MAKE_ARGS=(
  "CC=clang"
  "ARCH=arm64"
  "LLVM=1"
  "LLVM_IAS=1"
  "GOOGLE_BRANCH=$GOOGLE_BRANCH"
  "KMI_GENERATION=$KMI_GENERATION"
  "LOCALVERSION="
)

echo "==> Generate config: $TARGET_DEFCONFIG"
make -j"$JOBS" O=out "${MAKE_ARGS[@]}" "$TARGET_DEFCONFIG"

# Reproduce the stock Samsung kernel release exactly:
#   5.15.153-android13-8-2370170-abX710ZCU5CYH4
# CONFIG_LOCALVERSION contributes only "-2370170". Android release, KMI
# generation and -ab<BUILD_NUMBER> are added by Samsung setlocalversion.
./scripts/config --file out/.config --set-str LOCALVERSION "$STOCK_LOCALVERSION"
./scripts/config --file out/.config -d LOCALVERSION_AUTO

# Samsung hardening/options that this source tree's custom build path already
# disables. Keep the existing behavior to avoid introducing unrelated boot
# regressions while fixing the kernel identity.
./scripts/config --file out/.config \
  -d UH \
  -d RKP \
  -d KDP \
  -d SECURITY_DEFEX \
  -d INTEGRITY \
  -d FIVE \
  -d TRIM_UNUSED_KSYMS

# Droidspaces/container support.
./scripts/config --file out/.config \
  -e SYSCTL \
  -e SYSVIPC \
  -e POSIX_MQUEUE \
  -e NAMESPACES \
  -e PID_NS \
  -e UTS_NS \
  -e IPC_NS \
  -e USER_NS \
  -e NET_NS \
  -e SECCOMP \
  -e SECCOMP_FILTER \
  -e CGROUPS \
  -e CGROUP_DEVICE \
  -e CGROUP_PIDS \
  -e MEMCG \
  -e CGROUP_SCHED \
  -e FAIR_GROUP_SCHED \
  -e CGROUP_FREEZER \
  -e DEVTMPFS \
  -e OVERLAY_FS \
  -e VETH \
  -e BRIDGE \
  -e NETFILTER \
  -e BRIDGE_NETFILTER \
  -e NF_CONNTRACK \
  -e IP_NF_IPTABLES \
  -e IP_NF_FILTER \
  -e NF_NAT \
  -e NF_TABLES \
  -e IP_NF_TARGET_MASQUERADE \
  -e NETFILTER_XT_TARGET_MASQUERADE \
  -e NETFILTER_XT_TARGET_TCPMSS \
  -e NETFILTER_XT_MATCH_ADDRTYPE \
  -e NF_CONNTRACK_NETLINK \
  -e NF_NAT_REDIRECT \
  -e IP_ADVANCED_ROUTER \
  -e IP_MULTIPLE_TABLES

if [[ "$LTO" == "thin" ]]; then
  ./scripts/config --file out/.config -e LTO_CLANG_THIN -d LTO_CLANG_FULL
else
  ./scripts/config --file out/.config -e LTO_CLANG_FULL -d LTO_CLANG_THIN
fi

make -j"$JOBS" O=out "${MAKE_ARGS[@]}" olddefconfig

# Fail early if Kconfig normalization changed the stock identity settings.
if ! grep -q '^CONFIG_LOCALVERSION="-2370170"$' out/.config; then
  echo "::error::CONFIG_LOCALVERSION was not preserved as -2370170"
  grep '^CONFIG_LOCALVERSION' out/.config || true
  exit 1
fi
if grep -q '^CONFIG_LOCALVERSION_AUTO=y$' out/.config; then
  echo "::error::CONFIG_LOCALVERSION_AUTO must be disabled for a deterministic stock release"
  exit 1
fi

# This tree carries the SYSVIPC task_struct compatibility patch required when
# SYSVIPC is enabled on the Android GKI kernel. Do not silently continue with
# an unknown layout: that can produce a kernel with a vendor-module ABI break.
PATCH_FILE="$KERNEL_DIR/0001-ANDROID-sched-Move-SYSVIPC-fields-to-the-end-of-task.patch"
if [[ -f "$PATCH_FILE" ]]; then
  if patch --dry-run -p1 < "$PATCH_FILE" >/dev/null 2>&1; then
    echo "==> Applying SYSVIPC task_struct compatibility patch"
    patch -p1 < "$PATCH_FILE"
  elif patch --dry-run -R -p1 < "$PATCH_FILE" >/dev/null 2>&1; then
    echo "==> SYSVIPC compatibility patch already applied"
  else
    echo "::error::SYSVIPC compatibility patch state is unknown; refusing to build"
    exit 1
  fi
else
  echo "::error::Missing SYSVIPC compatibility patch: $PATCH_FILE"
  exit 1
fi

# Verify kernel.release before spending time on the full build. The kernelrelease
# target prints the release to stdout but does not guarantee that
# out/include/config/kernel.release already exists at this stage.
ACTUAL_RELEASE="$(make -s O=out "${MAKE_ARGS[@]}" kernelrelease | tail -n 1)"
echo "==> Expected kernel.release: $EXPECTED_RELEASE"
echo "==> Actual   kernel.release: $ACTUAL_RELEASE"
if [[ "$ACTUAL_RELEASE" != "$EXPECTED_RELEASE" ]]; then
  echo "::error::Kernel release does not match the stock SM-X710 release"
  exit 1
fi

echo "==> Build kernel with $JOBS jobs ($LTO LTO)"
make -j"$JOBS" O=out "${MAKE_ARGS[@]}"

IMAGE="$OUT_DIR/arch/arm64/boot/Image"
COMPILE_H="$OUT_DIR/include/generated/compile.h"
test -s "$IMAGE"
test -f "$COMPILE_H"

# Re-check after the full build using the same kernelrelease target, rather
# than depending on the location/timing of an intermediate generated file.
ACTUAL_RELEASE="$(make -s O=out "${MAKE_ARGS[@]}" kernelrelease | tail -n 1)"
if [[ "$ACTUAL_RELEASE" != "$EXPECTED_RELEASE" ]]; then
  echo "::error::Final kernel release mismatch: $ACTUAL_RELEASE"
  exit 1
fi

ACTUAL_UTS_VERSION="$(sed -n 's/^#define UTS_VERSION "\(.*\)"$/\1/p' "$COMPILE_H")"
echo "==> Expected UTS_VERSION: $EXPECTED_UTS_VERSION"
echo "==> Actual   UTS_VERSION: $ACTUAL_UTS_VERSION"
if [[ "$ACTUAL_UTS_VERSION" != "$EXPECTED_UTS_VERSION" ]]; then
  echo "::error::Kernel build version/time does not match the stock SM-X710 kernel"
  exit 1
fi

cat > "$OUT_DIR/build_identity.txt" <<EOF
Device: Samsung Galaxy Tab S9 Wi-Fi (SM-X710)
Firmware: $BUILD_NUMBER
kernel.release: $ACTUAL_RELEASE
UTS_VERSION: $ACTUAL_UTS_VERSION
Expected kernel.release: $EXPECTED_RELEASE
Expected UTS_VERSION: $EXPECTED_UTS_VERSION
GOOGLE_BRANCH: $GOOGLE_BRANCH
KMI_GENERATION: $KMI_GENERATION
CONFIG_LOCALVERSION: $STOCK_LOCALVERSION
LTO: $LTO
EOF

cd "$OUT_DIR"
if [[ ! -d AnyKernel3 ]]; then
  git clone --depth=1 https://github.com/wickedid/AnyKernel3.git -b kalama AnyKernel3
fi

cp arch/arm64/boot/Image AnyKernel3/zImage
ZIP_NAME="SM-X710_${BUILD_NUMBER}_${ACTUAL_RELEASE}_$(date -u '+%Y_%m_%d').zip"
cd AnyKernel3
rm -f ./*.zip
zip -r "$ZIP_NAME" . -x '*.git*' '*.zip'

echo "==> AnyKernel3 package: $(realpath "$ZIP_NAME")"
echo "==> Stock kernel identity verified successfully"

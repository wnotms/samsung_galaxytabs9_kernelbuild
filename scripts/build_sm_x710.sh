#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"
KERNEL_DIR="$ROOT_DIR/common"
TOOLCHAIN_DIR="$ROOT_DIR/prebuilts/clang/host/linux-x86/clang-r450784e/bin"
KERNEL_TOOLS_DIR="$ROOT_DIR/prebuilts/kernel-build-tools/linux-x86/bin"
TARGET_DEFCONFIG="${TARGET_DEFCONFIG:-kalama_gki_defconfig}"
JOBS="${JOBS:-2}"
LTO="${LTO:-thin}"
BUILD_NUMBER="${BUILD_NUMBER:-X710ZCU5CYH4}"

export PATH="$TOOLCHAIN_DIR:$KERNEL_TOOLS_DIR:$PATH"
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export KBUILD_BUILD_USER="wnotms"
export KBUILD_BUILD_HOST="github-actions"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-2025-08-20 08:06:12 UTC}"
export BUILD_NUMBER

LOCALVERSION="-android13-8-2370170"
if [[ "$LTO" == "thin" ]]; then
  LOCALVERSION+="-thin"
elif [[ "$LTO" == "full" ]]; then
  LOCALVERSION+="-full"
else
  echo "Unsupported LTO mode: $LTO"
  exit 1
fi

cd "$KERNEL_DIR"
rm -rf out

MAKE_ARGS=(
  "CC=clang"
  "ARCH=arm64"
  "LLVM=1"
  "LLVM_IAS=1"
  "LOCALVERSION=$LOCALVERSION"
)

echo "==> Generate config: $TARGET_DEFCONFIG"
make -j"$JOBS" O=out "${MAKE_ARGS[@]}" "$TARGET_DEFCONFIG"

# Samsung hardening/options that are commonly disabled in custom kernel builds.
./scripts/config --file out/.config \
  -d UH \
  -d RKP \
  -d KDP \
  -d SECURITY_DEFEX \
  -d INTEGRITY \
  -d FIVE \
  -d TRIM_UNUSED_KSYMS

# Droidspaces/container support. Most of these are already present in the
# repository defconfig, but forcing them here makes the Actions build explicit
# and self-checking.
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

# This tree already carries the SYSVIPC task_struct compatibility patch as a
# source file. Apply it only if the current tree still has SYSVIPC fields in
# their old position and the patch is applicable.
PATCH_FILE="$KERNEL_DIR/0001-ANDROID-sched-Move-SYSVIPC-fields-to-the-end-of-task.patch"
if [[ -f "$PATCH_FILE" ]]; then
  if patch --dry-run -p1 < "$PATCH_FILE" >/dev/null 2>&1; then
    echo "==> Applying SYSVIPC task_struct compatibility patch"
    patch -p1 < "$PATCH_FILE"
  elif patch --dry-run -R -p1 < "$PATCH_FILE" >/dev/null 2>&1; then
    echo "==> SYSVIPC compatibility patch already applied"
  else
    echo "==> SYSVIPC patch does not cleanly apply; continuing with current source layout"
  fi
fi

echo "==> Build kernel with $JOBS jobs"
make -j"$JOBS" O=out "${MAKE_ARGS[@]}"

IMAGE="$KERNEL_DIR/out/arch/arm64/boot/Image"
test -s "$IMAGE"

cd "$KERNEL_DIR/out"
if [[ ! -d AnyKernel3 ]]; then
  git clone --depth=1 https://github.com/wickedid/AnyKernel3.git -b kalama AnyKernel3
fi

cp arch/arm64/boot/Image AnyKernel3/zImage
KERNEL_RELEASE="$(cat include/config/kernel.release)"
ZIP_NAME="SM-X710_${BUILD_NUMBER}_${KERNEL_RELEASE}_$(date -u '+%Y_%m_%d').zip"
cd AnyKernel3
rm -f ./*.zip
zip -r "$ZIP_NAME" . -x '*.git*' '*.zip'

echo "==> AnyKernel3 package: $(realpath "$ZIP_NAME")"

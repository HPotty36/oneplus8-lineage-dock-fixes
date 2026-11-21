#!/bin/bash
# Build a dock-fix boot image for one LineageOS instantnoodle build.
#
# Inputs (environment):
#   DATE            Lineage build date, YYYYMMDD
#   BOOT_IMG        path to that build's stock boot.img (already sha256-checked)
#   MANIFEST        path to that build's build-manifest.xml
#   WORKDIR         scratch directory (default: ./work)
#   OUTDIR          output directory (default: ./out)
# Needs: clang/lld/llvm 18, bc bison flex libssl-dev libelf-dev lz4 cpio python3 git
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORKDIR=${WORKDIR:-$PWD/work}
OUTDIR=${OUTDIR:-$PWD/out}
PATCH_VERSION=$(cat "$REPO_DIR/patches/VERSION")
PATCH="$REPO_DIR/patches/op8-dock-fixes-$PATCH_VERSION.patch"
EXTRA_CMDLINE="usbcore.autosuspend=-1 policy_engine.host_hs_only=1"
KERNEL_REPO=https://github.com/LineageOS/android_kernel_oneplus_sm8250
MKBOOTIMG_REPO=https://github.com/LineageOS/android_system_tools_mkbootimg

: "${DATE:?}" "${BOOT_IMG:?}" "${MANIFEST:?}"
mkdir -p "$WORKDIR" "$OUTDIR"
BOOT_IMG=$(realpath "$BOOT_IMG"); MANIFEST=$(realpath "$MANIFEST")

# 1. kernel revision used by this build
KREV=$(grep -o 'name="LineageOS/android_kernel_oneplus_sm8250"[^>]*revision="[0-9a-f]\{40\}"' "$MANIFEST" \
       | grep -o 'revision="[0-9a-f]*"' | cut -d'"' -f2)
[ -n "$KREV" ] || { echo "kernel revision not found in manifest" >&2; exit 1; }
echo "kernel revision: $KREV"

# 2. mkbootimg tools
[ -d "$WORKDIR/mkbootimg" ] || git clone --depth 1 "$MKBOOTIMG_REPO" "$WORKDIR/mkbootimg"

# 3. stock boot.img -> kernel config
rm -rf "$WORKDIR/stock" && mkdir "$WORKDIR/stock"
python3 "$WORKDIR/mkbootimg/unpack_bootimg.py" --boot_img "$BOOT_IMG" --out "$WORKDIR/stock" >/dev/null

# 4. kernel source at that revision
KSRC="$WORKDIR/kernel"
if [ ! -d "$KSRC/.git" ]; then
  git init -q "$KSRC"
  git -C "$KSRC" remote add origin "$KERNEL_REPO"
fi
git -C "$KSRC" fetch -q --depth 1 origin "$KREV"
git -C "$KSRC" checkout -q -f FETCH_HEAD
git -C "$KSRC" clean -qfdx
"$KSRC/scripts/extract-ikconfig" "$WORKDIR/stock/kernel" > "$WORKDIR/stock.config"

# 5. apply the dock fixes
if ! git -C "$KSRC" apply "$PATCH"; then
  echo "git apply failed, trying patch with fuzz" >&2
  patch -d "$KSRC" -p1 -F3 --no-backup-if-mismatch < "$PATCH"
  if find "$KSRC" -name '*.rej' | grep -q .; then
    echo "patch does not apply to $KREV" >&2; exit 1
  fi
fi
echo "-dockfix" > "$KSRC/localversion-dockfix"
[ "${STOP_AFTER:-}" = apply ] && { echo "stopping after apply"; exit 0; }

# 6. build
KOUT="$WORKDIR/kout"
rm -rf "$KOUT" && mkdir -p "$KOUT"
cp "$WORKDIR/stock.config" "$KOUT/.config"
MAKE=(make -C "$KSRC" O="$KOUT" ARCH=arm64 LLVM=1 LLVM_IAS=1
      CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi-)
"${MAKE[@]}" olddefconfig
"${MAKE[@]}" -j"$(nproc)" Image
IMAGE="$KOUT/arch/arm64/boot/Image"

# sanity: the fixes are really in there
for s in "skip chargerid switch" "host_hs_only" "enumeration interrupted, re-checking port"; do
  strings "$IMAGE" | grep -q "$s" || { echo "missing marker: $s" >&2; exit 1; }
done

# 7. repack
NAME="boot-dockfix-$DATE-$PATCH_VERSION.img"
MKBOOTIMG_DIR="$WORKDIR/mkbootimg" EXTRA_CMDLINE="$EXTRA_CMDLINE" \
  bash "$REPO_DIR/scripts/repack-boot.sh" "$BOOT_IMG" "$IMAGE" "$OUTDIR/$NAME"

IMG_SHA=$(sha256sum "$OUTDIR/$NAME" | cut -d' ' -f1)
echo "$IMG_SHA  $NAME" > "$OUTDIR/$NAME.sha256"
cp "$KOUT/.config" "$OUTDIR/kernel-$DATE-$PATCH_VERSION.config"
KVER=$(cat "$KOUT/include/config/kernel.release")
STOCK_SHA=$(sha256sum "$BOOT_IMG" | cut -d' ' -f1)
cat > "$OUTDIR/build-info.json" <<JSON
{
  "lineage_date": "$DATE",
  "stock_boot_sha256": "$STOCK_SHA",
  "kernel_revision": "$KREV",
  "kernel_release": "$KVER",
  "patch_version": "$PATCH_VERSION",
  "extra_cmdline": "$EXTRA_CMDLINE",
  "image": "$NAME",
  "image_sha256": "$IMG_SHA",
  "image_size": $(stat -c %s "$OUTDIR/$NAME")
}
JSON
cat "$OUTDIR/build-info.json"

#!/bin/sh
# Repack a header-v2 boot image with a new kernel and the extra cmdline options.
# Usage: repack-boot.sh <stock-boot.img> <Image> <out.img>
# Needs AOSP mkbootimg tools: set MKBOOTIMG_DIR to a checkout of
# https://android.googlesource.com/platform/system/tools/mkbootimg
set -e
STOCK=$1; IMAGE=$2; OUT=$3
TOOLS=${MKBOOTIMG_DIR:-./mkbootimg}
EXTRA="usbcore.autosuspend=-1 policy_engine.host_hs_only=1"
WORK=$(mktemp -d)

python3 "$TOOLS/unpack_bootimg.py" --boot_img "$STOCK" --out "$WORK" --format=mkbootimg > "$WORK/args"
# swap the kernel and append the extra options to the cmdline
ARGS=$(sed -e "s#--kernel $WORK/kernel#--kernel $IMAGE#" \
           -e "s#--cmdline '\([^']*\)'#--cmdline '\1 $EXTRA'#" "$WORK/args")
eval python3 "$TOOLS/mkbootimg.py" $ARGS --output "$OUT"

python3 "$TOOLS/unpack_bootimg.py" --boot_img "$OUT" --out "$WORK/check" | grep "command line"
cmp "$WORK/check/kernel" "$IMAGE" && echo "kernel OK"
rm -rf "$WORK"

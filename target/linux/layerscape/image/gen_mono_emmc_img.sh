#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Mono Gateway eMMC image. Layout (see mono_gpt.py for the GPT rationale):
#   0-4 KiB   complete GPT (8-entry array), clear of the firmware region
#   4 KiB-32 MiB  boot firmware, owned by a separate update tool - untouched
#   32 MiB    p1 bootA (ext4: /boot/extlinux + Image.gz + dtb)
#   +bootfs   p2 rootA: slot-A rootfs (read-only squashfs). p3 bootB / p4 rootB /
#             p5 data follow in the GPT but are created on the device - this image
#             only seeds bootA + rootA. The writable overlay is on p5 (extroot).
#
set -ex
[ $# -eq 6 ] || {
    echo "SYNTAX: $0 <file> <bootfs> <rootfs> <bootfs MB> <rootfs part MB> <disk sectors>"
    exit 1
}
OUTPUT="$1"; BOOTFS="$2"; ROOTFS="$3"
BOOTFSSIZE="$4"; ROOTFSPARTSIZE="$5"; DISKSECTORS="$6"
HERE="$(dirname "$0")"

# squashfs rootfs: read-only and fixed-size, so it is written to the slot as-is -
# no ext4 resize-metadata prep, no grow-on-first-boot. It compresses to well under
# the 1 GiB slot; the free tail of the slot is simply unused (the writable overlay
# lives on p5, not in the rootfs slot).

rm -f "$OUTPUT"
python3 "$HERE/mono_gpt.py" primary "$OUTPUT" "$DISKSECTORS" "$BOOTFSSIZE" "$ROOTFSPARTSIZE"
truncate -s $(( (32 + BOOTFSSIZE) * 2048 * 512 )) "$OUTPUT"   # zero-fill to rootfs start

BOOTOFFSET=$(( 32 * 2048 ))
ROOTFSOFFSET=$(( (32 + BOOTFSSIZE) * 2048 ))
dd bs=512 if="$BOOTFS" of="$OUTPUT" seek=${BOOTOFFSET} conv=notrunc
dd bs=512 if="$ROOTFS" of="$OUTPUT" seek=${ROOTFSOFFSET} conv=notrunc

# Trim after the rootA payload: this image carries only bootA + rootA. p3-p5
# (bootB/rootB/data) live in the GPT but are created on the device at first
# boot, and the flashing procedure never writes past rootA. The backup GPT is
# placed by first-boot, not the image.
ROOTFSBYTES=$(stat -c%s "$ROOTFS")
truncate -s $(( ROOTFSOFFSET * 512 + ROOTFSBYTES )) "$OUTPUT"

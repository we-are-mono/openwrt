#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Mono Gateway eMMC image. Layout (see mono_gpt.py for the GPT rationale):
#   0-4 KiB   complete GPT (8-entry array), clear of the firmware region
#   4 KiB-32 MiB  boot firmware, owned by a separate update tool - untouched
#   32 MiB    partition 1: boot (ext4: /boot/extlinux + Image.gz + dtb)
#   +bootfs   partition 2: rootfs, partition sized to the eMMC; the ext4
#             inside is smaller and grows on first boot
#
set -ex
[ $# -eq 6 ] || {
    echo "SYNTAX: $0 <file> <bootfs> <rootfs> <bootfs MB> <rootfs part MB> <disk sectors>"
    exit 1
}
OUTPUT="$1"; BOOTFS="$2"; ROOTFS="$3"
BOOTFSSIZE="$4"; ROOTFSPARTSIZE="$5"; DISKSECTORS="$6"
HERE="$(dirname "$0")"

# make_ext4fs output cannot be grown online (the kernel resizer rejects its
# reserved-GDT layout: "reserved block not at offset"). e2fsck plus ONE
# offline grow on the host rebuilds the resize metadata; first-boot online
# resize then works. Verified via loop mount.
cp "$ROOTFS" "$OUTPUT.rootfs"
e2fsck -fy "$OUTPUT.rootfs" || [ $? -le 2 ]
truncate -s 384M "$OUTPUT.rootfs"
resize2fs "$OUTPUT.rootfs"
ROOTFS="$OUTPUT.rootfs"

rm -f "$OUTPUT"
python3 "$HERE/mono_gpt.py" primary "$OUTPUT" "$DISKSECTORS" "$BOOTFSSIZE" "$ROOTFSPARTSIZE"
truncate -s $(( (32 + BOOTFSSIZE) * 2048 * 512 )) "$OUTPUT"   # zero-fill to rootfs start

BOOTOFFSET=$(( 32 * 2048 ))
ROOTFSOFFSET=$(( (32 + BOOTFSSIZE) * 2048 ))
dd bs=512 if="$BOOTFS" of="$OUTPUT" seek=${BOOTOFFSET} conv=notrunc
dd bs=512 if="$ROOTFS" of="$OUTPUT" seek=${ROOTFSOFFSET} conv=notrunc

# Trim after the rootfs payload; the partition extends to end-of-device but
# the flashing procedure never writes that far (and the backup GPT is placed
# by first-boot, not the image).
ROOTFSBYTES=$(stat -c%s "$ROOTFS")
truncate -s $(( ROOTFSOFFSET * 512 + ROOTFSBYTES )) "$OUTPUT"
rm -f "$OUTPUT.rootfs"

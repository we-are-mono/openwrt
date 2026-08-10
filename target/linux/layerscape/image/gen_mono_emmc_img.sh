#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Mono Gateway eMMC image:
#   - 8-entry-equivalent GPT: header at LBA0/1, entry array relocated to
#     5 MiB (-e 5120) so the LS1046A boot firmware region stays clear:
#     PBL@4K, FIP@1M, U-Boot env@3M, FMan ucode@4M (raw, dd'd by the
#     factory flow / write_uboot_platform - NOT part of this image)
#   - partition 1 (boot, ext4: /boot/extlinux + Image.gz + dtb) at 32 MiB
#   - partition 2 (rootfs) right after
#
set -ex
[ $# -eq 5 ] || {
    echo "SYNTAX: $0 <file> <bootfs image> <rootfs image> <bootfs size MB> <rootfs part MB>"
    exit 1
}

OUTPUT="$1"
BOOTFS="$2"
ROOTFS="$3"
BOOTFSSIZE="$4"
ROOTFSPARTSIZE="$5"

# The rootfs PARTITION is created at its final (full-eMMC) size; the
# filesystem image inside is smaller and resize2fs grows it on first
# boot. This avoids any on-device GPT rewrite, which standard tools
# would relocate over the raw boot-firmware region.
#
# make_ext4fs output cannot be grown online (its reserved-GDT layout is
# rejected by the kernel resizer: "reserved block not at offset").
# e2fsck plus ONE offline grow on the host rebuilds the resize metadata;
# after that the first-boot online resize works. Verified via loop mount.
cp "$ROOTFS" "$OUTPUT.rootfs"
e2fsck -fy "$OUTPUT.rootfs" || [ $? -le 2 ]
truncate -s 384M "$OUTPUT.rootfs"
resize2fs "$OUTPUT.rootfs"
ROOTFS="$OUTPUT.rootfs"

set $(ptgen -o $OUTPUT -v -g -e 5120 \
    -N boot -p ${BOOTFSSIZE}M@32M \
    -N rootfs -p ${ROOTFSPARTSIZE}M)

BOOTOFFSET=$(($1 / 512))
ROOTFSOFFSET=$(($3 / 512))

dd bs=512 if="$BOOTFS" of="$OUTPUT" seek=${BOOTOFFSET} conv=notrunc
dd bs=512 if="$ROOTFS" of="$OUTPUT" seek=${ROOTFSOFFSET} conv=notrunc

# Trim the image after the rootfs payload: the partition extends far
# beyond it, and the alternate GPT ptgen placed at partition end would
# otherwise make the image eMMC-sized. The kernel accepts the primary
# GPT alone.
ROOTFSBYTES=$(stat -c%s "$ROOTFS")
truncate -s $(($3 + ROOTFSBYTES)) "$OUTPUT"

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
    echo "SYNTAX: $0 <file> <bootfs image> <rootfs image> <bootfs size MB> <rootfs size MB>"
    exit 1
}

OUTPUT="$1"
BOOTFS="$2"
ROOTFS="$3"
BOOTFSSIZE="$4"
ROOTFSSIZE="$5"

set $(ptgen -o $OUTPUT -v -g -e 5120 \
    -N boot -p ${BOOTFSSIZE}M@32M \
    -N rootfs -p ${ROOTFSSIZE}M)

BOOTOFFSET=$(($1 / 512))
ROOTFSOFFSET=$(($3 / 512))

dd bs=512 if="$BOOTFS" of="$OUTPUT" seek=${BOOTOFFSET} conv=notrunc
dd bs=512 if="$ROOTFS" of="$OUTPUT" seek=${ROOTFSOFFSET} conv=notrunc

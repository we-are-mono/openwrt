#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Mono Gateway eMMC image:
#   - complete GPT within the first 4 KiB: protective MBR (LBA0),
#     header (LBA1), 8-entry partition array (LBA2-3). The firmware
#     update tool owns EVERYTHING from 4 KiB to 32 MiB and rewrites it
#     wholesale, so no GPT structure may live there. 8 entries instead
#     of the customary 128 is a header-declared value the kernel and
#     U-Boot honor (ptgen cannot emit small arrays, hence the inline
#     writer below).
#   - partition 1 (boot, ext4: /boot/extlinux + Image.gz + dtb) at 32 MiB
#   - partition 2 (rootfs) right after, partition sized to the full
#     eMMC; the filesystem inside is smaller and grows on first boot
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

# make_ext4fs output cannot be grown online (its reserved-GDT layout is
# rejected by the kernel resizer: "reserved block not at offset").
# e2fsck plus ONE offline grow on the host rebuilds the resize metadata;
# after that the first-boot online resize works. Verified via loop mount.
cp "$ROOTFS" "$OUTPUT.rootfs"
e2fsck -fy "$OUTPUT.rootfs" || [ $? -le 2 ]
truncate -s 384M "$OUTPUT.rootfs"
resize2fs "$OUTPUT.rootfs"
ROOTFS="$OUTPUT.rootfs"

rm -f "$OUTPUT"
python3 - "$OUTPUT" "$BOOTFSSIZE" "$ROOTFSPARTSIZE" <<'PYEOF'
import struct, sys, uuid, zlib

out, bootmb, rootmb = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
SEC = 512
ENTRIES = 8
ENTRY_SZ = 128
# DK eMMC: 31080448 KiB. Only informational fields derive from this;
# partitions themselves fit any device at least this large.
DISK_LAST = 31080448 * 2 - 1

def guid(s):
    return uuid.UUID(s).bytes_le

LINUX_FS = guid("0FC63DAF-8483-4772-8E79-3D69D8477DE4")
# Fixed GUIDs for reproducible images
DISK_GUID = guid("6D6F6E6F-1046-4000-8000-4D6F6E6F0000")
PART_GUIDS = [guid("6D6F6E6F-1046-4000-8000-4D6F6E6F0001"),
              guid("6D6F6E6F-1046-4000-8000-4D6F6E6F0002")]

boot_first = 32 * 2048            # 32 MiB, in sectors
boot_last = boot_first + bootmb * 2048 - 1
root_first = boot_last + 1
root_last = root_first + rootmb * 2048 - 1

def entry(type_guid, part_guid, first, last, name):
    e = type_guid + part_guid + struct.pack("<QQQ", first, last, 0)
    e += name.encode("utf-16-le").ljust(72, b"\0")
    return e

array = entry(LINUX_FS, PART_GUIDS[0], boot_first, boot_last, "boot")
array += entry(LINUX_FS, PART_GUIDS[1], root_first, root_last, "rootfs")
array = array.ljust(ENTRIES * ENTRY_SZ, b"\0")

def header(entries_crc):
    h = struct.pack("<8s4sII4xQQQQ16sQIII",
        b"EFI PART", bytes([0, 0, 1, 0]), 92, 0,
        1, DISK_LAST,                 # this header, alternate location
        4 * 2048 // 1,                # first usable: 4 MiB... see below
        DISK_LAST - 34,               # last usable
        DISK_GUID,
        2,                            # entry array LBA
        ENTRIES, ENTRY_SZ, entries_crc)
    return h

# first usable must be >= end of the entry array (LBA 4). Use the 32 MiB
# boundary so the table itself documents the firmware reserve.
def header2(entries_crc):
    h = bytearray(header(entries_crc))
    struct.pack_into("<Q", h, 40, boot_first)
    return bytes(h)

ecrc = zlib.crc32(array) & 0xFFFFFFFF
h = bytearray(header2(ecrc))
hcrc = zlib.crc32(bytes(h)) & 0xFFFFFFFF
struct.pack_into("<I", h, 16, hcrc)

# Protective MBR: one 0xEE partition from LBA1 to end-of-disk (capped)
pmbr = bytearray(SEC)
psize = min(DISK_LAST, 0xFFFFFFFF)
pmbr[446:462] = bytes([0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF]) + \
    struct.pack("<II", 1, psize)
pmbr[510:512] = b"\x55\xAA"

with open(out, "wb") as f:
    f.write(bytes(pmbr))
    f.write(bytes(h).ljust(SEC, b"\0"))
    f.write(array)                    # LBA2-3
    f.truncate(root_first * SEC)      # zeros to rootfs start
print("gpt: boot %d-%d rootfs %d-%d" % (boot_first, boot_last, root_first, root_last))
PYEOF

BOOTOFFSET=$((32 * 2048))
ROOTFSOFFSET=$(( (32 + BOOTFSSIZE) * 2048 ))

dd bs=512 if="$BOOTFS" of="$OUTPUT" seek=${BOOTOFFSET} conv=notrunc
dd bs=512 if="$ROOTFS" of="$OUTPUT" seek=${ROOTFSOFFSET} conv=notrunc

# Trim after the rootfs payload: the partition extends far beyond it.
ROOTFSBYTES=$(stat -c%s "$ROOTFS")
truncate -s $(( ROOTFSOFFSET * 512 + ROOTFSBYTES )) "$OUTPUT"

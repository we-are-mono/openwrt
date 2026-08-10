#!/usr/bin/env python3
# Mono Gateway GPT writer. The whole GPT lives in the first 4 KiB (8-entry
# array) so the boot-firmware region (4 KiB-32 MiB, owned by a separate
# update tool) stays clear; ptgen cannot emit a small array, hence this.
#
# Two modes:
#   primary  -> protective MBR + header (LBA1) + array (LBA2-3), for the
#               head of the flashable image.
#   backup   -> array + header tail (33 sectors) written at LBA N-33 of the
#               real device on first boot; makes the on-disk table complete
#               so partition tools do not see a half-corrupt GPT and try to
#               "repair" it back to a 128-entry table across the 4 KiB line.
import struct, sys, uuid, zlib

def guid(s): return uuid.UUID(s).bytes_le

LINUX_FS  = guid("0FC63DAF-8483-4772-8E79-3D69D8477DE4")
DISK_GUID = guid("6D6F6E6F-1046-4000-8000-4D6F6E6F0000")
PART_GUID = [guid("6D6F6E6F-1046-4000-8000-4D6F6E6F0001"),
             guid("6D6F6E6F-1046-4000-8000-4D6F6E6F0002")]
SEC, ENTRIES, ENTRY_SZ = 512, 8, 128

def build(disk_sectors, boot_mb, root_part_mb):
    boot_first = 32 * 2048
    boot_last  = boot_first + boot_mb * 2048 - 1
    root_first = boot_last + 1
    root_last  = root_first + root_part_mb * 2048 - 1
    if root_last > disk_sectors - 34:
        sys.exit("mono_gpt: rootfs partition (%d MiB) exceeds device (%d sectors)"
                 % (root_part_mb, disk_sectors))

    def entry(pg, first, last, name):
        return (LINUX_FS + pg + struct.pack("<QQQ", first, last, 0)
                + name.encode("utf-16-le").ljust(72, b"\0"))
    array = (entry(PART_GUID[0], boot_first, boot_last, "boot")
             + entry(PART_GUID[1], root_first, root_last, "rootfs"))
    array = array.ljust(ENTRIES * ENTRY_SZ, b"\0")
    arr_crc = zlib.crc32(array) & 0xFFFFFFFF

    first_usable = boot_first
    last_usable  = disk_sectors - 34
    backup_arr_lba = disk_sectors - 33

    def header(my_lba, alt_lba, entry_lba):
        h = struct.pack("<8s4sII4xQQQQ16sQIII",
                        b"EFI PART", bytes([0, 0, 1, 0]), 92, 0,
                        my_lba, alt_lba, first_usable, last_usable,
                        DISK_GUID, entry_lba, ENTRIES, ENTRY_SZ, arr_crc)
        h = bytearray(h)
        struct.pack_into("<I", h, 16, zlib.crc32(h) & 0xFFFFFFFF)
        return bytes(h)

    return array, arr_crc, first_usable, last_usable, backup_arr_lba, \
           header(1, disk_sectors - 1, 2), \
           header(disk_sectors - 1, 1, backup_arr_lba)

def main():
    mode, out, disk, boot_mb, root_mb = sys.argv[1], sys.argv[2], \
        int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
    array, _, _, _, _, primary_hdr, backup_hdr = build(disk, boot_mb, root_mb)

    if mode == "primary":
        pmbr = bytearray(SEC)
        pmbr[446:462] = (bytes([0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF])
                         + struct.pack("<II", 1, min(disk - 1, 0xFFFFFFFF)))
        pmbr[510:512] = b"\x55\xAA"
        with open(out, "wb") as f:
            f.write(bytes(pmbr))
            f.write(primary_hdr.ljust(SEC, b"\0"))
            f.write(array)
    elif mode == "backup":
        # 33 sectors: 32-sector array region then the backup header, dd'd
        # to LBA (N-33) on the device.
        with open(out, "wb") as f:
            f.write(array.ljust(32 * SEC, b"\0"))
            f.write(backup_hdr.ljust(SEC, b"\0"))
    else:
        sys.exit("mono_gpt: mode must be primary|backup")

if __name__ == "__main__":
    main()

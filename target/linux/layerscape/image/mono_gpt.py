#!/usr/bin/env python3
# Mono Gateway GPT writer. The whole GPT lives in the first 4 KiB (8-entry
# array) so the boot-firmware region (4 KiB-32 MiB, owned by a separate
# update tool) stays clear; ptgen cannot emit a small array, hence this.
#
# A/B layout (5 partitions, all within the 8-entry array):
#   p1 bootA   @ 32 MiB            , boot_mb   ext4: /boot/extlinux + Image.gz + dtb
#   p2 rootA   @ 32+boot_mb MiB    , root_mb   slot-A rootfs (== the pre-A/B rootfs start)
#   p3 bootB   @ after rootA       , boot_mb   slot-B boot (empty until an A/B update)
#   p4 rootB   @ after bootB       , root_mb   slot-B rootfs (empty until an A/B update)
#   p5 data    @ after rootB       , fill      persistent /data; survives sysupgrade
# Slot A keeps the pre-A/B offsets so an existing unit's rootfs stays put and the
# migration only shrinks p2 and adds p3-p5. root_mb is now the PER-SLOT rootfs size.
#
# Two modes:
#   primary  -> protective MBR + header (LBA1) + array (LBA2-3), for the head
#               of the flashable image.
#   backup   -> array + header tail (33 sectors) written at LBA N-33 of the
#               real device on first boot; makes the on-disk table complete
#               so partition tools do not see a half-corrupt GPT and try to
#               "repair" it back to a 128-entry table across the 4 KiB line.
import struct, sys, uuid, zlib

def guid(s): return uuid.UUID(s).bytes_le

LINUX_FS  = guid("0FC63DAF-8483-4772-8E79-3D69D8477DE4")
DISK_GUID = guid("6D6F6E6F-1046-4000-8000-4D6F6E6F0000")
# One stable partition GUID per partition p1..p5 (…0001 … …0005).
PART_GUID = [guid("6D6F6E6F-1046-4000-8000-4D6F6E6F000%d" % n) for n in range(1, 6)]
SEC, ENTRIES, ENTRY_SZ = 512, 8, 128
MiB = 2048   # 512-byte sectors per MiB

def build(disk_sectors, boot_mb, root_mb):
    first_usable = 32 * MiB               # keep the 4 KiB-32 MiB firmware region out of range
    last_usable  = disk_sectors - 34      # 33-sector backup GPT tail lives above this

    # (label, size in MiB); size 0 means "fill to last_usable" (the data partition).
    specs = [("bootA", boot_mb), ("rootA", root_mb),
             ("bootB", boot_mb), ("rootB", root_mb), ("data", 0)]
    parts, cur = [], first_usable
    for name, mb in specs:
        first = cur
        last  = (first + mb * MiB - 1) if mb else last_usable
        if first > last or last > last_usable:
            sys.exit("mono_gpt: layout exceeds device (%d sectors): %s wants %d-%d, "
                     "last_usable %d" % (disk_sectors, name, first, last, last_usable))
        parts.append((name, first, last))
        cur = last + 1

    def entry(pg, first, last, name):
        return (LINUX_FS + pg + struct.pack("<QQQ", first, last, 0)
                + name.encode("utf-16-le").ljust(72, b"\0"))
    array = b"".join(entry(PART_GUID[i], f, l, n)
                     for i, (n, f, l) in enumerate(parts))
    array = array.ljust(ENTRIES * ENTRY_SZ, b"\0")
    arr_crc = zlib.crc32(array) & 0xFFFFFFFF

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

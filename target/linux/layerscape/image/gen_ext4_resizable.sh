#!/bin/bash
# Creates an ext4 image with resize_inode support and proper GDT reservation
# Usage: gen_ext4_resizable.sh <output> <size_bytes> <blocksize> <source_dir> [reserved_pct] [journal|nojournal] [setfiles]
# Note: Uses mkfs.ext4 -d (e2fsprogs 1.43+) - no root required

set -e

OUTPUT="$1"
SIZE="$2"
BLOCKSIZE="$3"
SOURCE_DIR="$4"
RESERVED_PCT="${5:-0}"
JOURNAL="${6:-nojournal}"
SETFILES="${7:-}"

TMPFILE="${OUTPUT}.tmp"
OWNER_CMDS="${OUTPUT}.owner.cmds"

# Calculate actual content size + 50% headroom for filesystem overhead
CONTENT_SIZE=$(du -sb "$SOURCE_DIR" | cut -f1)
INITIAL_SIZE=$(( CONTENT_SIZE * 150 / 100 ))

# Minimum 128MB to ensure proper metadata allocation
MIN_SIZE=$((128 * 1024 * 1024))
if [ "$INITIAL_SIZE" -lt "$MIN_SIZE" ]; then
    INITIAL_SIZE="$MIN_SIZE"
fi

# Round up to 4K boundary
INITIAL_SIZE=$(( (INITIAL_SIZE + 4095) / 4096 * 4096 ))

truncate -s "$INITIAL_SIZE" "$TMPFILE"

# Create ext4 filesystem with:
# - resize_inode: enables online resize
# - resize=32G: reserves GDT blocks for future expansion to 32GB
# - has_journal per CONFIG_TARGET_EXT4_JOURNAL (rootfs is a writable ext4 on
#   eMMC taking live UCI commits; without a journal an unclean power-off can
#   corrupt it)
#
# When SELinux labels are requested, setfiles and mkfs.ext4 must run in the
# same fakeroot session so mkfs.ext4 can see the fake security.selinux xattrs.
if [ "$JOURNAL" = "journal" ]; then
    FEATURES="resize_inode,has_journal"
else
    FEATURES="resize_inode,^has_journal"
fi

fakeroot -- sh -c '
set -e
source_dir="$1"
setfiles="$2"
tmpfile="$3"
blocksize="$4"
reserved_pct="$5"
features="$6"

if [ -n "$setfiles" ]; then
    if [ ! -f "$source_dir/etc/selinux/config" ]; then
        echo "SELinux labeling requested, but $source_dir/etc/selinux/config is missing" >&2
        exit 1
    fi

    . "$source_dir/etc/selinux/config"
    file_contexts="$source_dir/etc/selinux/${SELINUXTYPE}/contexts/files/file_contexts"
    if [ ! -f "$file_contexts" ]; then
        echo "SELinux labeling requested, but $file_contexts is missing" >&2
        exit 1
    fi

    "$setfiles" -r "$source_dir" "$file_contexts" "$source_dir"
fi

mkfs.ext4 -F -L rootfs -O "$features" \
    -E resize=34359738368 \
    -b "$blocksize" -m "$reserved_pct" \
    -d "$source_dir" \
    "$tmpfile"
' sh "$SOURCE_DIR" "$SETFILES" "$TMPFILE" "$BLOCKSIZE" "$RESERVED_PCT" "$FEATURES"

# setfiles must run in fakeroot for SELinux xattrs, but that makes mkfs.ext4
# record the build user's uid/gid. Normalize image ownership afterwards without
# changing the target rootfs tree on disk.
find "$SOURCE_DIR" -mindepth 1 -printf '%P\n' | while IFS= read -r path; do
    escaped="${path//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    printf 'set_inode_field "/%s" uid 0\n' "$escaped"
    printf 'set_inode_field "/%s" gid 0\n' "$escaped"
done > "$OWNER_CMDS"
debugfs -w -f "$OWNER_CMDS" "$TMPFILE" >/dev/null 2>&1
rm -f "$OWNER_CMDS"

# Shrink filesystem to minimum
e2fsck -fy "$TMPFILE" >/dev/null 2>&1 || true
resize2fs -M "$TMPFILE" >/dev/null 2>&1

# Get actual filesystem size and add padding for kernel.itb (added later by mono-add-kernel)
# Need at least 32MB extra for kernel + headroom
BLOCKS=$(dumpe2fs -h "$TMPFILE" 2>/dev/null | grep "Block count:" | awk '{print $3}')
BLOCK_SIZE_ACTUAL=$(dumpe2fs -h "$TMPFILE" 2>/dev/null | grep "Block size:" | awk '{print $3}')
FS_SIZE=$(( BLOCKS * BLOCK_SIZE_ACTUAL ))
PADDING=$(( FS_SIZE * 5 / 100 ))  # 5% padding
MIN_PADDING=$((32 * 1024 * 1024))  # minimum 32MB for kernel
if [ "$PADDING" -lt "$MIN_PADDING" ]; then
    PADDING="$MIN_PADDING"
fi
FINAL_SIZE=$(( FS_SIZE + PADDING ))

# Truncate file to final size
truncate -s "$FINAL_SIZE" "$TMPFILE"

# Resize filesystem to fill the truncated file
e2fsck -fy "$TMPFILE" >/dev/null 2>&1 || true
resize2fs "$TMPFILE" >/dev/null 2>&1

mv "$TMPFILE" "$OUTPUT"

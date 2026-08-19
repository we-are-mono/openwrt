#!/bin/sh
# Unit tests for the mono flash-target guards in the layerscape sysupgrade
# platform.sh: mono_gateway_root_part() (device validation) and mono_dd_member()
# (fail-if-either-tar-or-dd-fails streaming). Sandboxes the absolute paths the
# validator reads and relaxes the block-special check to plain existence (a unit
# test cannot mknod). Every DECISION is exercised, including the 196608-vs-65536
# boot-partition trap that makes this a real adaptation of cvandesande's guard.
#
# The DT compatible node is written as TEXT here (not the on-device
# NUL-separated form) so the result is independent of which grep the host
# provides; busybox grep matching the real NUL node is verified separately.
# Run from anywhere; skips if platform.sh is absent.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PLATFORM="$HERE/../base-files/lib/upgrade/platform.sh"
[ -f "$PLATFORM" ] || { echo "SKIP: platform.sh not found ($PLATFORM)"; exit 0; }
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
fails=0

sed -e "s#/proc/cmdline#$S/cmdline#g" \
    -e "s#/sys/firmware/devicetree/base/compatible#$S/compatible#g" \
    -e "s#/sys/block/#$S/sys/block/#g" \
    -e "s#/sys/class/block/#$S/sys/class/block/#g" \
    -e 's#-b "/dev/\$part"#-e "'"$S"'/dev/\$part"#g' \
    "$PLATFORM" > "$S/platform.sh"
. "$S/platform.sh"

grep -q "MONO_ROOT_START_SECTOR=196608" "$S/platform.sh" || { echo "FAIL: rootfs sector not 196608"; exit 1; }
grep -q "MONO_BOOT_START_SECTOR=65536"  "$S/platform.sh" || { echo "FAIL: boot sector not 65536"; exit 1; }
grep -q '\-b "/dev/' "$S/platform.sh" && { echo "FAIL: block check not relaxed by sed"; exit 1; }

valid() {  # $1 = disk name (default mmcblk0); running slot A (root=p2) by default
	local d=${1:-mmcblk0}
	rm -rf "$S/sys" "$S/dev"
	mkdir -p "$S/dev" "$S/sys/block/$d/device" \
	         "$S/sys/class/block/${d}p1" "$S/sys/class/block/${d}p2" \
	         "$S/sys/class/block/${d}p3" "$S/sys/class/block/${d}p4"
	printf 'root=/dev/%sp2 rootwait console=ttyS0,115200\n' "$d" > "$S/cmdline"
	printf 'mono,gateway-dk fsl,ls1046a\n' > "$S/compatible"
	: > "$S/dev/${d}p2"; : > "$S/dev/${d}p4"
	echo 1      > "$S/sys/class/block/${d}p1/partition"; echo 65536   > "$S/sys/class/block/${d}p1/start"
	echo 2      > "$S/sys/class/block/${d}p2/partition"; echo 196608  > "$S/sys/class/block/${d}p2/start"
	echo 3      > "$S/sys/class/block/${d}p3/partition"; echo 2293760 > "$S/sys/class/block/${d}p3/start"
	echo 4      > "$S/sys/class/block/${d}p4/partition"; echo 2424832 > "$S/sys/class/block/${d}p4/start"
	echo 0      > "$S/sys/block/$d/removable"
	echo MMC    > "$S/sys/block/$d/device/type"
}
# Switch the running slot to B (root=p4) after a valid() setup.
use_slot_b() { local d=${1:-mmcblk0}; printf 'root=/dev/%sp4 rootwait console=ttyS0,115200\n' "$d" > "$S/cmdline"; }
check() {  # $1: 0=accept 1=reject ; $2: desc ; $3: expected output (accept only)
	local want="${3:-/dev/mmcblk0p2}" out rc
	out=$(mono_gateway_root_part 2>/dev/null); rc=$?
	if [ "$1" = 0 ]; then
		if [ "$rc" = 0 ] && [ "$out" = "$want" ]; then echo "ok   accept: $2"
		else echo "FAIL accept: $2 (rc=$rc out='$out' want='$want')"; fails=$((fails+1)); fi
	else
		if [ "$rc" != 0 ]; then echo "ok   reject: $2"
		else echo "FAIL reject: $2 (wrongly accepted '$out')"; fails=$((fails+1)); fi
	fi
}

echo "== mono_gateway_root_part =="
valid;                                                          check 0 "valid p2 @196608 on non-removable eMMC"
valid mmcblk10;                                                 check 0 "high disk index mmcblk10" /dev/mmcblk10p2
valid; echo 65536 > "$S/sys/class/block/mmcblk0p2/start";       check 1 "rootfs start 65536 (boot-partition trap)"
valid; echo 1     > "$S/sys/class/block/mmcblk0p2/partition";   check 1 "partition index 1, not 2"
valid; echo 1     > "$S/sys/block/mmcblk0/removable";           check 1 "removable disk"
valid; echo SD    > "$S/sys/block/mmcblk0/device/type";         check 1 "non-MMC bus type"
valid; printf 'fsl,ls1046a\n' > "$S/compatible";               check 1 "not a Mono Gateway (DT compatible)"
valid; printf 'root=/dev/mmcblk0p1 rootwait\n' > "$S/cmdline"; check 1 "root= is p1 (wrong partition)"
valid; printf 'root=/dev/sda2 rootwait\n' > "$S/cmdline";      check 1 "root= is non-eMMC (sda2)"
valid; printf 'root=/dev/mmcblk0boot0p2 rootwait\n' > "$S/cmdline"; check 1 "eMMC hardware boot partition name"
valid; rm -f "$S/dev/mmcblk0p2";                               check 1 "rootfs device node missing"
valid; printf 'console=ttyS0 rootwait\n' > "$S/cmdline";       check 1 "no root= on cmdline"
# last root= wins (kernel semantics): an earlier p1 is overridden by a later p2
valid; printf 'root=/dev/mmcblk0p1 root=/dev/mmcblk0p2 rootwait\n' > "$S/cmdline"; check 0 "last root= wins (p1 then p2)"
# A/B: slot B rootfs (p4 @2424832) is a valid running root; boot parts (p1/p3) are not.
valid; use_slot_b;                                             check 0 "valid p4 @2424832 (slot B running)" /dev/mmcblk0p4
valid; printf 'root=/dev/mmcblk0p3 rootwait\n' > "$S/cmdline"; check 1 "root= is p3 (boot partition, not a slot)"
valid; use_slot_b; echo 65536 > "$S/sys/class/block/mmcblk0p4/start"; check 1 "slot B rootfs at wrong start sector"

echo "== A/B: sysupgrade writes the INACTIVE slot =="
# running slot A (root=p2) -> write slot B: bootB p3, rootB p4
valid
ab=$(mono_gateway_inactive_slot 2>/dev/null)
if [ "$ab" = "b /dev/mmcblk0p3 /dev/mmcblk0p4 3 2293760 4 2424832" ]; then echo "ok   A active -> write B"
else echo "FAIL inactive from A: '$ab'"; fails=$((fails+1)); fi
# running slot B (root=p4) -> write slot A: bootA p1, rootA p2
valid; use_slot_b
ab=$(mono_gateway_inactive_slot 2>/dev/null)
if [ "$ab" = "a /dev/mmcblk0p1 /dev/mmcblk0p2 1 65536 2 196608" ]; then echo "ok   B active -> write A"
else echo "FAIL inactive from B: '$ab'"; fails=$((fails+1)); fi

echo "== mono_dd_member: fails if EITHER tar or dd fails =="
# success: stubbed tar emits data, real dd writes it to a sandbox file
tar() { printf 'IMAGE-BYTES'; }
mono_dd_member x y root "$S/out"; rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$S/out")" = "IMAGE-BYTES" ]; then echo "ok   success: streams + rc 0"
else echo "FAIL success: rc=$rc out='$(cat "$S/out" 2>/dev/null)'"; fails=$((fails+1)); fi
# tar failure: stubbed tar emits a short stream then exits non-zero; dd reads it
# and exits 0 - the fix must still report failure (the whole point of finding #1).
tar() { printf 'SHORT'; return 2; }
mono_dd_member x y root "$S/out2"; rc=$?
if [ "$rc" != 0 ]; then echo "ok   tar-failure detected despite dd exit 0"
else echo "FAIL tar-failure masked (rc=$rc) - the bug is back"; fails=$((fails+1)); fi
unset -f tar

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi

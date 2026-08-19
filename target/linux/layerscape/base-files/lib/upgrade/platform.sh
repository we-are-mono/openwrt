#
# Copyright 2015-2019 Traverse Technologies
# Copyright 2020 NXP
#

# platform_do_upgrade_mono streams each tar member to its partition through a fifo
# (mono_dd_member) so tar's exit status is checked, not just dd's - busybox ash has
# no PIPESTATUS. Beyond stage2's base ramfs (busybox, fwtool, gzip, hexdump, tar,
# dd), the mono A/B flash needs: mkfifo (the fifo); fw_setenv + mono-fw-setenv to
# flip the boot slot after writing the INACTIVE slot; and the env configs as DATA
# so fw_setenv writes the same env U-Boot reads (mtd3 QSPI + eMMC copy). Left out,
# the flash silently fails at the boot write, or cannot switch slot, and reverts.
RAMFS_COPY_BIN="mkfifo fw_setenv fw_printenv mono-fw-setenv"
RAMFS_COPY_DATA="/etc/fw_env.config /etc/fw_env.d/emmc"

REQUIRE_IMAGE_METADATA=1

# --- Mono Gateway: validated flash target -----------------------------------
# Confirm the disk we are about to write really is THIS board's soldered eMMC
# and return its rootfs partition, so a wrong or absent device is refused
# instead of blindly dd'd. Inspired by Christopher van de Sande's
# device-validation guards (github.com/cvandesande). That fork's single-
# partition layout put the rootfs at sector 65536; our 2-partition GPT puts the
# BOOT partition there and the rootfs (p2) at 196608 = (32 + MONO_BOOTFS_SIZE[64])
# * 2048 - so copying that 65536 check verbatim would select our boot partition
# and overwrite it.
# This helper is the single source of truth; the first-boot expand uci-default
# sources this file to reuse it. Per-device: when non-DK Gateway boards are
# added, these sectors must track the mono_gpt.py layout.
# A/B slots (mono_gpt.py): slot A = bootA p1 / rootA p2; slot B = bootB p3 / rootB
# p4. Fixed GPT sectors: bootA@65536, rootA@196608, bootB@2293760, rootB@2424832
# (data p5 fills the rest and is never touched by sysupgrade). HW-confirmed on the
# DUT via /sys/class/block/mmcblk0pN/start.
MONO_ROOT_START_SECTOR=196608
MONO_BOOT_START_SECTOR=65536
MONO_ROOTB_START_SECTOR=2424832
MONO_BOOTB_START_SECTOR=2293760

mono_cmdline_root() {
	# Last root= wins, matching the kernel (a later root= overrides an earlier).
	local arg val=
	for arg in $(cat /proc/cmdline); do
		case "$arg" in root=*) val="${arg#root=}" ;; esac
	done
	[ -n "$val" ] && echo "$val"
}

# True (0) if partition $1 (e.g. mmcblk0p2) has index $2 and starts at sector $3.
mono_part_matches() {
	[ "$(cat "/sys/class/block/$1/partition" 2>/dev/null)" = "$2" ] &&
	[ "$(cat "/sys/class/block/$1/start" 2>/dev/null)" = "$3" ]
}

# Echo the validated rootfs partition (e.g. /dev/mmcblk0p2), or fail (return 1).
mono_gateway_root_part() {
	local root part disk idx sector removable type

	grep -q "mono,gateway-dk" /sys/firmware/devicetree/base/compatible 2>/dev/null || {
		echo "Not a Mono Gateway - refusing" >&2; return 1; }
	root="$(mono_cmdline_root)" || { echo "Cannot determine root= from /proc/cmdline" >&2; return 1; }
	# A/B: the running rootfs is slot A (p2 @196608) or slot B (p4 @2424832).
	# The boot partitions (p1/p3) and /data (p5) are never a valid root=.
	case "$root" in
	/dev/mmcblk*p2) part="${root##*/}"; idx=2; sector="$MONO_ROOT_START_SECTOR" ;;
	/dev/mmcblk*p4) part="${root##*/}"; idx=4; sector="$MONO_ROOTB_START_SECTOR" ;;
	*) echo "Refusing unsupported root device: $root" >&2; return 1 ;;
	esac
	disk="${part%p[0-9]}"
	case "$disk" in
	mmcblk | mmcblk*[!0-9]*) echo "Refusing malformed eMMC name: $disk" >&2; return 1 ;;
	esac
	[ -b "/dev/$part" ]       || { echo "$part is not a block device" >&2; return 1; }
	[ -d "/sys/block/$disk" ] || { echo "eMMC $disk not present in sysfs" >&2; return 1; }
	mono_part_matches "$part" "$idx" "$sector" || {
		echo "Refusing: $part is not an A/B rootfs slot (want index $idx at sector $sector)" >&2; return 1; }
	removable="$(cat "/sys/block/$disk/removable" 2>/dev/null)"
	[ "$removable" = "0" ] || { echo "Refusing removable disk $disk (not soldered eMMC)" >&2; return 1; }
	type="$(cat "/sys/block/$disk/device/type" 2>/dev/null)"
	[ "$type" = "MMC" ] || { echo "Refusing non-eMMC disk $disk (type '$type')" >&2; return 1; }

	echo "/dev/$part"
}

# A/B slot selection for sysupgrade: from the validated RUNNING rootfs, echo the
# INACTIVE slot we must write, as:
#   <new_slot> <bootpart> <rootpart> <boot_idx> <boot_sector> <root_idx> <root_sector>
# (running A -> write B: p3/p4; running B -> write A: p1/p2). Fails if the running
# slot cannot be validated.
mono_gateway_inactive_slot() {
	local run disk
	run="$(mono_gateway_root_part)" || return 1
	disk="${run%p[0-9]}"
	case "$run" in
	*p2) echo "b ${disk}p3 ${disk}p4 3 $MONO_BOOTB_START_SECTOR 4 $MONO_ROOTB_START_SECTOR" ;;
	*p4) echo "a ${disk}p1 ${disk}p2 1 $MONO_BOOT_START_SECTOR 2 $MONO_ROOT_START_SECTOR" ;;
	*) return 1 ;;
	esac
}

platform_do_upgrade_sdboot() {
	local diskdev partdev parttype=ext4
	local tar_file="$1"
	local board_dir=$(tar tf $tar_file | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	export_bootdevice && export_partdevice diskdev 0 || {
		echo "Unable to determine upgrade device"
		return 1
	}

	if export_partdevice partdev 1; then
		mount -t $parttype -o rw,noatime "/dev/$partdev" /mnt 2>&1
		echo "Writing kernel..."
		tar xf $tar_file ${board_dir}/kernel -O > /mnt/fitImage
		umount /mnt
	fi

	echo "Erasing rootfs..."
	dd if=/dev/zero of=/dev/mmcblk0p2 bs=1M > /dev/null 2>&1
	echo "Writing rootfs..."
	tar xf $tar_file ${board_dir}/root -O  | dd of=/dev/mmcblk0p2 bs=512k > /dev/null 2>&1

}

platform_do_upgrade_traverse_slotubi() {
	part="$(awk -F 'ubi.mtd=' '{printf $2}' /proc/cmdline | sed -e 's/ .*$//')"
	echo "Active boot slot: ${part}"
	new_active_sys="b"

	if [ ! -z "${part}" ]; then
		if [ "${part}" = "ubia" ]; then
			CI_UBIPART="ubib"
		else
			CI_UBIPART="ubia"
			new_active_sys="a"
		fi
	fi
	echo "Updating UBI part ${CI_UBIPART}"
	fw_setenv "openwrt_active_sys" "${new_active_sys}"
	nand_do_upgrade "$1"
	return $?
}

platform_copy_config_sdboot() {
	local diskdev partdev parttype=ext4

	export_bootdevice && export_partdevice diskdev 0 || {
		echo "Unable to determine upgrade device"
		return 1
	}

	if export_partdevice partdev 1; then
		mount -t $parttype -o rw,noatime "/dev/$partdev" /mnt 2>&1
		echo "Saving config backup..."
		cp -af "$UPGRADE_BACKUP" "/mnt/$BACKUP_FILE"
		umount /mnt
	fi
}
# Decompress a gzipped sysupgrade image ($1) to a plain tar ($2), verifying
# the whole gzip stream (CRC32) before returning success. The fwtool metadata
# trailer sits after the gzip stream, so strip it first with fwtool -T ($1 is
# left untouched) - fed the raw image, gzip's exit status would be ambiguous
# (trailing garbage vs corruption). A bad image fails here, before any dd.
mono_decompress_image() {	# image.bin out.tar
	local scratch="$2.gz"
	fwtool -q -T -i /dev/null "$1" > "$scratch" || {
		rm -f "$scratch"
		echo "Could not strip the metadata trailer from the image"
		return 1
	}
	gzip -dc "$scratch" > "$2" || {
		rm -f "$scratch" "$2"
		echo "Image failed the gzip integrity check"
		return 1
	}
	rm -f "$scratch"
}

# Stream a sysupgrade tar member to a block device, failing if EITHER tar or dd
# fails. A plain "tar | dd || ..." only observes dd's exit status, so a
# truncated/erroring tar with a dd that exits 0 would silently write a short
# image; the fifo + wait captures tar's exit too.
mono_dd_member() {  # tar_file board_dir member device
	local rc_t rc_d fifo=/tmp/mono-upgrade.fifo
	rm -f "$fifo"; mkfifo "$fifo" || return 1
	tar xf "$1" "$2/$3" -O > "$fifo" &
	local tp=$!
	dd of="$4" bs=1M conv=fsync < "$fifo"; rc_d=$?
	wait "$tp"; rc_t=$?
	rm -f "$fifo"
	[ "$rc_d" = 0 ] && [ "$rc_t" = 0 ]
}

platform_do_upgrade_mono() {
	local tar_file="$1"

	# sysupgrade.bin ships gzipped (~44 MB vs ~470 MB) to cut OTA downloads.
	# The shipped busybox tar has no compression autodetect, and streaming a
	# decompress into the tar calls below could abort mid-write on a corrupt
	# download - so verify and decompress the whole image to tmpfs first,
	# then flash unchanged. Non-gzip images keep taking the direct path.
	# PID-unique temp names so no operator-supplied image path in /tmp can
	# collide with (and be truncated by) our own redirects.
	if [ "$(dd if="$tar_file" bs=2 count=1 2>/dev/null | hexdump -v -n 2 -e '1/1 "%02x"')" = "1f8b" ]; then
		local gz_tar="/tmp/mono-upgrade.$$.tar"
		echo "Verifying and decompressing the sysupgrade image..."
		mono_decompress_image "$tar_file" "$gz_tar" || {
			echo "Refusing upgrade: image did not decompress cleanly - nothing was written"
			return 1
		}
		tar_file="$gz_tar"
	fi

	local board_dir=$(tar tf $tar_file | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	# A/B: write the INACTIVE slot, leaving the running slot intact as the rollback
	# target. mono_gateway_inactive_slot validates the running rootfs and returns
	# the slot we must write.
	local new_slot bootpart rootpart boot_idx boot_sector root_idx root_sector ab
	ab="$(mono_gateway_inactive_slot)" || {
		echo "Refusing upgrade: could not determine the inactive A/B slot (running rootfs did not validate)"; return 1; }
	set -- $ab
	new_slot="$1"; bootpart="$2"; rootpart="$3"
	boot_idx="$4"; boot_sector="$5"; root_idx="$6"; root_sector="$7"
	echo "A/B: writing INACTIVE slot ${new_slot} (boot ${bootpart}, root ${rootpart})"

	# Validate BOTH targets (index + fixed GPT sector) before any write, so a wrong
	# or blank GPT is refused rather than dd'd. Boot is written first and is the more
	# catastrophic target.
	[ -b "$bootpart" ] && mono_part_matches "${bootpart#/dev/}" "$boot_idx" "$boot_sector" || {
		echo "Inactive boot $bootpart failed validation (want index $boot_idx at sector $boot_sector)"; return 1; }
	[ -b "$rootpart" ] && mono_part_matches "${rootpart#/dev/}" "$root_idx" "$root_sector" || {
		echo "Inactive root $rootpart failed validation (want index $root_idx at sector $root_sector)"; return 1; }

	# The "kernel" member is the complete boot partition image (Image.gz + dtb +
	# extlinux.conf), so dtb + boot config always match the kernel. The GPT, the raw
	# boot firmware in the first 32 MiB, the ACTIVE slot, and /data (p5) are never
	# touched.
	echo "Writing boot partition to $bootpart..."
	mono_dd_member "$tar_file" "$board_dir" kernel "$bootpart" || {
		echo "Boot partition write to $bootpart failed"; return 1; }
	echo "Writing rootfs to $rootpart..."
	mono_dd_member "$tar_file" "$board_dir" root "$rootpart" || {
		echo "Rootfs write to $rootpart failed"; return 1; }

	# Both slots are on disk. Flip the boot pointer to the freshly written slot and
	# ARM the rollback trial: bootcount=0 (fresh budget) + upgrade_available=1 (the
	# CONFIG_BOOTCOUNT_ENV gate - U-Boot only counts/rolls-back while this is 1; the
	# new slot's mark-good clears it on a healthy boot). mono-fw-setenv writes BOTH
	# env media (QSPI mtd3 + eMMC) so it holds regardless of the firmware-boot DIP
	# switch. If the SLOT flip fails, abort WITHOUT switching so the unit still boots
	# the good (running) slot; if only arming fails, warn - the new slot still boots,
	# just without the auto-rollback safety net.
	echo "Activating slot ${new_slot} (both env media)..."
	mono-fw-setenv slot "$new_slot" || {
		echo "Refusing: could not set boot slot to ${new_slot}; keeping current slot"; return 1; }
	mono-fw-setenv bootcount 0        || echo "Warning: could not reset bootcount"
	mono-fw-setenv upgrade_available 1 || echo "Warning: could not arm rollback (upgrade_available); new slot boots without auto-rollback"
	# The new slot's first-boot uci-default re-expands the 384M rootfs to fill its
	# partition. sysupgrade now reboots into slot ${new_slot}; if it fails to boot
	# bootlimit times, U-Boot's altbootcmd flips back to the good slot. Migration of
	# an old 2-partition unit still happens on first boot (05-mono-gateway-migrate).
}

platform_copy_config_mono() {
	# The config backup must land on the slot we just wrote (the INACTIVE slot),
	# so the new slot restores it on first boot - NOT the running slot.
	local ab rootpart
	ab="$(mono_gateway_inactive_slot)" || {
		echo "Could not determine the inactive A/B slot for config backup"; return 1; }
	set -- $ab
	rootpart="$3"			# fields: <new_slot> <bootpart> <rootpart> ...
	mkdir -p /tmp/new_root
	if mount -t ext4 -o rw,noatime "$rootpart" /tmp/new_root; then
		echo "Saving config backup to the new slot rootfs ($rootpart)..."
		cp -af "$UPGRADE_BACKUP" /tmp/new_root/sysupgrade.tgz
		umount /tmp/new_root
	fi
}

platform_copy_config() {
	local board=$(board_name)

	case "$board" in
	mono,gateway-dk)
		platform_copy_config_mono
		return 0
		;;
	fsl,ls1012a-frwy-sdboot | \
	fsl,ls1021a-iot-sdboot | \
	fsl,ls1021a-twr-sdboot | \
	fsl,ls1028a-rdb-sdboot | \
	fsl,ls1043a-rdb-sdboot | \
	fsl,ls1046a-frwy-sdboot | \
	fsl,ls1046a-rdb-sdboot | \
	fsl,ls1088a-rdb-sdboot | \
	fsl,lx2160a-rdb-sdboot)
		platform_copy_config_sdboot
		;;
	esac
}
platform_check_image() {
	local board=$(board_name)

	case "$board" in
	traverse,ten64)
		nand_do_platform_check "ten64-mtd" $1
		return $?
		;;
	mono,gateway-dk)
		# Pre-flight: refuse before writing anything if the target eMMC
		# does not validate, rather than failing part-way through the flash.
		mono_gateway_root_part >/dev/null || return 1
		return 0
		;;
	fsl,ls1012a-frdm | \
	fsl,ls1012a-frwy-sdboot | \
	fsl,ls1012a-rdb | \
	fsl,ls1021a-iot-sdboot | \
	fsl,ls1021a-twr | \
	fsl,ls1021a-twr-sdboot | \
	fsl,ls1028a-rdb | \
	fsl,ls1028a-rdb-sdboot | \
	fsl,ls1043a-rdb | \
	fsl,ls1043a-rdb-sdboot | \
	fsl,ls1046a-frwy | \
	fsl,ls1046a-frwy-sdboot | \
	fsl,ls1046a-rdb | \
	fsl,ls1046a-rdb-sdboot | \
	fsl,ls1088a-rdb | \
	fsl,ls1088a-rdb-sdboot | \
	fsl,ls2088a-rdb | \
	fsl,lx2160a-rdb | \
	fsl,lx2160a-rdb-sdboot)
		return 0
		;;
	*)
		echo "Sysupgrade is not currently supported on $board"
		;;
	esac

	return 1
}
platform_do_upgrade() {
	local board=$(board_name)

	# Force the creation of fw_printenv.lock
	mkdir -p /var/lock
	touch /var/lock/fw_printenv.lock

	case "$board" in
	mono,gateway-dk)
		platform_do_upgrade_mono "$1"
		return $?
		;;
	traverse,ten64)
		platform_do_upgrade_traverse_slotubi "${1}"
		;;
	fsl,ls1012a-frdm | \
	fsl,ls1012a-rdb | \
	fsl,ls1021a-twr | \
	fsl,ls1028a-rdb | \
	fsl,ls1043a-rdb | \
	fsl,ls1046a-frwy | \
	fsl,ls1046a-rdb | \
	fsl,ls1088a-rdb | \
	fsl,ls2088a-rdb | \
	fsl,lx2160a-rdb)
		PART_NAME=firmware
		default_do_upgrade "$1"
		;;
	fsl,ls1012a-frwy-sdboot | \
	fsl,ls1021a-iot-sdboot | \
	fsl,ls1021a-twr-sdboot | \
	fsl,ls1028a-rdb-sdboot | \
	fsl,ls1043a-rdb-sdboot | \
	fsl,ls1046a-frwy-sdboot | \
	fsl,ls1046a-rdb-sdboot | \
	fsl,ls1088a-rdb-sdboot | \
	fsl,lx2160a-rdb-sdboot)
		platform_do_upgrade_sdboot "$1"
		return 0
		;;
	*)
		echo "Sysupgrade is not currently supported on $board"
		;;
	esac
}

#
# Copyright 2015-2019 Traverse Technologies
# Copyright 2020 NXP
#

RAMFS_COPY_BIN=""
RAMFS_COPY_DATA=""

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
# added, MONO_ROOT_START_SECTOR must track their (32 + boot size) * 2048.
MONO_ROOT_START_SECTOR=196608
MONO_BOOT_START_SECTOR=65536

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
	local root part disk removable type

	grep -q "mono,gateway-dk" /sys/firmware/devicetree/base/compatible 2>/dev/null || {
		echo "Not a Mono Gateway - refusing" >&2; return 1; }
	root="$(mono_cmdline_root)" || { echo "Cannot determine root= from /proc/cmdline" >&2; return 1; }
	case "$root" in
	/dev/mmcblk*p2) part="${root##*/}" ;;
	*) echo "Refusing unsupported root device: $root" >&2; return 1 ;;
	esac
	disk="${part%p2}"
	case "$disk" in
	mmcblk | mmcblk*[!0-9]*) echo "Refusing malformed eMMC name: $disk" >&2; return 1 ;;
	esac
	[ -b "/dev/$part" ]       || { echo "$part is not a block device" >&2; return 1; }
	[ -d "/sys/block/$disk" ] || { echo "eMMC $disk not present in sysfs" >&2; return 1; }
	mono_part_matches "$part" 2 "$MONO_ROOT_START_SECTOR" || {
		echo "Refusing: $part is not partition 2 at sector $MONO_ROOT_START_SECTOR" >&2; return 1; }
	removable="$(cat "/sys/block/$disk/removable" 2>/dev/null)"
	[ "$removable" = "0" ] || { echo "Refusing removable disk $disk (not soldered eMMC)" >&2; return 1; }
	type="$(cat "/sys/block/$disk/device/type" 2>/dev/null)"
	[ "$type" = "MMC" ] || { echo "Refusing non-eMMC disk $disk (type '$type')" >&2; return 1; }

	echo "/dev/$part"
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
	local board_dir=$(tar tf $tar_file | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	local rootpart bootpart disk
	rootpart="$(mono_gateway_root_part)" || {
		echo "Refusing upgrade: could not validate the target eMMC"; return 1; }
	disk="${rootpart%p2}"
	bootpart="${disk}p1"		# boot is the sibling of the validated rootfs
	# Boot is written FIRST and is the more catastrophic target, so validate it
	# to the same standard as the rootfs (index 1 at the expected start sector).
	[ -b "$bootpart" ] && mono_part_matches "${bootpart#/dev/}" 1 "$MONO_BOOT_START_SECTOR" || {
		echo "Boot partition $bootpart failed validation"; return 1; }

	# The "kernel" member is the complete boot partition image
	# (Image.gz + dtb + extlinux.conf), so the device tree and boot
	# config always match the kernel they were built with. The GPT
	# and the raw boot firmware in the first 32 MiB are never touched.
	echo "Writing boot partition to $bootpart..."
	mono_dd_member "$tar_file" "$board_dir" kernel "$bootpart" || {
		echo "Boot partition write to $bootpart failed"; return 1; }
	echo "Writing rootfs to $rootpart..."
	mono_dd_member "$tar_file" "$board_dir" root "$rootpart" || {
		echo "Rootfs write to $rootpart failed"; return 1; }
	# rootfs ships at 384M; the uci-defaults script in it re-expands
	# to the full partition on first boot
}

platform_copy_config_mono() {
	local rootpart
	rootpart="$(mono_gateway_root_part)" || {
		echo "Could not validate rootfs for config backup"; return 1; }
	mkdir -p /tmp/new_root
	if mount -t ext4 -o rw,noatime "$rootpart" /tmp/new_root; then
		echo "Saving config backup to new rootfs..."
		cp -af "$UPGRADE_BACKUP" /tmp/new_root/sysupgrade.tgz
		umount /tmp/new_root
	fi
}

platform_copy_config() {
	local board=$(board_name)

	case "$board" in
	mono,gateway-dk | \
	mono,gateway-dk-sdboot)
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
	mono,gateway-dk | \
	mono,gateway-dk-sdboot)
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
	mono,gateway-dk | \
	mono,gateway-dk-sdboot)
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

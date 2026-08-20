# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright 2018-2020 NXP

define Device/Default
  PROFILES := Default
  IMAGES := firmware.bin sysupgrade.bin
  DEVICE_DTS_DIR := $(DTS_DIR)/freescale
  DEVICE_DTS = $(subst _,-,$(1))
  FILESYSTEMS := squashfs
  KERNEL := kernel-bin | gzip | uImage gzip
  KERNEL_INITRAMFS = kernel-bin | gzip | fit gzip $$(DEVICE_DTS_DIR)/$$(DEVICE_DTS).dtb
  KERNEL_LOADADDR := 0x80000000
  IMAGE_SIZE := 64m
  IMAGE/sysupgrade.bin = \
    ls-append-dtb $$(DEVICE_DTS) | pad-to 1M | \
    append-kernel | pad-to 17M | \
    append-rootfs | pad-rootfs | \
    check-size $(LS_SYSUPGRADE_IMAGE_SIZE) | append-metadata
endef

define Device/fsl-sdboot
  KERNEL = kernel-bin | gzip | fit gzip $$(DEVICE_DTS_DIR)/$$(DEVICE_DTS).dtb
  IMAGES := sdcard.img.gz sysupgrade.bin
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef

define Device/fsl_ls1012a-frdm
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := FRDM-LS1012A
  DEVICE_PACKAGES += \
    layerscape-ppfe \
    kmod-ppfe
  BLOCKSIZE := 256KiB
  IMAGE/firmware.bin := \
    ls-clean | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 10M | \
    ls-append pfe.itb | pad-to 15M | \
    ls-append-dtb $$(DEVICE_DTS) | pad-to 16M | \
    append-kernel | pad-to $$(BLOCKSIZE) | \
    append-rootfs | pad-rootfs | check-size
  IMAGE/sysupgrade.bin := \
    append-kernel | pad-to $$(BLOCKSIZE) | \
    append-rootfs | pad-rootfs | \
    check-size $(LS_SYSUPGRADE_IMAGE_SIZE) | append-metadata
  KERNEL := kernel-bin | gzip | fit gzip $$(DEVICE_DTS_DIR)/$$(DEVICE_DTS).dtb
endef
TARGET_DEVICES += fsl_ls1012a-frdm

define Device/fsl_ls1012a-rdb
  $(Device/fix-sysupgrade)
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := LS1012A-RDB
  DEVICE_PACKAGES += \
    layerscape-ppfe \
    kmod-hwmon-ina2xx \
    kmod-iio-fxas21002c-i2c \
    kmod-iio-fxos8700-i2c \
    kmod-ppfe
  IMAGE/firmware.bin := \
    ls-clean | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 10M | \
    ls-append pfe.itb | pad-to 15M | \
    ls-append-dtb $$(DEVICE_DTS) | pad-to 16M | \
    append-kernel | pad-to 32M | \
    append-rootfs | pad-rootfs | check-size
endef
TARGET_DEVICES += fsl_ls1012a-rdb

define Device/fsl_ls1012a-frwy-sdboot
  $(Device/rework-sdcard-images)
  $(Device/fsl-sdboot)
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := FRWY-LS1012A
  DEVICE_PACKAGES += \
    layerscape-ppfe \
    kmod-ppfe
  DEVICE_DTS := fsl-ls1012a-frwy
  IMAGES += firmware.bin
  IMAGE/firmware.bin := \
    ls-clean | \
    ls-append $(1)-bl2.pbl | pad-to 128K | \
    ls-append pfe.itb | pad-to 384K | \
    ls-append $(1)-fip.bin | pad-to 1856K | \
    ls-append $(1)-uboot-env.bin | pad-to 2048K | \
    check-size 2097153
  IMAGE/sdcard.img.gz := \
    ls-clean | \
    ls-append-sdhead $(1) | pad-to 16M | \
    ls-append-kernel | pad-to $(LS_SD_ROOTFSPART_OFFSET)M | \
    append-rootfs | pad-to $(LS_SD_IMAGE_SIZE)M | gzip
endef
TARGET_DEVICES += fsl_ls1012a-frwy-sdboot

define Device/fsl_ls1028a-rdb
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := LS1028A-RDB
  DEVICE_VARIANT := Default
  KERNEL = kernel-bin | gzip | fit gzip $$(DEVICE_DTS_DIR)/$$(DEVICE_DTS).dtb
  DEVICE_PACKAGES += \
    kmod-hwmon-ina2xx \
    kmod-hwmon-lm90 \
    kmod-rtc-pcf2127
  IMAGE/firmware.bin := \
    ls-clean | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 16M | \
    append-kernel | \
    append-rootfs | pad-rootfs | check-size
  IMAGE/sysupgrade.bin := \
    append-kernel | \
    append-rootfs | pad-rootfs | \
    check-size $(LS_SYSUPGRADE_IMAGE_SIZE) | append-metadata
endef
TARGET_DEVICES += fsl_ls1028a-rdb

define Device/fsl_ls1028a-rdb-sdboot
  $(Device/fsl-sdboot)
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := LS1028A-RDB
  DEVICE_VARIANT := SD Card Boot
  DEVICE_DTS := fsl-ls1028a-rdb
  DEVICE_PACKAGES += \
    kmod-hwmon-ina2xx \
    kmod-hwmon-lm90 \
    kmod-rtc-pcf2127
  IMAGE/sdcard.img.gz := \
    ls-clean | \
    ls-append-sdhead $(1) | pad-to 4K | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 16M | \
    ls-append-kernel | pad-to $(LS_SD_ROOTFSPART_OFFSET)M | \
    append-rootfs | pad-to $(LS_SD_IMAGE_SIZE)M | gzip
endef
TARGET_DEVICES += fsl_ls1028a-rdb-sdboot

define Device/fsl_ls1043a-rdb
  $(Device/fix-sysupgrade)
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := LS1043A-RDB
  DEVICE_VARIANT := Default
  DEVICE_PACKAGES += \
    kmod-ahci-qoriq \
    kmod-hwmon-ina2xx \
    kmod-hwmon-lm90
  IMAGE/firmware.bin := \
    ls-clean | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 9M | \
    ls-append $(1)-fman.bin | pad-to 15M | \
    ls-append-dtb $$(DEVICE_DTS) | pad-to 16M | \
    append-kernel | pad-to 32M | \
    append-rootfs | pad-rootfs | check-size
endef
TARGET_DEVICES += fsl_ls1043a-rdb

define Device/fsl_ls1043a-rdb-sdboot
  $(Device/rework-sdcard-images)
  $(Device/fsl-sdboot)
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := LS1043A-RDB
  DEVICE_VARIANT := SD Card Boot
  DEVICE_PACKAGES += \
    kmod-ahci-qoriq \
    kmod-hwmon-ina2xx \
    kmod-hwmon-lm90
  DEVICE_DTS := fsl-ls1043a-rdb
  IMAGE/sdcard.img.gz := \
    ls-clean | \
    ls-append-sdhead $(1) | pad-to 4K | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 9M | \
    ls-append fsl_ls1043a-rdb-fman.bin | pad-to 16M | \
    ls-append-kernel | pad-to $(LS_SD_ROOTFSPART_OFFSET)M | \
    append-rootfs | pad-to $(LS_SD_IMAGE_SIZE)M | gzip
endef
TARGET_DEVICES += fsl_ls1043a-rdb-sdboot

define Device/fsl_ls1046a-frwy
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := FRWY-LS1046A
  DEVICE_VARIANT := Default
  IMAGE/firmware.bin := \
    ls-clean | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 9M | \
    ls-append fsl_ls1046a-rdb-fman.bin | pad-to 15M | \
    ls-append-dtb $$(DEVICE_DTS) | pad-to 16M | \
    append-kernel | pad-to 32M | \
    append-rootfs | pad-rootfs | check-size
endef
TARGET_DEVICES += fsl_ls1046a-frwy

define Device/fsl_ls1046a-frwy-sdboot
  $(Device/fsl-sdboot)
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := FRWY-LS1046A
  DEVICE_VARIANT := SD Card Boot
  DEVICE_DTS := fsl-ls1046a-frwy
  IMAGE/sdcard.img.gz := \
    ls-clean | \
    ls-append-sdhead $(1) | pad-to 4K | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 9M | \
    ls-append fsl_ls1046a-rdb-fman.bin | pad-to 16M | \
    ls-append-kernel | pad-to $(LS_SD_ROOTFSPART_OFFSET)M | \
    append-rootfs | pad-to $(LS_SD_IMAGE_SIZE)M | gzip
endef
TARGET_DEVICES += fsl_ls1046a-frwy-sdboot

define Device/fsl_ls1046a-rdb
  $(Device/fix-sysupgrade)
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := LS1046A-RDB
  DEVICE_VARIANT := Default
  DEVICE_PACKAGES += \
    kmod-ahci-qoriq \
    kmod-hwmon-ina2xx \
    kmod-hwmon-lm90
  IMAGE/firmware.bin := \
    ls-clean | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 9M | \
    ls-append $(1)-fman.bin | pad-to 15M | \
    ls-append-dtb $$(DEVICE_DTS) | pad-to 16M | \
    append-kernel | pad-to 32M | \
    append-rootfs | pad-rootfs | check-size
endef
TARGET_DEVICES += fsl_ls1046a-rdb

define Device/fsl_ls1046a-rdb-sdboot
  $(Device/rework-sdcard-images)
  $(Device/fsl-sdboot)
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := LS1046A-RDB
  DEVICE_VARIANT := SD Card Boot
  DEVICE_PACKAGES += \
    kmod-ahci-qoriq \
    kmod-hwmon-ina2xx \
    kmod-hwmon-lm90
  DEVICE_DTS := fsl-ls1046a-rdb
  IMAGE/sdcard.img.gz := \
    ls-clean | \
    ls-append-sdhead $(1) | pad-to 4K | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 9M | \
    ls-append fsl_ls1046a-rdb-fman.bin | pad-to 16M | \
    ls-append-kernel | pad-to $(LS_SD_ROOTFSPART_OFFSET)M | \
    append-rootfs | pad-to $(LS_SD_IMAGE_SIZE)M | gzip
endef
TARGET_DEVICES += fsl_ls1046a-rdb-sdboot

define Device/fsl_ls1088a-rdb
  $(Device/fix-sysupgrade)
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := LS1088A-RDB
  DEVICE_VARIANT := Default
  DEVICE_PACKAGES += \
    restool \
    kmod-ahci-qoriq \
    kmod-hwmon-ina2xx \
    kmod-hwmon-lm90
  IMAGE/firmware.bin := \
    ls-clean | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 10M | \
    ls-append $(1)-mc.itb | pad-to 13M | \
    ls-append $(1)-dpl.dtb | pad-to 14M | \
    ls-append $(1)-dpc.dtb | pad-to 15M | \
    ls-append-dtb $$(DEVICE_DTS) | pad-to 16M | \
    append-kernel | pad-to 32M | \
    append-rootfs | pad-rootfs | check-size
endef
TARGET_DEVICES += fsl_ls1088a-rdb

define Device/fsl_ls1088a-rdb-sdboot
  $(Device/rework-sdcard-images)
  $(Device/fsl-sdboot)
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := LS1088A-RDB
  DEVICE_VARIANT := SD Card Boot
  DEVICE_PACKAGES += \
    restool \
    kmod-ahci-qoriq \
    kmod-hwmon-ina2xx \
    kmod-hwmon-lm90
  DEVICE_DTS := fsl-ls1088a-rdb
  IMAGE/sdcard.img.gz := \
    ls-clean | \
    ls-append-sdhead $(1) | pad-to 4K | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 10M | \
    ls-append fsl_ls1088a-rdb-mc.itb | pad-to 13M | \
    ls-append fsl_ls1088a-rdb-dpl.dtb | pad-to 14M | \
    ls-append fsl_ls1088a-rdb-dpc.dtb | pad-to 16M | \
    ls-append-kernel | pad-to $(LS_SD_ROOTFSPART_OFFSET)M | \
    append-rootfs | pad-to $(LS_SD_IMAGE_SIZE)M | gzip
endef
TARGET_DEVICES += fsl_ls1088a-rdb-sdboot

define Device/fsl_ls2088a-rdb
  $(Device/fix-sysupgrade)
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := LS2088ARDB
  DEVICE_PACKAGES += \
    restool \
    kmod-ahci-qoriq
  IMAGE/firmware.bin := \
    ls-clean | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 10M | \
    ls-append $(1)-mc.itb | pad-to 13M | \
    ls-append $(1)-dpl.dtb | pad-to 14M | \
    ls-append $(1)-dpc.dtb | pad-to 15M | \
    ls-append-dtb $$(DEVICE_DTS) | pad-to 16M | \
    append-kernel | pad-to 32M | \
    append-rootfs | pad-rootfs | check-size
endef
TARGET_DEVICES += fsl_ls2088a-rdb

define Device/fsl_lx2160a-rdb
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := LX2160A-RDB
  DEVICE_VARIANT := Rev2.0 silicon
  DEVICE_PACKAGES += restool
  IMAGE/firmware.bin := \
    ls-clean | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 8M | \
    ls-append $(1)-fip_ddr_all.bin | pad-to 10M | \
    ls-append $(1)-mc.itb | pad-to 13M | \
    ls-append $(1)-dpl.dtb | pad-to 14M | \
    ls-append $(1)-dpc.dtb | pad-to 15M | \
    ls-append-dtb $$(DEVICE_DTS) | pad-to 16M | \
    append-kernel | pad-to 32M | \
    append-rootfs | pad-rootfs | check-size
endef
TARGET_DEVICES += fsl_lx2160a-rdb

define Device/fsl_lx2160a-rdb-sdboot
  $(Device/fsl-sdboot)
  DEVICE_VENDOR := NXP
  DEVICE_MODEL := LX2160A-RDB
  DEVICE_VARIANT := Rev2.0 silicon SD Card Boot
  DEVICE_PACKAGES += restool
  DEVICE_DTS := fsl-lx2160a-rdb
  IMAGE/sdcard.img.gz := \
    ls-clean | \
    ls-append-sdhead $(1) | pad-to 4K | \
    ls-append $(1)-bl2.pbl | pad-to 1M | \
    ls-append $(1)-fip.bin | pad-to 5M | \
    ls-append $(1)-uboot-env.bin | pad-to 8M | \
    ls-append fsl_lx2160a-rdb-fip_ddr_all.bin | pad-to 10M | \
    ls-append fsl_lx2160a-rdb-mc.itb | pad-to 13M | \
    ls-append fsl_lx2160a-rdb-dpl.dtb | pad-to 14M | \
    ls-append fsl_lx2160a-rdb-dpc.dtb | pad-to 16M | \
    ls-append-kernel | pad-to $(LS_SD_ROOTFSPART_OFFSET)M | \
    append-rootfs | pad-to $(LS_SD_IMAGE_SIZE)M | gzip
endef
TARGET_DEVICES += fsl_lx2160a-rdb-sdboot

define Device/traverse_ten64_mtd
  DEVICE_VENDOR := Traverse
  DEVICE_MODEL := Ten64 (NAND boot)
  DEVICE_NAME := ten64-mtd
  DEVICE_PACKAGES += \
    uboot-envtools \
    kmod-rtc-rx8025 \
    kmod-sfp \
    kmod-i2c-mux-pca954x \
    restool
  DEVICE_DESCRIPTION = \
    Generate images for booting from NAND/ubifs on Traverse Ten64 (LS1088A) \
    family boards. For disk (NVMe/USB/SD) boot, use the armvirt target instead.
  FILESYSTEMS := squashfs
  KERNEL_LOADADDR := 0x80000000
  KERNEL_ENTRY_POINT := 0x80000000
  FDT_LOADADDR := 0x90000000
  KERNEL_SUFFIX := -kernel.itb
  DEVICE_DTS := fsl-ls1088a-ten64
  IMAGES := nand.ubi sysupgrade.bin
  KERNEL := kernel-bin | gzip | traverse-fit-ls1088 gzip $$(DTS_DIR)/$$(DEVICE_DTS).dtb $$(FDT_LOADADDR)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  IMAGE/nand.ubi := append-ubi
  KERNEL_IN_UBI := 1
  BLOCKSIZE := 128KiB
  PAGESIZE := 2048
  MKUBIFS_OPTS := -m $$(PAGESIZE) -e 124KiB -c 600
  SUPPORTED_DEVICES = traverse,ten64
endef
TARGET_DEVICES += traverse_ten64_mtd

# Boot partition for the Mono Gateway: ext4 with /boot/extlinux for the
# QSPI/eMMC U-Boot's `sysboot mmc 0:1 any ... /boot/extlinux/extlinux.conf`
define Build/mono-bootfs
	rm -rf $@.bootdir $@.bootfs
	mkdir -p $@.bootdir/boot/extlinux
	$(CP) $(IMAGE_KERNEL) $@.bootdir/boot/Image.gz
	$(CP) $(DEVICE_DTS_DIR)/$(DEVICE_DTS).dtb $@.bootdir/boot/
	# SELinux mode is set by /etc/selinux/config (SELINUX=permissive during bring-up);
	# a kernel `enforcing=` arg here is overridden at policy load, so it's not used.
	# root= is per-slot: U-Boot's sysboot expands $${rootpart} (set by bootcmd's
	# set_slot_a/b) in the append line (pxe_utils cli_simple_process_macros), so
	# ONE image boots either A/B slot. $$ keeps make from eating the ${..} - it
	# must reach the file literally for U-Boot to expand at boot. default+timeout
	# make the single label auto-boot even if a second entry is ever added.
	printf 'default OpenWrt\ntimeout 10\nlabel OpenWrt\n\tkernel /boot/Image.gz\n\tfdt /boot/%s.dtb\n\tappend root=/dev/mmcblk0p$${rootpart} rootwait console=ttyS0,115200 earlycon=uart8250,mmio,0x21c0500 panic=10\n' \
		"$(DEVICE_DTS)" > $@.bootdir/boot/extlinux/extlinux.conf
	# GPT blobs travel in the boot partition: the 33-sector backup tail (first
	# boot dd's it to the device end so the on-disk table is complete) and the
	# 4 KiB primary table (the sysupgrade migration path dd's it to repartition
	# an old-layout unit to the A/B + /data GPT - platform_do_upgrade_mono).
	python3 mono_gpt.py backup $@.bootdir/boot/backup-gpt.bin \
		$(MONO_EMMC_SECTORS) $(MONO_BOOTFS_SIZE) $(MONO_ROOTFS_PART)
	python3 mono_gpt.py primary $@.bootdir/boot/primary-gpt.bin \
		$(MONO_EMMC_SECTORS) $(MONO_BOOTFS_SIZE) $(MONO_ROOTFS_PART)
	truncate -s $(MONO_BOOTFS_SIZE)M $@.bootfs
	$(STAGING_DIR_HOST)/bin/mkfs.ext4 -F -L boot -d $@.bootdir $@.bootfs
endef

define Build/mono-emmc-img
	rm -f $@
	./gen_mono_emmc_img.sh $@ $@.bootfs $(IMAGE_ROOTFS) \
		$(MONO_BOOTFS_SIZE) $(MONO_ROOTFS_PART) $(MONO_EMMC_SECTORS) $(MONO_ROOTFS_STAGE)
endef

# Same resize-metadata prep as the eMMC image (make_ext4fs output
# cannot be grown online); the boot partition blob travels as the
# "kernel" member so dtb and extlinux.conf always match the kernel.
define Build/mono-sysupgrade
	cp $(IMAGE_ROOTFS) $@.rootfs
	e2fsck -fy $@.rootfs || true
	truncate -s $(MONO_ROOTFS_STAGE)M $@.rootfs
	resize2fs $@.rootfs
	sh $(TOPDIR)/scripts/sysupgrade-tar.sh \
		--board $(subst _,$(comma),$(DEVICE_NAME)) \
		--kernel $@.bootfs \
		--rootfs $@.rootfs \
		$@
	rm -f $@.rootfs
endef

define Device/mono_gateway-dk
  DEVICE_VENDOR := Mono
  DEVICE_MODEL := Gateway DK
  # Fat base image = r9's full package set + the ASU cutover (r10, the first ASU
  # release). Nothing r9 baked is dropped, so a plain r9->r10 sysupgrade loses
  # nothing (r9 has no owut to preserve packages, so this one hop can't rely on
  # ASU). The update path IS ASU now: owut (CLI) + luci-app-attendedsysupgrade
  # (LuCI), pointed at https://sysupgrade.mono.si by mono-asu-config; the old
  # mono-update signed/anti-rollback client + its LuCI app are retired here (owut
  # bakes packages server-side). The lean trim + OpenVPN-DCO + wireguard-as-module
  # move to r11, where owut preserves each device's real package set (so lean only
  # ever hits new/factory installs).
  #
  # Everything that must be IN ASU-rebuilt images lives HERE, not in the .seed: the
  # ASU ImageBuilder installs only DEVICE_PACKAGES (+ target/global DEFAULT_PACKAGES)
  # and IGNORES the seed's CONFIG_PACKAGE_x=y, so a seed-only package is absent from
  # owut rebuilds. (adguardhome stays seed-only for now: the release image bakes it
  # and owut preserves it per-device, so nobody loses it on the r9->r10 upgrade.)
  DEVICE_PACKAGES := kmod-ask-cdx kmod-ask-fci kmod-ask-auto-bridge \
	cmm cmmqos dpa-app fmc \
	kmod-leds-lp5812 kmod-sfp-led fancontrol lm-sensors irqbalance \
	kmod-i2c-core kmod-hwmon-core kmod-hwmon-ina2xx kmod-hwmon-lm90 \
	kmod-regmap-core kmod-regmap-i2c i2csfp i2c-tools usbutils pciutils \
	kmod-nxp-mwifiex nxp-wifi-firmware-9098-pcie wpad-openssl iw usteer luci-app-usteer \
	luci-light libustream-mbedtls px5g-mbedtls -luci-app-package-manager luci-app-statistics \
	ip-full ethtool-full tcpdump telnet-bsd \
	strongswan strongswan-default strongswan-mod-openssl openvpn-openssl luci-app-openvpn \
	kmod-wireguard wireguard-tools luci-proto-wireguard tailscale \
	adblock luci-app-adblock https-dns-proxy luci-app-https-dns-proxy banip luci-app-banip \
	nlbwmon luci-app-nlbwmon vnstat2 luci-app-vnstat2 iftop mtr htop iperf3 \
	ddns-scripts luci-app-ddns miniupnpd luci-app-upnp umdns etherwake watchcat \
	ksmbd-server luci-app-ksmbd \
	block-mount kmod-usb-storage-uas kmod-fs-exfat kmod-fs-ntfs3 kmod-fs-vfat smartmontools \
	tmux vim-full curl rsync jq less bind-dig openssh-sftp-server file \
	resize2fs e2fsprogs usign ca-bundle uboot-envtools mono-ab-env \
	owut luci-app-attendedsysupgrade attendedsysupgrade-common mono-asu-config \
	selinux-policy busybox-selinux procd-selinux auditd \
	policycoreutils policycoreutils-setfiles policycoreutils-sestatus
  KERNEL_NAME := Image
  KERNEL := kernel-bin | gzip
  FILESYSTEMS := ext4
  # A/B + persistent-data eMMC layout (see mono_gpt.py): two 1 GiB rootfs slots
  # (rootA=p2 keeps the pre-A/B start sector), two 64 MiB boot slots, and /data
  # (p5) filling the rest (~27.5 GiB). MONO_ROOTFS_PART is the PER-SLOT size.
  MONO_BOOTFS_SIZE := 64
  MONO_ROOTFS_PART := 1024
  MONO_EMMC_SECTORS := 62160896
  # Build-time rootfs staging size (MiB): the ext4 is truncated to this then
  # resize2fs'd down to it, and grown to fill the 1 GiB slot (MONO_ROOTFS_PART)
  # on first boot. Must exceed the actual rootfs content. The fat r10 base (r9's
  # full package set + ASU) is ~373M like r9, so 512 gives comfortable headroom.
  # Keep it comfortably below MONO_ROOTFS_PART; bump if the base image grows.
  MONO_ROOTFS_STAGE := 512
  # Keep the -sdboot alias: units flashed before 02_sysinfo_fixup stopped
  # appending it still report mono,gateway-dk-sdboot at runtime, and sysupgrade
  # refuses an image whose SUPPORTED_DEVICES lacks the running board name.
  SUPPORTED_DEVICES := mono,gateway-dk mono,gateway-dk-sdboot
  IMAGES := emmc.img.gz sysupgrade.bin sysupgrade-legacy.bin
  IMAGE/emmc.img.gz := mono-bootfs | mono-emmc-img | gzip | append-metadata
  IMAGE/sysupgrade.bin := mono-bootfs | mono-sysupgrade | gzip | append-metadata
  # Same tar, uncompressed: firmware that predates the gzip-capable flash
  # path cannot read sysupgrade.bin, so latest.json keeps advertising this
  # one under "sysupgrade" (old clients) and the gzipped one under
  # "sysupgrade_gz". Drop it only once no deployed device predates gzip
  # support - a straggler waking up after months still needs it.
  IMAGE/sysupgrade-legacy.bin := mono-bootfs | mono-sysupgrade | append-metadata
endef
TARGET_DEVICES += mono_gateway-dk


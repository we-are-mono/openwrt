# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2016 Jiang Yutang <jiangyutang1978@gmail.com>

include $(TOPDIR)/rules.mk

BOARD:=layerscape
BOARDNAME:=NXP Layerscape

KERNEL_PATCHVER:=6.12

# ASK hardware-offload integration rides OpenWrt's OWN kernel (no git-cloned NXP
# vendor kernel, no custom Kernel/Prepare). The NXP DPAA/FMan/QBMan SDK driver
# source and the 3 SDK-flavour DPAA device-tree includes are vendored as files/,
# and ASK's kernel hooks as patches-6.12/010-101 -- both synced from pinned ASK +
# NXP refs by scripts/mono-sync-ask-kernel.sh (run its --check to guard drift).
# OpenWrt's normal FILES_DIR overlay + patch flow apply them; the generic patch
# stack (which git-clone mode used to skip) now applies itself.

FEATURES:=squashfs nand usb pcie gpio fpu ubifs ext4 rootfs-part boot-part
SUBTARGETS:=armv8_64b armv7

define Target/Description
	Build firmware images for NXP Layerscape based boards.
endef

include $(INCLUDE_DIR)/target.mk

DEFAULT_PACKAGES += kmod-usb3 kmod-usb-dwc3 kmod-usb-storage \
  mkf2fs e2fsprogs partx-utils

$(eval $(call BuildTarget))

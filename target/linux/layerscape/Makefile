# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2016 Jiang Yutang <jiangyutang1978@gmail.com>

include $(TOPDIR)/rules.mk

BOARD:=layerscape
BOARDNAME:=NXP Layerscape

KERNEL_PATCHVER:=6.12
# Real version of the NXP vendor kernel fetched via KERNEL_GIT_CLONE_URI;
# names the build dir and gives kmod packages an apk-valid version.
KERNEL_GIT_LINUX_VERSION:=6.12.49

# Authoritative pin for the NXP vendor kernel (tag lf-6.12.49-2.2.0). This is
# the source of truth; the build seed sets CONFIG_KERNEL_GIT_REF to match.
# If a git-clone kernel build uses any other ref (or the seed was skipped and
# it defaulted to HEAD), stop hard rather than silently building a different,
# non-reproducible kernel the ASK patch series may not even apply to.
MONO_KERNEL_GIT_REF:=df24f9428e38740256a410b983003a478e72a7c0
ifeq ($(TARGET_BUILD),1)
  ifneq ($(call qstrip,$(CONFIG_KERNEL_GIT_CLONE_URI)),)
    ifneq ($(call qstrip,$(CONFIG_KERNEL_GIT_REF)),$(MONO_KERNEL_GIT_REF))
      $(error CONFIG_KERNEL_GIT_REF='$(call qstrip,$(CONFIG_KERNEL_GIT_REF))' != pinned $(MONO_KERNEL_GIT_REF); use configs/mono_gateway-dk.seed)
    endif
  endif
endif

FEATURES:=squashfs nand usb pcie gpio fpu ubifs ext4 rootfs-part boot-part
SUBTARGETS:=armv8_64b armv7

define Target/Description
	Build firmware images for NXP Layerscape based boards.
endef

include $(INCLUDE_DIR)/target.mk

DEFAULT_PACKAGES += kmod-usb3 kmod-usb-dwc3 kmod-usb-storage \
  mkf2fs e2fsprogs partx-utils

# ASK hardware-offload integration.
#
# The offload stack requires the NXP vendor kernel (sdk_dpaa/sdk_fman/qbman),
# selected via CONFIG_KERNEL_GIT_CLONE_URI. In that mode OpenWrt skips all
# kernel patching (generic + platform), so it is restored here: the ASK
# repository is fetched at a pinned revision and its kernel patch series is
# applied, followed by the OpenWrt-integration patches in patches-ask/
# (cherry-picks from the generic stack that OpenWrt userspace depends on).
ASK_VERSION:=9b683f8d26cd352d90e29453e28c57928f200b38
ASK_SOURCE:=ask-$(ASK_VERSION).tar.xz
ASK_SUBDIR:=ask-$(ASK_VERSION)

ifeq ($(TARGET_BUILD),1)
ifneq ($(call qstrip,$(CONFIG_KERNEL_GIT_CLONE_URI)),)

  define Download/ask
    URL:=https://github.com/we-are-mono/ASK
    PROTO:=git
    SOURCE_VERSION:=$(ASK_VERSION)
    FILE:=$(ASK_SOURCE)
    SUBDIR:=$(ASK_SUBDIR)
  endef
  $(eval $(call Download,ask))

  KERNEL_FILE_DEPENDS+=$(PLATFORM_DIR)/patches-ask $(PLATFORM_DIR)/files-ask

  # 0*.patch only: 999-* is the legacy 5.4 reference monolith, never applied.
  # files-ask/ overlays board files (mono-gateway-dk.dts, vendored from the
  # meta-mono layer) onto the vendor tree; the dtb-y append is idempotent.
  define Kernel/Prepare
	$(call Kernel/Prepare/Default)
	rm -rf $(KERNEL_BUILD_DIR)/$(ASK_SUBDIR) $(KERNEL_BUILD_DIR)/ask-kernel-patches
	xzcat $(DL_DIR)/$(ASK_SOURCE) | $(TAR) -C $(KERNEL_BUILD_DIR) -xf -
	mkdir -p $(KERNEL_BUILD_DIR)/ask-kernel-patches
	$(CP) $(KERNEL_BUILD_DIR)/$(ASK_SUBDIR)/patches/kernel/0*.patch $(KERNEL_BUILD_DIR)/ask-kernel-patches/
	$(call PatchDir,$(LINUX_DIR),$(KERNEL_BUILD_DIR)/ask-kernel-patches,ask/)
	$(call PatchDir,$(LINUX_DIR),$(PLATFORM_DIR)/patches-ask,ask-openwrt/)
	$(CP) $(PLATFORM_DIR)/files-ask/. $(LINUX_DIR)/
	grep -q "mono-gateway-dk" $(LINUX_DIR)/arch/arm64/boot/dts/freescale/Makefile || \
		echo 'dtb-y += mono-gateway-dk.dtb' \
			>> $(LINUX_DIR)/arch/arm64/boot/dts/freescale/Makefile
  endef

$(STAMP_PREPARED): $(DL_DIR)/$(ASK_SOURCE)

endif
endif

$(eval $(call BuildTarget))

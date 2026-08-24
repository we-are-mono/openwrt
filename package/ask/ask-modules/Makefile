include $(TOPDIR)/rules.mk
include $(TOPDIR)/package/ask/ask-version.mk

PKG_NAME:=ask-modules
PKG_VERSION:=$(ASK_PKG_VERSION)
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=$(ASK_SOURCE_URL)
PKG_SOURCE_VERSION:=$(ASK_VERSION)
PKG_SOURCE:=$(ASK_SOURCE)
PKG_SOURCE_SUBDIR:=ask-$(ASK_VERSION)
PKG_MIRROR_HASH:=fc028771e175372f10eae0fec169da00dbed1c4f61a97f795511577efe36c887

PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/kernel.mk

PKG_BUILD_DIR:=$(KERNEL_BUILD_DIR)/ask-modules-$(ASK_VERSION)

include $(INCLUDE_DIR)/package.mk

define KernelPackage/ask-cdx
  SUBMENU:=Network Devices
  TITLE:=ASK CDX fast-path translator (DPAA)
  DEPENDS:=@TARGET_layerscape
  FILES:=$(PKG_BUILD_DIR)/cdx/cdx.ko
  AUTOLOAD:=$(call AutoLoad,30,cdx)
endef

define KernelPackage/ask-cdx/description
  Programs DPAA hardware (FMan external hash table, CEETM, SEC frame
  queues) from CMM/FPP commands. Spawns /usr/bin/dpa_app at init to
  apply the FMan PCD classification graph.
endef

define KernelPackage/ask-auto-bridge
  SUBMENU:=Network Devices
  TITLE:=ASK automatic bridging module
  DEPENDS:=@TARGET_layerscape +kmod-ask-cdx
  FILES:=$(PKG_BUILD_DIR)/auto_bridge/auto_bridge.ko
  AUTOLOAD:=$(call AutoLoad,31,auto_bridge)
endef

define KernelPackage/ask-auto-bridge/description
  L2 bridge flow learning for the ASK fast path. Subscribes to the
  kernel brevent notifier chain and reports bridged flows over
  NETLINK_L2FLOW so they can be hardware-forwarded.
endef

define KernelPackage/ask-fci
  SUBMENU:=Network Devices
  TITLE:=ASK Fast Control Interface
  DEPENDS:=@TARGET_layerscape +kmod-ask-cdx +kmod-nf-conntrack-netlink +kmod-ipt-conntrack
  FILES:=$(PKG_BUILD_DIR)/fci/fci.ko
  AUTOLOAD:=$(call AutoLoad,52,fci)
endef

define KernelPackage/ask-fci/description
  Netlink bridge (NETLINK_FF) routing FPP command messages between
  the cmm daemon and the cdx kernel backend. Loaded after the
  conntrack stack, per the ASK module load order.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	xzcat $(DL_DIR)/$(ASK_SOURCE) | $(TAR) -C $(PKG_BUILD_DIR) --strip-components=1 -xf -
	printf '/*Auto-generated file. Do not edit !*/\n#ifndef CDX_VERSION_H\n\n#define CDX_VERSION_H\n\n#define CDX_VERSION "ask-%.12s"\n\n#endif /* CDX_VERSION_H */\n' \
		"$(ASK_VERSION)" > $(PKG_BUILD_DIR)/cdx/version.h
endef

ASK_KBUILD_ARGS:= \
	CROSS_COMPILE="$(KERNEL_CROSS)" \
	ARCH="$(LINUX_KARCH)" \
	PLATFORM=LS1043A

define Build/Compile
	+$(KERNEL_MAKE) M=$(PKG_BUILD_DIR)/cdx \
		$(ASK_KBUILD_ARGS) KERNELDIR=$(LINUX_DIR) KERNELVERSION=6.12 \
		CONFIG_ASK_CDX=m modules
	+$(KERNEL_MAKE) M=$(PKG_BUILD_DIR)/fci \
		$(ASK_KBUILD_ARGS) KERNEL_SOURCE=$(LINUX_DIR) BOARD_ARCH=$(LINUX_KARCH) \
		KBUILD_EXTRA_SYMBOLS=$(PKG_BUILD_DIR)/cdx/Module.symvers \
		CONFIG_ASK_FCI=m modules
	+$(KERNEL_MAKE) M=$(PKG_BUILD_DIR)/auto_bridge \
		$(ASK_KBUILD_ARGS) KERNEL_SOURCE=$(LINUX_DIR) \
		CONFIG_ASK_AUTO_BRIDGE=m modules
endef

$(eval $(call KernelPackage,ask-cdx))
$(eval $(call KernelPackage,ask-auto-bridge))
$(eval $(call KernelPackage,ask-fci))

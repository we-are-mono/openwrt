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
PKG_MIRROR_HASH:=74918243a9b40e7959e59430a0ff26eb1285e2b22947d83da843509e1116da1f

PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/kernel.mk

PKG_BUILD_DIR:=$(KERNEL_BUILD_DIR)/ask-modules-$(ASK_VERSION)

include $(INCLUDE_DIR)/package.mk

# No AUTOLOAD on either module: ASK's platform contract gates all hardware
# activation on the recovery budget being armed, so ask-flowtable's init script
# loads them only after /etc/init.d/ask-recovery succeeds.
define KernelPackage/ask-cdx
  SUBMENU:=Network Devices
  TITLE:=ASK CDX hardware backend (DPAA)
  DEPENDS:=@TARGET_layerscape
  FILES:=$(PKG_BUILD_DIR)/cdx/cdx.ko
endef

define KernelPackage/ask-cdx/description
  Brings up the DPAA/FMan offload hardware: builds the FMan PCD in-kernel at
  module init and programs the external hash tables, CEETM queues and SEC
  frame queues. Load-once; it has no supported unload.
endef

define KernelPackage/ask-flowtable
  SUBMENU:=Network Devices
  TITLE:=ASK Linux flowtable offload adapter
  DEPENDS:=@TARGET_layerscape +kmod-ask-cdx +kmod-nf-flow +kmod-nft-offload
  FILES:=$(PKG_BUILD_DIR)/cdx/ask_flowtable.ko
endef

define KernelPackage/ask-flowtable/description
  Binds nftables flowtables declaring 'flags offload' on CDX-backed ports
  and installs their flows into the CDX hardware. Reloadable.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	xzcat $(DL_DIR)/$(ASK_SOURCE) | $(TAR) -C $(PKG_BUILD_DIR) --strip-components=1 -xf -
endef

define Build/Compile
	+$(KERNEL_MAKE) M=$(PKG_BUILD_DIR)/cdx \
		CROSS_COMPILE="$(KERNEL_CROSS)" ARCH="$(LINUX_KARCH)" PLATFORM=LS1046A \
		KERNELDIR=$(LINUX_DIR) KERNELVERSION=6.12 \
		CONFIG_ASK_CDX=m modules
endef

$(eval $(call KernelPackage,ask-cdx))
$(eval $(call KernelPackage,ask-flowtable))

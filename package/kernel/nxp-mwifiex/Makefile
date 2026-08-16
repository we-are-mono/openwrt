#
# NXP MXM Wi-Fi driver (moal + mlan) for the 88W9098 (u-blox JODY-W3), PCIe.
#
# Source: nxp-imx/mwifiex, branch hotfix/lf-6.12.49_2.2.0_hotfix.
# It is a cfg80211 FULLMAC driver (not mac80211) -> built against OpenWrt's
# backports headers/symbols (the mac80211 package). Drive AP with hostapd.
#
include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=nxp-mwifiex
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/nxp-imx/mwifiex.git
PKG_SOURCE_DATE:=2026-08-15
PKG_SOURCE_VERSION:=09f41e1423e4806a127507d5fa284cd02c46772f
PKG_MIRROR_HASH:=skip

PKG_BUILD_DEPENDS:=mac80211
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define KernelPackage/nxp-mwifiex
  SECTION:=kernel
  CATEGORY:=Kernel modules
  SUBMENU:=Wireless Drivers
  TITLE:=NXP 88W9098 (moal/mlan) PCIe Wi-Fi driver
  URL:=https://github.com/nxp-imx/mwifiex
  # +@DRIVER_11AC/AX_SUPPORT: hostapd's VHT(11ac)/HE(11ax) code is gated on these
  # symbols, normally select-ed by mac80211 driver pkgs. We build no kmod-mac80211
  # (fullmac needs only cfg80211), so this driver must select them itself — else
  # wpad is HT-only (Wi-Fi 4) and add_iface fails on any vht_*/he_* config item.
  # (11AX also auto-selects WPA_MBO_SUPPORT, which aids band steering.)
  DEPENDS:=@PCI_SUPPORT +kmod-cfg80211 +nxp-wifi-firmware-9098-pcie +@DRIVER_11AC_SUPPORT +@DRIVER_11AX_SUPPORT
  FILES:= \
	$(PKG_BUILD_DIR)/mlan.ko \
	$(PKG_BUILD_DIR)/moal.ko
  AUTOLOAD:=$(call AutoProbe,mlan moal)
endef

define KernelPackage/nxp-mwifiex/description
 NXP MXM Wi-Fi driver (moal + mlan) for the 88W9098 (u-blox JODY-W3) over PCIe.
 cfg80211 fullmac; drive the AP with hostapd over nl80211.
endef

# Prepend OpenWrt's backports cfg80211 headers so they win over the in-kernel
# ones, and force-include backport/backport.h (defines CPTCFG_CFG80211 etc.).
# Order mirrors backports' own Makefile.kernel: backport-include first, then
# the refreshed subsystem headers (include/), each with its uapi/ sibling.
BACKPORT_INC:= \
	-I$(STAGING_DIR)/usr/include/mac80211-backport \
	-I$(STAGING_DIR)/usr/include/mac80211-backport/uapi \
	-I$(STAGING_DIR)/usr/include/mac80211 \
	-I$(STAGING_DIR)/usr/include/mac80211/uapi \
	-include backport/backport.h

# Build only the PCIe-9098 chip; drop every SDIO/USB/other-PCIe variant.
NXP_CHIP_FLAGS:= \
	CONFIG_PCIE9098=y \
	CONFIG_SD8978=n CONFIG_SD8987=n CONFIG_SD9177=n CONFIG_SD9098=n \
	CONFIG_SDIW610=n CONFIG_USBIW610=n CONFIG_SDAW693=n CONFIG_PCIEAW693=n \
	CONFIG_PCIE9097=n CONFIG_PCIE8897=n

# cfg80211 FULLMAC only. Force the driver's STA/uAP cfg80211 knobs on and its
# legacy WEXT knobs off, bypassing the upstream Makefile's CPTCFG/CONFIG_CFG80211
# autodetection (which reads CPP macros as make vars and has a copy-paste bug in
# the uAP branch). Command-line vars can't be overridden by the driver Makefile.
NXP_FEATURE_FLAGS:= \
	CONFIG_NXP_WLAN_DRIVER=m \
	CONFIG_OPENWRT_SUPPORT=y \
	CONFIG_STA_SUPPORT=y \
	CONFIG_UAP_SUPPORT=y \
	CONFIG_STA_CFG80211=y \
	CONFIG_UAP_CFG80211=y \
	CONFIG_STA_WEXT=n \
	CONFIG_UAP_WEXT=n

# The driver Makefile builds obj-m := mlan.o + moal.o under the kernel Kbuild.
# KERNEL_MAKEOPTS already supplies -C $(LINUX_DIR), the cross toolchain and
# KBUILD_EXTRA_SYMBOLS (=$(KERNEL_BUILD_DIR)/symvers/*.symvers, i.e. cfg80211's
# exports from the mac80211 package). We cd into the module dir first so the
# driver's own "-I$(PWD)/mlan" resolves there ("-C" moves CURDIR, not $(PWD)),
# and inject the backports headers via NOSTDINC_FLAGS so they precede
# LINUXINCLUDE (the exact slot backports uses).
define Build/Compile
	+cd $(PKG_BUILD_DIR) && \
	$(MAKE) $(PKG_JOBS) $(KERNEL_MAKEOPTS) \
		M=$(PKG_BUILD_DIR) \
		KERNELDIR=$(LINUX_DIR) \
		NOSTDINC_FLAGS="$(BACKPORT_INC) -nostdinc" \
		$(NXP_FEATURE_FLAGS) \
		$(NXP_CHIP_FLAGS) \
		modules
endef

$(eval $(call KernelPackage,nxp-mwifiex))

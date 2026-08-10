include $(TOPDIR)/rules.mk
include $(TOPDIR)/package/ask/ask-version.mk

PKG_NAME:=cmm
PKG_VERSION:=$(ASK_PKG_VERSION)
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=$(ASK_SOURCE_URL)
PKG_SOURCE_VERSION:=$(ASK_VERSION)
PKG_SOURCE:=$(ASK_SOURCE)
PKG_SOURCE_SUBDIR:=ask-$(ASK_VERSION)
PKG_MIRROR_HASH:=skip

PKG_BUILD_DIR:=$(BUILD_DIR)/cmm-ask-$(ASK_VERSION)
PKG_BUILD_PARALLEL:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/cmm
  SECTION:=net
  CATEGORY:=Network
  TITLE:=ASK Connection Manager (conntrack monitor / fast-path control)
  DEPENDS:=@TARGET_layerscape +libcli +libpcap +libmnl +libnetfilter-conntrack \
	+kmod-ask-fci +kmod-ask-auto-bridge +kmod-nf-conntrack-netlink
endef

define Package/cmm/description
  Watches conntrack, routing, neighbour and interface state and
  programs offloadable flows into the DPAA fast path through
  libfci -> NETLINK_FF -> fci.ko -> cdx.ko.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	xzcat $(DL_DIR)/$(ASK_SOURCE) | $(TAR) -C $(PKG_BUILD_DIR) --strip-components=1 -xf -
endef

# CFLAGS/LDFLAGS go through the environment, not the command line: both
# Makefiles build their include/define lists with CFLAGS +=, which a
# command-line assignment would override.
define Build/Compile
	+CFLAGS="$(TARGET_CFLAGS)" \
	$(MAKE) -C $(PKG_BUILD_DIR)/fci/lib \
		CC="$(TARGET_CC)" AR="$(TARGET_AR)"
	+CFLAGS="$(TARGET_CFLAGS) $(TARGET_CPPFLAGS)" \
	LDFLAGS="$(TARGET_LDFLAGS)" \
	$(MAKE) -C $(PKG_BUILD_DIR)/cmm \
		CC="$(TARGET_CC)" \
		LIBFCI_DIR=$(PKG_BUILD_DIR)/fci/lib \
		ABM_DIR=$(PKG_BUILD_DIR)/auto_bridge \
		PKG_CONFIG="$(PKG_CONFIG)" \
		PKG_CONFIG_PATH="$(STAGING_DIR)/usr/lib/pkgconfig" \
		SYSROOT="$(STAGING_DIR)/usr"
endef

define Package/cmm/conffiles
/etc/config/fastforward
endef

define Package/cmm/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/cmm/src/cmm $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/config/fastforward $(1)/etc/config/fastforward
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/cmm.init $(1)/etc/init.d/cmm
endef

$(eval $(call BuildPackage,cmm))

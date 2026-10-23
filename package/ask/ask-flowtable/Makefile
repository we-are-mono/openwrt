include $(TOPDIR)/rules.mk
include $(TOPDIR)/package/ask/ask-version.mk

PKG_NAME:=ask-flowtable
PKG_VERSION:=$(ASK_PKG_VERSION)
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=$(ASK_SOURCE_URL)
PKG_SOURCE_VERSION:=$(ASK_VERSION)
PKG_SOURCE:=$(ASK_SOURCE)
PKG_SOURCE_SUBDIR:=ask-$(ASK_VERSION)
PKG_MIRROR_HASH:=f34d1b0cca758393e9c60ac83012a12cc82df5a63d48e27eec5f478dc7bdf7cc

PKG_LICENSE:=GPL-2.0

PKG_BUILD_DIR:=$(BUILD_DIR)/ask-flowtable-$(ASK_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/ask-flowtable
  SECTION:=net
  CATEGORY:=Network
  TITLE:=ASK hardware flow-offload service
  DEPENDS:=@TARGET_layerscape +kmod-ask-flowtable +nftables +mono-ab-env +jsonfilter \
	+kmod-sched-core +kmod-sched-flower +kmod-sched-act-police +tc-full +devlink \
	+kmod-ip6-tunnel
endef

define Package/ask-flowtable/description
  Declares and maintains the nftables flowtable that drives the ASK CDX
  hardware offload (table inet ask_flowtable), reconciling /etc/ask/offload.conf
  and backend health. Also ships ask-recovery: a procd hardware-watchdog monitor
  with a U-Boot-env reboot budget, which gates loading the ASK modules.
endef

define Package/ask-flowtable/conffiles
/etc/ask/offload.conf
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	xzcat $(DL_DIR)/$(ASK_SOURCE) | $(TAR) -C $(PKG_BUILD_DIR) --strip-components=1 -xf -
	$(Build/Patch)
endef

# flowtable/Makefile appends its own flags with +=, so pass ours through the
# environment rather than the command line (which would override them).
define Build/Compile
	CFLAGS="$(TARGET_CFLAGS) $(TARGET_CPPFLAGS)" LDFLAGS="$(TARGET_LDFLAGS)" \
		$(MAKE) -C $(PKG_BUILD_DIR)/flowtable CC="$(TARGET_CC)" all
endef

define Package/ask-flowtable/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/usr/libexec $(1)/etc/ask $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/flowtable/src/ask-flowtable $(1)/usr/sbin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/integration/ask-recovery-monitor $(1)/usr/libexec/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/integration/openwrt/ask-recovery $(1)/etc/init.d/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/config/offload.conf $(1)/etc/ask/
	$(INSTALL_BIN) ./files/ask-flowtable.init $(1)/etc/init.d/ask-flowtable
endef

$(eval $(call BuildPackage,ask-flowtable))

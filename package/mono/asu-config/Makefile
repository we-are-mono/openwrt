include $(TOPDIR)/rules.mk

PKG_NAME:=mono-asu-config
PKG_VERSION:=1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/mono-asu-config
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Mono Gateway ASU (attended-sysupgrade) server config
  DEPENDS:=@TARGET_layerscape +attendedsysupgrade-common
endef

define Package/mono-asu-config/description
  Points the Attended Sysupgrade client (owut CLI + luci-app-attendedsysupgrade)
  at the mono self-hosted build server https://sysupgrade.mono.si instead of the
  stock sysupgrade.openwrt.org. Ships a first-boot uci-defaults script that runs
  after 50-attendedsysupgrade (the base default config) and 51-attendedsysupgrade-owut,
  so the mono URL is the value that sticks. Kept as its own package - NOT a
  buildroot files/ overlay - so the ASU ImageBuilder reproduces it in every
  rebuilt image (the IB installs only packages, never the buildroot overlay).
endef

define Build/Compile
endef

define Package/mono-asu-config/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/52-mono-asu-server $(1)/etc/uci-defaults/52-mono-asu-server
endef

$(eval $(call BuildPackage,mono-asu-config))

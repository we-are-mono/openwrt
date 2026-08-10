include $(TOPDIR)/rules.mk

PKG_NAME:=mono-update-check
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/mono-update-check
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Mono Gateway update checker
  DEPENDS:=@TARGET_layerscape
endef

define Package/mono-update-check/description
  Daily check of a mono firmware server (latest.json) against the
  image's baked release tag. Disabled until uci sets the server URL:
    uci set mono-update.check.url='https://.../openwrt'
  mode 'notify' (default) logs availability; mode 'auto' downloads,
  verifies sha256 and applies sysupgrade unattended.
endef

define Build/Compile
endef

# Bake the release identity this image was built as. The mono-update.sh
# release flow tags the tree before building; developer builds get 'dev'
# and the checker treats any difference as an available update.
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	git -C $(TOPDIR) describe --tags --match 'mono-v*' --abbrev=0 \
		> $(PKG_BUILD_DIR)/mono_release 2>/dev/null || \
		echo "dev" > $(PKG_BUILD_DIR)/mono_release
endef

define Package/mono-update-check/conffiles
/etc/config/mono-update
endef

define Package/mono-update-check/install
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/mono_release $(1)/etc/mono_release
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/mono-update.config $(1)/etc/config/mono-update
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/mono-update-check $(1)/usr/sbin/
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/90-mono-update-cron $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,mono-update-check))

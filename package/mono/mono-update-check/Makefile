include $(TOPDIR)/rules.mk

PKG_NAME:=mono-update-check
PKG_VERSION:=1.0
PKG_RELEASE:=4
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/mono-update-check
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Mono Gateway update checker
  # usign: verify the release signature. ca-bundle: validate the server
  # TLS cert on the https fetch (both are the update trust chain, so they
  # are hard deps, not left to transitive luck from other packages).
  DEPENDS:=@TARGET_layerscape +usign +ca-bundle +curl
endef

define Package/mono-update-check/description
  Daily check of a mono firmware server (latest.json) against the
  image's baked release tag. Disabled until uci sets the server URL:
    uci set mono-update.check.url='https://.../openwrt'
  mode 'notify' (default) logs availability; mode 'auto' verifies the
  release signature (usign) against the baked public key, then the image
  hash against the signed hash list, then applies sysupgrade unattended.
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
	# Trusted release signing keys (public halves): the primary key used
	# nightly, plus an offline rotation key so a lost primary never strands
	# the fleet. Private halves never leave the release host / offline media.
	$(INSTALL_DIR) $(1)/etc/mono-keys
	$(INSTALL_DATA) ./files/mono-release.pub $(1)/etc/mono-keys/mono-release.pub
	$(INSTALL_DATA) ./files/mono-rotation.pub $(1)/etc/mono-keys/mono-rotation.pub
	# Preserve the anti-rollback floor across sysupgrade.
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/mono-update.keep $(1)/lib/upgrade/keep.d/mono-update
endef

$(eval $(call BuildPackage,mono-update-check))

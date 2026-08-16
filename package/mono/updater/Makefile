include $(TOPDIR)/rules.mk

PKG_NAME:=mono-update
PKG_VERSION:=1.1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/mono-update
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Mono Gateway OTA updater (CLI)
  # usign: verify the release signature. ca-bundle: validate the server
  # TLS cert on the https fetch (both are the update trust chain, so they
  # are hard deps, not left to transitive luck from other packages).
  DEPENDS:=@TARGET_layerscape +usign +ca-bundle +curl
endef

define Package/mono-update/description
  On-demand and scheduled OTA updater for Mono Gateway. Compares the image's
  baked release tag against a SIGNED latest.json on the update server:
    mono-update --check      report whether a newer signed release exists
    mono-update --install    verify signature + image hash, then sysupgrade
  A daily cron job runs --check (notify). Disabled until uci sets the URL:
    uci set mono-update.check.url='https://openwrt.mono.si'
  Set mono-update.check.mode='auto' to have cron run --install unattended.
endef

define Package/luci-app-mono-update
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI page for the Mono Gateway updater
  DEPENDS:=+mono-update +luci-base
endef

define Package/luci-app-mono-update/description
  A LuCI "Updates" page under the System menu that drives mono-update from the
  web UI: shows the running release, checks the server on a button click, and
  applies a signature+hash-verified upgrade (reboots) on confirmation.
endef

define Build/Compile
endef

# Bake the release identity this image was built as. The mono-update.sh
# release flow tags the tree before building; developer builds get 'dev'
# and the updater treats any difference as an available update.
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	git -C $(TOPDIR) describe --tags --match 'mono-v*' --abbrev=0 \
		> $(PKG_BUILD_DIR)/mono_release 2>/dev/null || \
		echo "dev" > $(PKG_BUILD_DIR)/mono_release
endef

define Package/mono-update/conffiles
/etc/config/mono-update
endef

define Package/mono-update/install
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/mono_release $(1)/etc/mono_release
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/mono-update.config $(1)/etc/config/mono-update
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/mono-update $(1)/usr/sbin/
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

define Package/luci-app-mono-update/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view
	$(INSTALL_DATA) ./files/luci/view/mono-update.js $(1)/www/luci-static/resources/view/mono-update.js
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/luci/menu.json $(1)/usr/share/luci/menu.d/luci-app-mono-update.json
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/luci/acl.json $(1)/usr/share/rpcd/acl.d/luci-app-mono-update.json
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/luci/rpcd-mono-update $(1)/usr/libexec/rpcd/mono-update
endef

$(eval $(call BuildPackage,mono-update))
$(eval $(call BuildPackage,luci-app-mono-update))

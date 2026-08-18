include $(TOPDIR)/rules.mk
include $(TOPDIR)/package/ask/ask-version.mk

PKG_NAME:=dpa-app
PKG_VERSION:=$(ASK_PKG_VERSION)
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=$(ASK_SOURCE_URL)
PKG_SOURCE_VERSION:=$(ASK_VERSION)
PKG_SOURCE:=$(ASK_SOURCE)
PKG_SOURCE_SUBDIR:=ask-$(ASK_VERSION)
PKG_MIRROR_HASH:=46e52870a12f5d94006aa736390a1a18baf85133cb409e0db7c81c34e3d93832

PKG_BUILD_DIR:=$(BUILD_DIR)/dpa-app-ask-$(ASK_VERSION)
PKG_BUILD_DEPENDS:=fmlib fmc
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/dpa-app
  SECTION:=net
  CATEGORY:=Network
  TITLE:=ASK FMan PCD loader (dpa_app)
  DEPENDS:=@TARGET_layerscape +libxml2 +libstdcpp +libcli +kmod-ask-cdx
endef

define Package/dpa-app/description
  One-shot boot-time tool, spawned by cdx.ko at module init, that
  applies the FMan PCD classification graph (/etc/cdx_pcd.xml,
  /etc/cdx_sp.xml, /etc/cdx_cfg.xml) whose leaf is the external
  hash table the fast path forwards from.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	xzcat $(DL_DIR)/$(ASK_SOURCE) | $(TAR) -C $(PKG_BUILD_DIR) --strip-components=1 -xf -
endef

# -DLS1043 is MANDATORY (see meta-ask dpa-app recipe): it selects
# dpaa_integration_LS1043.h / DPAA_VERSION=11. libfmc.a is built with
# -DLS1043 (fmc Makefile, MACHINE=ls1046); without it here,
# sizeof(fmc_model_t) differs between dpa_app and the library and
# fmc_compile's memset() overruns the BSS allocation and SIGSEGVs.
define Build/Compile
	+$(MAKE) -C $(PKG_BUILD_DIR)/dpa_app \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS) $(TARGET_CPPFLAGS) \
			-DENDIAN_LITTLE -DLS1043 -DNCSW_LINUX \
			-DDPAA_DEBUG_ENABLE -DSEC_PROFILE_SUPPORT -DVLAN_FILTER \
			-I$(STAGING_DIR)/usr/include/fmc \
			-I$(PKG_BUILD_DIR)/cdx \
			-I$(STAGING_DIR)/include/fmd \
			-I$(STAGING_DIR)/include/fmd/Peripherals \
			-I$(STAGING_DIR)/include/fmd/integrations \
			-I$(STAGING_DIR)/usr/include/libxml2" \
		LDFLAGS="$(TARGET_LDFLAGS) -lpthread -lcli \
			-L$(STAGING_DIR)/usr/lib -lfmc -lfm -lstdc++ -lxml2 -lm"
endef

# cdx_cfg.xml is the only device-specific ASK input; all variants ship
# and a preinit hook links the right one for the booted board (preinit,
# not uci-defaults: cdx.ko autoloads before uci-defaults run).
define Package/dpa-app/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/dpa_app/dpa_app $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/dpa_app/files/etc/cdx_pcd.xml $(1)/etc/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/dpa_app/files/etc/cdx_sp.xml $(1)/etc/
	$(INSTALL_DIR) $(1)/etc/cdx_cfg
	for cfg in $(PKG_BUILD_DIR)/config/*/cdx_cfg.xml; do \
		$(INSTALL_DATA) $$$$cfg $(1)/etc/cdx_cfg/$$$$(basename $$$$(dirname $$$$cfg)).xml; \
	done
	$(INSTALL_DIR) $(1)/lib/preinit
	$(INSTALL_DATA) ./files/81_cdx_cfg_select $(1)/lib/preinit/
endef

$(eval $(call BuildPackage,dpa-app))

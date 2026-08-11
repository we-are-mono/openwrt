include $(TOPDIR)/rules.mk
include $(TOPDIR)/package/ask/ask-version.mk

PKG_NAME:=fmc
PKG_VERSION:=$(ASK_NXP_PKG_VERSION)
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/nxp-qoriq/fmc
PKG_SOURCE_VERSION:=15a31335e254ba18134244bfd6dc57304a0cbfb4
PKG_MIRROR_HASH:=b76a583985d0db33580e6ae9b1ec66bf3c99bbc685a432c1324ceca17ab5ad4b

PKG_BUILD_PARALLEL:=0
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/fmc
  SECTION:=net
  CATEGORY:=Network
  DEPENDS:=@TARGET_layerscape +libxml2 +libstdcpp
  TITLE:=Layerscape Frame Manager Configuration tool (ASK-extended)
endef

define Package/fmc/description
  Converts Parse-Classify-Police-Distribute (PCD) XML descriptions
  into FMan hardware configuration. Carries the mono ASK extensions
  (port ID, shared-scheme replication, PPPoE field fix). libfmc is
  linked statically into dpa_app; the fmc binary is shipped for
  manual PCD work.
endef

MAKE_PATH:=source
MAKE_FLAGS += \
	MACHINE=ls1046 \
	FMD_USPACE_HEADER_PATH="$(STAGING_DIR)/include/fmd" \
	FMD_USPACE_LIB_PATH="$(STAGING_DIR)/usr/lib" \
	LIBXML2_HEADER_PATH="$(STAGING_DIR)/usr/include/libxml2" \
	TCLAP_HEADER_PATH="$(STAGING_DIR)/usr/include"

PKG_BUILD_DEPENDS:=fmlib tclap

define Build/InstallDev
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_BUILD_DIR)/source/*.a $(1)/usr/lib/
	$(INSTALL_DIR) $(1)/usr/include/fmc
	$(CP) $(PKG_BUILD_DIR)/source/fmc.h $(1)/usr/include/fmc/
endef

define Package/fmc/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(CP) $(PKG_BUILD_DIR)/source/fmc $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/fmc/config
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/etc/fmc/config/hxs_pdl_v3.xml $(1)/etc/fmc/config/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/etc/fmc/config/*.xsd $(1)/etc/fmc/config/
endef

$(eval $(call BuildPackage,fmc))

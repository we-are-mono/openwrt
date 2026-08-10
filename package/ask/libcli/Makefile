include $(TOPDIR)/rules.mk

PKG_NAME:=libcli
PKG_VERSION:=1.10.7
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/dparrish/libcli
PKG_SOURCE_VERSION:=dcfd3b72a5587c11b54c25d7ffe69bd7e03acb59
PKG_MIRROR_HASH:=skip

PKG_LICENSE:=LGPL-2.1
PKG_LICENSE_FILES:=COPYING

include $(INCLUDE_DIR)/package.mk

define Package/libcli
  SECTION:=libs
  CATEGORY:=Libraries
  TITLE:=Cisco-like telnet CLI library
  URL:=https://github.com/dparrish/libcli
endef

define Package/libcli/description
  Libcli provides a shared library for including a Cisco-like
  command-line interface into other software. Required by the ASK
  cmm and dpa_app control-plane tools.
endef

TARGET_CFLAGS += $(FPIC) -Wno-error=calloc-transposed-args

MAKE_FLAGS += \
	DEBUG="" \
	OPTIM="$(TARGET_CFLAGS)" \
	PREFIX="/usr" \
	DESTDIR="$(PKG_INSTALL_DIR)" \
	TESTS=0 \
	all install

define Build/InstallDev
	$(INSTALL_DIR) $(1)/usr/include
	$(CP) $(PKG_INSTALL_DIR)/usr/include/libcli.h $(1)/usr/include/
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libcli.so* $(1)/usr/lib/
endef

define Package/libcli/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libcli.so* $(1)/usr/lib/
endef

$(eval $(call BuildPackage,libcli))

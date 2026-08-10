include $(TOPDIR)/rules.mk
include $(TOPDIR)/package/ask/ask-version.mk

PKG_NAME:=fmlib
PKG_VERSION:=$(ASK_NXP_PKG_VERSION)
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/nxp-qoriq/fmlib
PKG_SOURCE_VERSION:=79c5c2ec2e1262b6331bd5f864d7bd60c310923c
PKG_MIRROR_HASH:=skip

PKG_BUILD_PARALLEL:=0
PKG_LICENSE:=BSD-3-Clause GPL-2.0

include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

define Package/fmlib
  SECTION:=libs
  CATEGORY:=Libraries
  TITLE:=Layerscape Frame Manager userspace library (ASK-extended)
  DEPENDS:=@TARGET_layerscape
  BUILDONLY:=1
endef

define Package/fmlib/description
  Static userspace library on top of the FMan driver ioctl interface,
  with the mono ASK extensions (external hash table, IP reassembly,
  shared schemes). Build-time dependency of fmc and dpa_app.
endef

MAKE_FLAGS += \
	libfm-arm.a install-libfm-arm \
	KERNEL_SRC="$(LINUX_DIR)" \
	PREFIX="$(PKG_INSTALL_DIR)"

define Build/InstallDev
	$(CP) $(PKG_INSTALL_DIR)/* $(1)/
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_BUILD_DIR)/libfm-arm.a $(1)/usr/lib/libfm.a
endef

$(eval $(call BuildPackage,fmlib))

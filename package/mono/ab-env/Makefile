include $(TOPDIR)/rules.mk

PKG_NAME:=mono-ab-env
PKG_VERSION:=1
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/mono-ab-env
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Mono Gateway A/B U-Boot env helper
  DEPENDS:=@TARGET_layerscape +uboot-envtools
endef

define Package/mono-ab-env/description
  Writes U-Boot env changes to BOTH firmware env media - QSPI (mtd3, the primary
  /etc/fw_env.config) and the eMMC copy (/dev/mmcblk0 @0x300000) - so the A/B
  slot + bootcount stay correct regardless of the board's firmware-boot DIP
  switch. Provides mono-fw-setenv (a write-both wrapper around fw_setenv) and
  ships /etc/fw_env.d/emmc.
endef

define Build/Compile
endef

define Package/mono-ab-env/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/mono-fw-setenv $(1)/usr/sbin/mono-fw-setenv
	$(INSTALL_DIR) $(1)/etc/fw_env.d
	$(INSTALL_DATA) ./files/fw_env.emmc $(1)/etc/fw_env.d/emmc
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/95-mono-ab-env $(1)/etc/uci-defaults/95-mono-ab-env
	# mark-good is a uci-default, NOT an init script: procd does not run a classic
	# init boot()/start() on the first boot after sysupgrade (verified on hw), but
	# uci-defaults do run then - which is exactly when a freshly-flashed slot must
	# confirm itself. It self-deletes once the trial is clear, and every image
	# ships it so each update's first boot re-runs it.
	$(INSTALL_BIN) ./files/96-mono-markgood $(1)/etc/uci-defaults/96-mono-markgood
endef

$(eval $(call BuildPackage,mono-ab-env))

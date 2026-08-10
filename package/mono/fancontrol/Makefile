include $(TOPDIR)/rules.mk

PKG_NAME:=fancontrol
PKG_VERSION:=3.6.0
PKG_RELEASE:=1

# Same lm-sensors revision the meta-mono layer pins, so the fancontrol
# algorithm (hysteresis, stall detection, restore-on-exit) is identical
# to what runs on the Yocto/Armbian builds.
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/lm-sensors/lm-sensors
PKG_SOURCE_VERSION:=1667b850a1ce38151dae17156276f981be6fb557
PKG_MIRROR_HASH:=skip

PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/fancontrol
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=lm-sensors fancontrol daemon (Mono Gateway curve)
  DEPENDS:=@TARGET_layerscape +bash
endef

define Package/fancontrol/description
  The lm-sensors fancontrol script with the Mono Gateway fan curve:
  linear 40-80 C on the SoC cluster_thermal sensor driving the EMC2305
  PWM (MINSTART 51, MINSTOP 34, 10s interval). hwmon indices are
  resolved by name at service start from the /etc/fancontrol.in
  template.
endef

define Build/Compile
endef

define Package/fancontrol/conffiles
/etc/fancontrol.in
endef

define Package/fancontrol/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/prog/pwm/fancontrol $(1)/usr/sbin/
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_DATA) ./files/fancontrol.in $(1)/etc/fancontrol.in
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/fancontrol.init $(1)/etc/init.d/fancontrol
endef

$(eval $(call BuildPackage,fancontrol))

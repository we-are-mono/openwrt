include $(TOPDIR)/rules.mk

PKG_NAME:=mono-leds
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

define KernelPackage/leds-lp5812
  SUBMENU:=LED modules
  TITLE:=TI LP5812 LED matrix controller
  DEPENDS:=@TARGET_layerscape
  FILES:=$(PKG_BUILD_DIR)/leds-lp5812/leds-lp5812.ko
  AUTOLOAD:=$(call AutoLoad,10,leds-lp5812)
endef

define KernelPackage/leds-lp5812/description
  I2C driver for the TI LP5812 4x3 LED matrix controller
  (status LEDs on the Mono Gateway). Loads early so
  /sys/class/leds/status:* exists before LED setup scripts run.
endef

define KernelPackage/sfp-led
  SUBMENU:=LED modules
  TITLE:=Mono SFP port LED controller
  DEPENDS:=@TARGET_layerscape
  FILES:=$(PKG_BUILD_DIR)/sfp-led/sfp-led.ko
  AUTOLOAD:=$(call AutoLoad,60,sfp-led)
endef

define KernelPackage/sfp-led/description
  Drives the SFP cage link/activity LEDs from module presence and
  optical signal state (mono,sfp-led device tree node).
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/. $(PKG_BUILD_DIR)/
	printf 'obj-m := sfp-led.o\n' > $(PKG_BUILD_DIR)/sfp-led/Makefile
	printf 'obj-m := leds-lp5812.o\n' > $(PKG_BUILD_DIR)/leds-lp5812/Makefile
endef

define Build/Compile
	+$(KERNEL_MAKE) M=$(PKG_BUILD_DIR)/sfp-led modules
	+$(KERNEL_MAKE) M=$(PKG_BUILD_DIR)/leds-lp5812 modules
endef

$(eval $(call KernelPackage,leds-lp5812))
$(eval $(call KernelPackage,sfp-led))

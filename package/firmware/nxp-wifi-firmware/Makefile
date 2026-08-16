#
# NXP 88W9098 PCIe Wi-Fi firmware (u-blox JODY-W3)
#
# Fetched from nxp-imx/imx-firmware (tag lf-6.12.49_2.2.0), dir FwImage_9098_PCIE,
# installed to /lib/firmware/nxp/ where the nxp-mwifiex (moal) driver loads it.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=nxp-wifi-firmware
PKG_VERSION:=6.12.49
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/nxp-imx/imx-firmware.git
PKG_SOURCE_DATE:=2026-08-15
PKG_SOURCE_VERSION:=8c9b278016c97527b285f2fcbe53c2d428eb171d
PKG_MIRROR_HASH:=skip

include $(INCLUDE_DIR)/package.mk

define Package/nxp-wifi-firmware-9098-pcie
  SECTION:=firmware
  CATEGORY:=Firmware
  TITLE:=NXP 88W9098 PCIe Wi-Fi firmware (JODY-W3)
  URL:=https://github.com/nxp-imx/imx-firmware
endef

define Package/nxp-wifi-firmware-9098-pcie/description
 NXP 88W9098 PCIe firmware + regulatory/TX-power config for the u-blox JODY-W3,
 from imx-firmware lf-6.12.49_2.2.0 (FwImage_9098_PCIE). Loaded by the
 nxp-mwifiex (moal) driver from /lib/firmware/nxp/.
endef

define Build/Compile
endef

FW9098:=$(PKG_BUILD_DIR)/FwImage_9098_PCIE

define Package/nxp-wifi-firmware-9098-pcie/install
	$(INSTALL_DIR) $(1)/lib/firmware/nxp
	$(INSTALL_DATA) $(FW9098)/pcieuart9098_combo_v1.bin $(1)/lib/firmware/nxp/
	$(INSTALL_DATA) $(FW9098)/pcie9098_wlan_v1.bin      $(1)/lib/firmware/nxp/
	$(INSTALL_DATA) $(FW9098)/uart9098_bt_v1.bin        $(1)/lib/firmware/nxp/
	$(INSTALL_DATA) $(FW9098)/ed_mac_ctrl_V3_909x.conf  $(1)/lib/firmware/nxp/
	$(INSTALL_DATA) $(FW9098)/txpwrlimit_cfg_9098.conf  $(1)/lib/firmware/nxp/
endef

$(eval $(call BuildPackage,nxp-wifi-firmware-9098-pcie))

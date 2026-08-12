#
# Mono Gateway — UCI front-end for the ASK cmm queue manager (CEETM QoS).
#
include $(TOPDIR)/rules.mk

PKG_NAME:=cmmqos
PKG_VERSION:=1
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0
PKG_MAINTAINER:=Mono <tomaz@zaman.io>

include $(INCLUDE_DIR)/package.mk

define Package/cmmqos
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Firewall
  TITLE:=Mono Gateway CEETM QoS (cmm qm-config front-end)
  DEPENDS:=@TARGET_layerscape +cmm
  PKGARCH:=all
endef

define Package/cmmqos/description
  UCI front-end for the ASK cmm queue manager: CEETM egress shaping,
  DSCP->queue maps and ingress policing. Renders /etc/config/cmmqos into
  cmm 'set qm' directives and applies them live via 'cmm -c qm-config'
  (item 7) without restarting cmm, which would drop the fast path.
  Off by default (config cmmqos 'global' option enabled '0').
endef

define Package/cmmqos/conffiles
/etc/config/cmmqos
endef

define Build/Compile
endef

define Package/cmmqos/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d
	$(INSTALL_CONF) ./files/cmmqos.config $(1)/etc/config/cmmqos
	$(INSTALL_BIN) ./files/cmmqos.init $(1)/etc/init.d/cmmqos
endef

$(eval $(call BuildPackage,cmmqos))

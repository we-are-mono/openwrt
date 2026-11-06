include $(TOPDIR)/rules.mk

PKG_NAME:=mono-asu-config
PKG_VERSION:=1
PKG_RELEASE:=3
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/mono-asu-config
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Mono Gateway ASU + apk feed server config
  DEPENDS:=@TARGET_layerscape +attendedsysupgrade-common
endef

define Package/mono-asu-config/description
  Points the mono package/update machinery at the self-hosted mono mirror instead
  of the stock OpenWRT servers, via first-boot uci-defaults scripts:

  52-mono-asu-server: the Attended Sysupgrade client (owut CLI +
  luci-app-attendedsysupgrade) -> https://sysupgrade.mono.si (runs after
  50-attendedsysupgrade and 51-attendedsysupgrade-owut, so the mono URL sticks).

  53-mono-apk-kmod-feed: the on-device apk TARGET (kernel-module) feed ->
  https://sysupgrade.mono.si, so `apk add` of a package that pulls a kmod (e.g.
  podman -> kmod-veth) resolves our own correct-vermagic modules; the userspace
  feeds stay on upstream.

  54-mono-nlbwmon-buffer + /etc/sysctl.d/10-mono-netlink.conf: nlbwmon gets a
  4 MiB netlink receive buffer (stock 512 KiB, capped by the kernel at 208 KiB)
  so a burst of connections no longer drops its conntrack dump. Only a stock
  buffer size is replaced.

  Kept as its own package - NOT a buildroot files/ overlay - so the ASU
  ImageBuilder reproduces it in every rebuilt image (the IB installs only
  packages, never the buildroot overlay).
endef

define Build/Compile
endef

define Package/mono-asu-config/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/52-mono-asu-server $(1)/etc/uci-defaults/52-mono-asu-server
	$(INSTALL_BIN) ./files/53-mono-apk-kmod-feed $(1)/etc/uci-defaults/53-mono-apk-kmod-feed
	$(INSTALL_BIN) ./files/54-mono-nlbwmon-buffer $(1)/etc/uci-defaults/54-mono-nlbwmon-buffer
	$(INSTALL_DIR) $(1)/etc/sysctl.d
	$(INSTALL_DATA) ./files/10-mono-netlink.conf $(1)/etc/sysctl.d/10-mono-netlink.conf
endef

$(eval $(call BuildPackage,mono-asu-config))

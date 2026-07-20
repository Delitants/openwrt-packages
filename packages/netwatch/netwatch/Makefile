include $(TOPDIR)/rules.mk

PKG_NAME:=netwatch
PKG_VERSION:=1.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/netwatch
	SECTION:=utils
	CATEGORY:=Utilities
	TITLE:=Lightweight host, TCP service, and network-interface monitor
	PKGARCH:=all
	DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-log +ucode-mod-socket +ucode-mod-ubus +ucode-mod-uci +ucode-mod-uloop +msmtp +ca-bundle
endef

define Package/netwatch/description
	Monitor hosts, TCP services, and network interfaces and send rate-limited SMTP alerts.
endef

define Build/Compile
endef

define Package/netwatch/conffiles
/etc/config/netwatch
endef

define Package/netwatch/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/netwatch $(1)/etc/config/netwatch
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/netwatch $(1)/etc/init.d/netwatch
	$(INSTALL_DIR) $(1)/usr/share/netwatch
	$(INSTALL_DATA) ./files/usr/share/netwatch/*.uc $(1)/usr/share/netwatch/
endef

$(eval $(call BuildPackage,netwatch))

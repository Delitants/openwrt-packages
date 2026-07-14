include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-scheduled-backup
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKGARCH:=all
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Scheduled Backup maintainers

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-scheduled-backup
	SECTION:=luci
	CATEGORY:=LuCI
	TITLE:=Scheduled configuration backups
	DEPENDS:=+luci-base +rpcd +rpcd-mod-file +uci +lftp +openssh-client +openssh-client-utils +openssh-keygen
endef

define Package/luci-app-scheduled-backup/conffiles
/etc/config/scheduled-backup
/etc/scheduled-backup/
endef

define Build/Compile
endef

define Package/luci-app-scheduled-backup/install
	$(INSTALL_DIR) $(1)
	$(CP) ./root/* $(1)/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/scheduled-backup $(1)/etc/config/scheduled-backup
	[ ! -d ./htdocs ] || $(CP) ./htdocs/* $(1)/
endef

$(eval $(call BuildPackage,luci-app-scheduled-backup))

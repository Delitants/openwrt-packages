include $(TOPDIR)/rules.mk

PKG_VERSION:=1.0.0
PKG_RELEASE:=2
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Scheduled Backup maintainers

LUCI_TITLE:=Scheduled configuration backups
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-file +uci +lftp +openssh-client +openssh-client-utils +openssh-keygen
LUCI_PKGARCH:=all

define Package/luci-app-scheduled-backup/conffiles
/etc/config/scheduled-backup
/etc/scheduled-backup/
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature

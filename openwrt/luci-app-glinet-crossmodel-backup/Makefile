include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-glinet-crossmodel-backup
PKG_VERSION:=1.1.0
PKG_RELEASE:=2
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Tech Relay
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=GL.iNet Cross-Model Backup / Restore
  DEPENDS:=+luci-base +uci +opkg +tar +jsonfilter +openssh-client +sshpass
endef

define Package/$(PKG_NAME)/description
Native LuCI utility for creating portable GL.iNet/OpenWrt configuration
profiles locally or from other LAN routers over SSH, then restoring
compatible settings onto a selected local or LAN router target.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./root/. $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)
	$(CP) $(PKG_BUILD_DIR)/. $(1)/
	chmod 0755 $(1)/usr/libexec/glinet-crossmodel-backup
	chmod 0755 $(1)/usr/libexec/glinet-crossmodel-remote
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-glinet-crossmodel-backup
PKG_VERSION:=1.1.0
PKG_RELEASE:=9
PKG_LICENSE:=MIT
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=GL.iNet Cross-Model Backup / Restore
  DEPENDS:=+luci-base
endef

define Package/$(PKG_NAME)/description
Portable GL.iNet and OpenWrt configuration profile utility.
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

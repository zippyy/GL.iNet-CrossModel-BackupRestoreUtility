include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-glinet-crossmodel-backup
PKG_VERSION:=2.0.0
PKG_RELEASE:=3
PKG_LICENSE:=MIT
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=GL.iNet Cross-Model Backup, Migration and Recovery
  DEPENDS:=+luci-base +openssh-client +sshpass +jsonfilter
endef

define Package/$(PKG_NAME)/description
Local and agentless-controller backup, migration, clone and recovery utility.
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
	chmod 0755 $(1)/usr/libexec/glinet-crossmodel-validate
	chmod 0755 $(1)/usr/libexec/gcm-glui-integrate
	chmod 0755 $(1)/usr/bin/glinet-crossmodel
	chmod 0644 $(1)/usr/lib/glinet-crossmodel/core.sh
	chmod 0755 $(1)/etc/init.d/gcm-glui-integration
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/glinet_crossmodel
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
mkdir -p /root/glinet-crossmodel/profiles /root/glinet-crossmodel/rollback /tmp/glinet-crossmodel /root/.ssh
chmod 700 /root/glinet-crossmodel /root/glinet-crossmodel/profiles /root/glinet-crossmodel/rollback /tmp/glinet-crossmodel /root/.ssh
touch /root/.ssh/known_hosts
chmod 600 /root/.ssh/known_hosts
/etc/init.d/gcm-glui-integration enable >/dev/null 2>&1 || true
/etc/init.d/gcm-glui-integration start >/dev/null 2>&1 || true
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/gcm-glui-integration stop >/dev/null 2>&1 || true
/etc/init.d/gcm-glui-integration disable >/dev/null 2>&1 || true
/usr/libexec/gcm-glui-integrate --remove >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

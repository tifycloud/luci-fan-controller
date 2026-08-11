include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ax9000-fan
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=CompanyWrt contributors
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-ax9000-fan
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=AX9000 fan controller LuCI panel
  DEPENDS:=+ax9000-fan-control +luci-base +luci-mod-admin-full +rpcd
  PKGARCH:=all
endef

define Package/luci-app-ax9000-fan/description
  Production dashboard and configuration form for the AX9000 fan controller.
  The panel reads status only through the fixed ax9000-fan-status helper.
endef

define Build/Compile
endef

define Package/luci-app-ax9000-fan/install
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/ax9000-fan
	$(CP) ./root/www/luci-static/resources/view/ax9000-fan/* $(1)/www/luci-static/resources/view/ax9000-fan/
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(CP) ./root/usr/share/luci/menu.d/* $(1)/usr/share/luci/menu.d/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(CP) ./root/usr/share/rpcd/acl.d/* $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/usr/share/ax9000-fan
	$(CP) ./root/usr/share/ax9000-fan/* $(1)/usr/share/ax9000-fan/
endef

$(eval $(call BuildPackage,luci-app-ax9000-fan))

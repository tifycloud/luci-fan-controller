include $(TOPDIR)/rules.mk

PKG_NAME:=ax9000-fan-control
PKG_VERSION:=1.0.0
PKG_RELEASE:=4
PKG_MAINTAINER:=CompanyWrt contributors
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/ax9000-fan-control
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Xiaomi AX9000 EMC2301 fan controller
  URL:=https://github.com/tifycloud/pplwrt
  DEPENDS:=+i2c-tools +kmod-hwmon-emc2305 +kmod-hwmon-core +kmod-thermal +kmod-i2c-core +kmod-regmap-i2c
  PKGARCH:=all
endef

define Package/ax9000-fan-control/description
  A procd-supervised, fail-safe fan controller for Xiaomi AX9000 and
  AX9000 Darkyun boards using the EMC2301/EMC2305 hwmon interface.
endef

define Package/ax9000-fan-control/conffiles
/etc/config/ax9000-fan
endef

# Package installation is fail-closed on unsupported hardware. Image builders
# set IPKG_INSTROOT while assembling a rootfs; board validation is performed by
# the runtime installer/first-boot package hook in that case.
define Package/ax9000-fan-control/preinst
#!/bin/sh
if [ -n "$${IPKG_INSTROOT:-}" ]; then
	exit 0
fi
board=
if [ "$${AX9000_ALLOW_BOARD_OVERRIDE:-0}" = 1 ]; then
	board="$${AX9000_BOARD_OVERRIDE:-}"
elif [ -r /tmp/sysinfo/board_name ]; then
	board="$$(sed -n '1p' /tmp/sysinfo/board_name 2>/dev/null)"
fi
if [ -z "$$board" ] && command -v ubus >/dev/null 2>&1; then
	board="$$(ubus call system board 2>/dev/null | sed -n 's/.*"board_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')"
fi
case "$$board" in
	xiaomi,ax9000|xiaomi,ax9000-darkyun) ;;
	*)
		echo "ax9000-fan-control: refusing unsupported/unknown board '$$board'" >&2
		exit 1
		;;
esac
exit 0
endef

define Package/ax9000-fan-control/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
[ -x /etc/init.d/ax9000-fan-control ] || {
	echo "ax9000-fan-control: init script is missing; refusing incomplete install" >&2
	exit 1
}
/etc/init.d/ax9000-fan-control enable >/dev/null 2>&1 || {
	echo "ax9000-fan-control: unable to enable service at boot" >&2
	exit 1
}
/etc/init.d/ax9000-fan-control restart >/dev/null 2>&1 || {
	echo "ax9000-fan-control: service failed to start; check the fail-safe status" >&2
	exit 1
}
exit 0
endef

define Package/ax9000-fan-control/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
[ -x /etc/init.d/ax9000-fan-control ] || {
	echo "ax9000-fan-control: init script is missing; refusing unsafe removal" >&2
	exit 1
}
[ -x /usr/libexec/ax9000-fan-force-fullspeed ] || {
	echo "ax9000-fan-control: full-speed helper is missing; refusing unsafe removal" >&2
	exit 1
}
/etc/init.d/ax9000-fan-control stop >/dev/null 2>&1 || exit 1
/usr/libexec/ax9000-fan-force-fullspeed >/dev/null 2>&1 || exit 1
/etc/init.d/ax9000-fan-control disable >/dev/null 2>&1 || exit 1
exit 0
endef

define Build/Compile
endef

define Package/ax9000-fan-control/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/ax9000-fan $(1)/etc/config/ax9000-fan
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/ax9000-fan-control $(1)/etc/init.d/ax9000-fan-control
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/ax9000-fan-control $(1)/usr/sbin/ax9000-fan-control
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/ax9000-fan-common $(1)/usr/libexec/ax9000-fan-common
	$(INSTALL_BIN) ./files/usr/libexec/ax9000-fan-force-fullspeed $(1)/usr/libexec/ax9000-fan-force-fullspeed
	$(INSTALL_BIN) ./files/usr/libexec/ax9000-fan-status $(1)/usr/libexec/ax9000-fan-status
	$(INSTALL_BIN) ./files/usr/libexec/ax9000-fan-validate $(1)/usr/libexec/ax9000-fan-validate
endef

$(eval $(call BuildPackage,ax9000-fan-control))

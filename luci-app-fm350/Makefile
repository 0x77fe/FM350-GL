include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-fm350
PKG_VERSION:=1.0.0
PKG_RELEASE:=44
# GPL-3.0-only：本包含从 luci-app-modem（GPLv3，作者 Siriling）抽取并修改的代码，
# 见 files/usr/lib/fm350/fibocom.sh 头部声明。
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=FM350 Users <fm350@local>

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-fm350
	SECTION:=luci
	CATEGORY:=LuCI
	TITLE:=FM350-GL management (watchdog + LuCI UI)
	# kmod-usb-* 依赖不在此声明：会触发 SDK 编译内核模块（爆盘）；
	# 安装期由离线包 dist/deps-ipk/ 或 dist/deps-apk/ 里的同 ABI 包满足
	DEPENDS:=+luci-base +rpcd +jq +sms-tool
	PKGARCH:=all
endef

define Package/luci-app-fm350/description
	FM350-GL (Fibocom) 5G modem manager: dial lifecycle, graded
	recovery (random drop / RNDIS freeze / IPv6 stale), hotplug-free
	module auto-discovery and LuCI2 web UI.
endef

define Package/luci-app-fm350/conffiles
/etc/config/fm350
endef

define Build/Prepare
endef

define Build/Compile
endef

define Package/luci-app-fm350/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/fm350mgr $(1)/etc/init.d/fm350mgr

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./files/etc/config/fm350 $(1)/etc/config/fm350

	$(INSTALL_DIR) $(1)/usr/lib/fm350/lib
	$(INSTALL_BIN) ./files/usr/lib/fm350/fm350.sh $(1)/usr/lib/fm350/fm350.sh
	$(INSTALL_BIN) ./files/usr/lib/fm350/fibocom.sh $(1)/usr/lib/fm350/fibocom.sh
	$(INSTALL_BIN) ./files/usr/lib/fm350/lib/config.sh $(1)/usr/lib/fm350/lib/config.sh
	$(INSTALL_BIN) ./files/usr/lib/fm350/lib/util.sh $(1)/usr/lib/fm350/lib/util.sh
	$(INSTALL_BIN) ./files/usr/lib/fm350/lib/at.sh $(1)/usr/lib/fm350/lib/at.sh
	$(INSTALL_BIN) ./files/usr/lib/fm350/lib/discover.sh $(1)/usr/lib/fm350/lib/discover.sh
	$(INSTALL_BIN) ./files/usr/lib/fm350/lib/probe.sh $(1)/usr/lib/fm350/lib/probe.sh
	$(INSTALL_BIN) ./files/usr/lib/fm350/lib/dial.sh $(1)/usr/lib/fm350/lib/dial.sh
	$(INSTALL_BIN) ./files/usr/lib/fm350/lib/recover.sh $(1)/usr/lib/fm350/lib/recover.sh

	$(INSTALL_DIR) $(1)/usr/share/fm350
	$(INSTALL_DATA) ./files/etc/config/fm350 $(1)/usr/share/fm350/config.template

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-fm350.json $(1)/usr/share/luci/menu.d/luci-app-fm350.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_BIN) ./files/usr/share/rpcd/ucode/fm350 $(1)/usr/share/rpcd/ucode/fm350

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-fm350.json $(1)/usr/share/rpcd/acl.d/luci-app-fm350.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/fm350
	$(INSTALL_DATA) ./files/www/luci-static/resources/fm350/common.js $(1)/www/luci-static/resources/fm350/common.js

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/fm350
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/fm350/*.js $(1)/www/luci-static/resources/view/fm350/
endef

$(eval $(call BuildPackage,luci-app-fm350))

# luci-app-uptime-kuma -- LuCI shell for the uptime-kuma service.
#
# Pure text package: no compilation, no upstream download. The payload is the
# view script, the menu/ACL JSON, the uci-defaults firewall hook, the backup
# helper and the compiled zh-cn catalog; the ipk is assembled from this
# directory and packed with the vendored opkg-build.

PKG_NAME        := luci-app-uptime-kuma
PKG_VERSION     := 1.0.3
PKG_ARCH        := all

PKG_ROOT        := $(CURDIR)/build/root
PKG_IPK_DIR     := $(CURDIR)/build/ipk
DIST_DIR        := $(CURDIR)/../dist
IPK             := $(DIST_DIR)/$(PKG_NAME)_$(PKG_VERSION)_$(PKG_ARCH).ipk
OPKG_BUILD      := $(CURDIR)/../scripts/opkg-build

CONTROL_FILES   := files/control files/postinst files/prerm

# Fixed timestamp for every archive member, so two builds of an unchanged
# tree are byte-identical.
export SOURCE_DATE_EPOCH := 1795219200

# Files that go into the ipk, relative to this directory. Explicit rather
# than a wildcard so a stray editor backup or build artifact cannot silently
# end up on the device. `htdocs/` is LuCI's source-side name for the web root;
# luci.mk installs its content into /www, and so do we.
PAYLOAD := \
	htdocs/luci-static/resources/view/uptime-kuma/overview.js \
	root/etc/uci-defaults/90_luci-app-uptime-kuma \
	root/usr/lib/lua/luci/i18n/luci-app-uptime-kuma.zh-cn.lmo \
	root/usr/lib/lua/luci/controller/uptimekuma.lua \
	root/usr/lib/lua/luci/view/uptime-kuma/overview.htm \
	root/usr/libexec/luci-app-uptime-kuma/backup \
	root/usr/libexec/luci-app-uptime-kuma/sync-firewall \
	root/usr/share/luci/menu.d/luci-app-uptime-kuma.json \
	root/usr/share/rpcd/acl.d/luci-app-uptime-kuma.json

.PHONY: all verify po clean distclean

all: $(IPK)

# The .lmo is committed (the device must not need python); regenerate it from
# the .po only when translating. `make po` rewrites it in place.
po:
	python3 tools/po2lmo.py po/zh-cn/$(PKG_NAME).zh-cn.po \
		root/usr/lib/lua/luci/i18n/$(PKG_NAME).zh-cn.lmo

$(IPK): $(addprefix $(CURDIR)/,$(PAYLOAD)) $(CONTROL_FILES)
	rm -rf $(PKG_ROOT) $(PKG_IPK_DIR)
	mkdir -p $(PKG_ROOT) $(PKG_IPK_DIR)/CONTROL $(DIST_DIR)
	cd $(CURDIR) && cp -a --parents $(PAYLOAD) $(PKG_ROOT)/
	mv $(PKG_ROOT)/root/* $(PKG_ROOT)/ && rmdir $(PKG_ROOT)/root
	mv $(PKG_ROOT)/htdocs $(PKG_ROOT)/www
	find $(PKG_ROOT) -type f -exec chmod 0644 {} +
	chmod 0755 $(PKG_ROOT)/etc/uci-defaults/90_luci-app-uptime-kuma
	chmod 0755 $(PKG_ROOT)/usr/libexec/luci-app-uptime-kuma/backup
	chmod 0755 $(PKG_ROOT)/usr/libexec/luci-app-uptime-kuma/sync-firewall
	cp -a $(PKG_ROOT)/. $(PKG_IPK_DIR)/
	sed -e 's|@VERSION@|$(PKG_VERSION)|g' files/control > $(PKG_IPK_DIR)/CONTROL/control
	cp files/postinst files/prerm $(PKG_IPK_DIR)/CONTROL/
	chmod 0644 $(PKG_IPK_DIR)/CONTROL/control
	chmod 0755 $(PKG_IPK_DIR)/CONTROL/postinst $(PKG_IPK_DIR)/CONTROL/prerm
	# `-c` = gzip-tar outer container; the device opkg cannot read `ar` ipks.
	$(OPKG_BUILD) -c -o root -g root $(PKG_IPK_DIR) $(DIST_DIR)
	@echo "==> $(IPK)"

verify: $(IPK)
	./verify.sh $(IPK)

clean:
	rm -rf $(CURDIR)/build

distclean: clean
	rm -f $(IPK)

# uptime-kuma -- Uptime Kuma 2.5.12 for OpenWrt 21.02
# (aarch64_cortex-a53, musl 1.1.24).
#
# node_modules is installed inside an arm64/musl container and shipped in the
# package; the device never downloads anything.  The frontend is the official
# prebuilt dist tarball, not a local vite build.
#
# The runtime is the node20 package.  @louislam/sqlite3 is the upstream
# napi-v6-linux-arm64-musl prebuild (never a source build); it needs
# libstdc++.so.6, which is taken from Alpine 3.12 (musl 1.1.24, the same libc
# as the device) and bundled under /opt/uptime-kuma/lib.

PKG_NAME        := uptime-kuma
PKG_VERSION     := 2.5.12
PKG_RELEASE     := 1
PKG_ARCH        := aarch64_cortex-a53

PKG_SOURCE      := uptime-kuma-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL  := https://codeload.github.com/louislam/uptime-kuma/tar.gz/refs/tags/$(PKG_VERSION)
PKG_SOURCE_HASH := 48f32d9651081f35cd69c84bf7cf26e131a5d9b9b1549b9f84980d67e67acb5e

DIST_SOURCE      := dist-$(PKG_VERSION).tar.gz
DIST_SOURCE_URL  := https://github.com/louislam/uptime-kuma/releases/download/$(PKG_VERSION)/dist.tar.gz
DIST_SOURCE_HASH := 8524bfbf0140de84fe14a5f3946bb322beaf7070aa51f36ebd568db1b9758472

# The addon the sqlite3 install script must fetch.  If node-pre-gyp falls
# back to a source build this file is different and the build fails.
SQLITE_BINDING       := node_modules/@louislam/sqlite3/lib/binding/napi-v6-linux-arm64/node_sqlite3.node
SQLITE_BINDING_HASH  := d14ab9d2a8611fc086c2c14ad9704592db499cab84b1dddb31df89240f6f493c

LIBSTDCXX_HASH := fd9f4683f979345e58253b3d21e82c1f9af27996269c07404ed74fa2b0566d06

# Pinned build images.  node:20-alpine is the arm64/musl build environment;
# alpine:3.12 supplies libstdc++.so.6 built against musl 1.1.24.
NODE_IMAGE   := node:20-alpine@sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293
ALPINE_IMAGE := alpine:3.12

export SOURCE_DATE_EPOCH := 1794928440

PKG_ROOT    := $(CURDIR)/build/root
PKG_IPK_DIR := $(CURDIR)/build/ipk
BUILD_DIR   := $(CURDIR)/build
DL_DIR      := $(BUILD_DIR)/dl
SRC_DIR     := $(BUILD_DIR)/src
ART_DIR     := $(BUILD_DIR)/art
DIST_DIR    := $(CURDIR)/../dist
IPK         := $(DIST_DIR)/$(PKG_NAME)_$(PKG_VERSION)-$(PKG_RELEASE)_$(PKG_ARCH).ipk
OPKG_BUILD  := $(CURDIR)/../scripts/opkg-build
BUILD_CTR   := uptime-kuma-build

STAMP_SOURCE  := $(BUILD_DIR)/.stamp-source
STAMP_RUNTIME := $(BUILD_DIR)/.stamp-runtime
STAMP_ROOT    := $(BUILD_DIR)/.stamp-root

.PHONY: all verify smoke clean distclean

all: $(IPK)

$(DL_DIR)/$(PKG_SOURCE):
	mkdir -p $(DL_DIR)
	curl -fL --retry 5 --retry-delay 3 -o $@.part $(PKG_SOURCE_URL)
	echo "$(PKG_SOURCE_HASH)  $@.part" | sha256sum -c -
	mv $@.part $@

$(DL_DIR)/$(DIST_SOURCE):
	mkdir -p $(DL_DIR)
	curl -fL --retry 5 --retry-delay 3 -o $@.part $(DIST_SOURCE_URL)
	echo "$(DIST_SOURCE_HASH)  $@.part" | sha256sum -c -
	mv $@.part $@

$(STAMP_SOURCE): $(DL_DIR)/$(PKG_SOURCE)
	rm -rf $(SRC_DIR) $(STAMP_SOURCE)
	mkdir -p $(SRC_DIR)
	tar -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(SRC_DIR) --strip-components=1
	chmod -R u=rwX,go=rX $(SRC_DIR)
	touch $@

$(BUILD_DIR)/dist/index.html: $(DL_DIR)/$(DIST_SOURCE)
	rm -rf $(BUILD_DIR)/dist
	tar -xzf $(DL_DIR)/$(DIST_SOURCE) -C $(BUILD_DIR)
	test -f $@
	touch $@

# libstdc++.so.6 comes from the same Alpine release as the smoke rootfs.
$(BUILD_DIR)/libstdc++.so.6:
	mkdir -p $(BUILD_DIR)
	for i in 1 2 3; do \
		docker run --rm --platform linux/arm64 $(ALPINE_IMAGE) \
			sh -c 'apk add --no-cache libstdc++ >/dev/null && cat /usr/lib/libstdc++.so.6' \
			> $@.part && break; \
		sleep 5; \
	done
	echo "$(LIBSTDCXX_HASH)  $@.part" | sha256sum -c -
	mv $@.part $@

# npm ci runs under qemu-user inside the arm64 container.  Bind mounts are not
# usable in this runtime, so the tree goes in and out with docker cp.
$(STAMP_RUNTIME): $(STAMP_SOURCE)
	@set -eu; \
	rm -rf $(ART_DIR) $(STAMP_RUNTIME); \
	mkdir -p $(ART_DIR); \
	docker rm -f $(BUILD_CTR) >/dev/null 2>&1 || true; \
	trap 'docker rm -f $(BUILD_CTR) >/dev/null 2>&1 || true' EXIT INT TERM; \
	echo "==> creating arm64 build container"; \
	docker create --name $(BUILD_CTR) --platform linux/arm64 -w /src \
		-v $(PKG_NAME)-npm-cache:/root/.npm \
		$(NODE_IMAGE) sh -c 'sleep 7200' >/dev/null; \
	docker start $(BUILD_CTR) >/dev/null; \
	docker exec $(BUILD_CTR) mkdir -p /src; \
	docker cp $(SRC_DIR)/. $(BUILD_CTR):/src; \
	echo "==> npm ci --omit dev (arm64/musl)"; \
	docker exec \
		-e npm_config_fallback_to_build=false \
		-e npm_config_fetch_retries=10 \
		-e npm_config_fetch_retry_mintimeout=10000 \
		-e npm_config_fetch_retry_maxtimeout=180000 \
		-e npm_config_fetch_timeout=600000 \
		-e npm_config_maxsockets=4 \
		$(BUILD_CTR) sh -c 'cd /src && \
			rc=1; \
			for attempt in 1 2 3; do \
				rm -rf node_modules; \
				if npm ci --omit dev --no-audit --no-fund --prefer-offline; then \
					rc=0; break; \
				else \
					rc=$$?; \
					echo "npm ci attempt $$attempt failed ($$rc), retrying" >&2; \
					sleep 5; \
				fi; \
			done; \
			exit $$rc'; \
	echo "==> checking the sqlite3 addon is the upstream musl prebuild"; \
	docker exec $(BUILD_CTR) sh -c \
		'test -f $(SQLITE_BINDING) && test ! -d node_modules/@louislam/sqlite3/build-tmp-napi-v6'; \
	docker exec $(BUILD_CTR) sha256sum $(SQLITE_BINDING) | \
		awk '{print $$1}' | grep -qx '$(SQLITE_BINDING_HASH)'; \
	docker cp $(BUILD_CTR):/src/node_modules $(ART_DIR)/node_modules; \
	touch $(STAMP_RUNTIME)

$(STAMP_ROOT): $(STAMP_RUNTIME) $(BUILD_DIR)/dist/index.html $(BUILD_DIR)/libstdc++.so.6
	rm -rf $(PKG_ROOT) $(STAMP_ROOT)
	mkdir -p $(PKG_ROOT)/opt/uptime-kuma/src \
		$(PKG_ROOT)/opt/uptime-kuma/extra \
		$(PKG_ROOT)/opt/uptime-kuma/lib \
		$(PKG_ROOT)/etc/init.d $(PKG_ROOT)/etc/config
	cp -a $(SRC_DIR)/server $(PKG_ROOT)/opt/uptime-kuma/server
	cp -a $(SRC_DIR)/db $(PKG_ROOT)/opt/uptime-kuma/db
	cp -a $(BUILD_DIR)/dist $(PKG_ROOT)/opt/uptime-kuma/dist
	cp -a $(ART_DIR)/node_modules $(PKG_ROOT)/opt/uptime-kuma/node_modules
	cp $(SRC_DIR)/package.json $(PKG_ROOT)/opt/uptime-kuma/package.json
	cp $(SRC_DIR)/src/util.js $(PKG_ROOT)/opt/uptime-kuma/src/util.js
	cp $(SRC_DIR)/extra/rdap-dns.json $(PKG_ROOT)/opt/uptime-kuma/extra/rdap-dns.json
	cp $(BUILD_DIR)/libstdc++.so.6 $(PKG_ROOT)/opt/uptime-kuma/lib/libstdc++.so.6
	# db/kuma.db is NOT a developer database: it is the empty SQLite template
	# that server/database.js copies to DATA_DIR on first setup
	# (`Database.templatePath = "./db/kuma.db"`).  Deleting it makes the service
	# crash on `copyfile ENOENT` right after the setup form is submitted.
	test -f $(PKG_ROOT)/opt/uptime-kuma/db/kuma.db
	head -c 15 $(PKG_ROOT)/opt/uptime-kuma/db/kuma.db | grep -q 'SQLite format 3' \
		|| { echo "db/kuma.db is not a SQLite database" >&2; exit 1; }
	install -m 0644 files/uptime-kuma.config $(PKG_ROOT)/etc/config/uptime-kuma
	install -m 0755 files/uptime-kuma.init $(PKG_ROOT)/etc/init.d/uptime-kuma
	# A non-git install cannot self-update: never run the update checker.
	grep -q 'if ((await setting("checkUpdate")) === false) {' \
		$(PKG_ROOT)/opt/uptime-kuma/server/check-version.js
	sed -i 's|if ((await setting("checkUpdate")) === false) {|if (true) { // checkUpdate disabled: non-git install|' \
		$(PKG_ROOT)/opt/uptime-kuma/server/check-version.js
	grep -q 'checkUpdate disabled: non-git install' \
		$(PKG_ROOT)/opt/uptime-kuma/server/check-version.js
	# Also hide the update controls in the UI: a non-git install cannot update.
	grep -q 'const data = await getSettings("general");' \
		$(PKG_ROOT)/opt/uptime-kuma/server/server.js
	sed -i 's|const data = await getSettings("general");|const data = await getSettings("general"); data.checkUpdate = false; // OpenWrt: non-git install|' \
		$(PKG_ROOT)/opt/uptime-kuma/server/server.js
	grep -q 'data.checkUpdate = false; // OpenWrt: non-git install' \
		$(PKG_ROOT)/opt/uptime-kuma/server/server.js
	# Trim rounds 1-2 (*.md, *.map).  *.d.ts/tests are kept: measured rounds
	# 3-4 put the tree at 168/163 MB, below the 180-220 MB budget.
	find $(PKG_ROOT)/opt/uptime-kuma -type f -name '*.md' -delete
	find $(PKG_ROOT)/opt/uptime-kuma -type f -name '*.map' -delete
	chmod -R u=rwX,go=rX $(PKG_ROOT)
	touch $(STAMP_ROOT)

$(IPK): $(STAMP_ROOT)
	rm -rf $(PKG_IPK_DIR)
	mkdir -p $(PKG_IPK_DIR)/CONTROL $(DIST_DIR)
	cp -a $(PKG_ROOT)/. $(PKG_IPK_DIR)/
	size=$$(du -sk $(PKG_ROOT) | cut -f1); \
	sed -e 's|@VERSION@|$(PKG_VERSION)-$(PKG_RELEASE)|g' \
	    -e 's|@ARCH@|$(PKG_ARCH)|g' \
	    -e "s|@SIZE@|$$size|g" \
	    files/control > $(PKG_IPK_DIR)/CONTROL/control
	chmod 0644 $(PKG_IPK_DIR)/CONTROL/control
	# Conffiles live in CONTROL/conffiles, the OpenWrt way.  A `Conffiles:`
	# field inside `control` is rejected by opkg 0.4 ("Failed to parse
	# Conffiles line"), which is the opkg this device runs.
	printf '%s\n' /etc/config/uptime-kuma > $(PKG_IPK_DIR)/CONTROL/conffiles
	chmod 0644 $(PKG_IPK_DIR)/CONTROL/conffiles
	# Uninstall hygiene: stop the daemon and drop the procd autostart link
	# before the payload is removed.
	install -m 0755 files/prerm $(PKG_IPK_DIR)/CONTROL/prerm
	install -m 0755 files/postinst $(PKG_IPK_DIR)/CONTROL/postinst
	# `-c` = gzip-tar outer container; the device opkg cannot read `ar` ipks.
	$(OPKG_BUILD) -c -o root -g root $(PKG_IPK_DIR) $(DIST_DIR)
	@echo "==> $(IPK)"

verify: $(IPK)
	./verify.sh $(IPK)

smoke: $(IPK)
	./smoke.sh $(IPK)

clean:
	docker rm -f $(BUILD_CTR) >/dev/null 2>&1 || true
	rm -rf $(CURDIR)/build

distclean: clean
	rm -f $(IPK)

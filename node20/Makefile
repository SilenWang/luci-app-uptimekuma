# node20 -- Node.js 20.20.2 for OpenWrt 21.02 (aarch64_cortex-a53, musl).
#
# Prebuilt artifact, no compilation: the official linux-arm64-musl tarball is
# downloaded, hash-checked, trimmed, and repacked as an ipk.

PKG_NAME        := node20
PKG_VERSION     := 20.20.2
PKG_ARCH        := aarch64_cortex-a53

PKG_SOURCE      := node-v$(PKG_VERSION)-linux-arm64-musl.tar.xz
PKG_SOURCE_URL  := https://unofficial-builds.nodejs.org/download/release/v$(PKG_VERSION)/$(PKG_SOURCE)
PKG_SOURCE_DIR  := node-v$(PKG_VERSION)-linux-arm64-musl
PKG_HASH        := 02d7c51f40f165e248c80d01fd26a80ab9dc726737d971edc94a65dc1c74d613

# Reproducible ipk: freeze the tar mtimes (opkg-build honours this) to the
# upstream tarball's own mtime, so two builds of the same inputs are
# byte-identical and the sha256 below stays meaningful.
export SOURCE_DATE_EPOCH := 1774487510

PKG_ROOT        := $(CURDIR)/build/node20-root
PKG_IPK_DIR     := $(CURDIR)/build/ipk
DL_DIR          := $(CURDIR)/build/dl
DIST_DIR        := $(CURDIR)/../dist
IPK             := $(DIST_DIR)/$(PKG_NAME)_$(PKG_VERSION)_$(PKG_ARCH).ipk
OPKG_BUILD      := $(CURDIR)/../scripts/opkg-build

.PHONY: all verify clean distclean

all: $(IPK)

$(DL_DIR)/$(PKG_SOURCE):
	mkdir -p $(DL_DIR)
	curl -fL --retry 3 --retry-delay 2 -o $@.part $(PKG_SOURCE_URL)
	echo "$(PKG_HASH)  $@.part" | sha256sum -c -
	mv $@.part $@

$(PKG_ROOT)/opt/node20/bin/node: | $(DL_DIR)/$(PKG_SOURCE)
	rm -rf $(PKG_ROOT) $(CURDIR)/build/extract
	mkdir -p $(PKG_ROOT)/opt $(CURDIR)/build/extract
	tar -xJf $(DL_DIR)/$(PKG_SOURCE) -C $(CURDIR)/build/extract
	mv $(CURDIR)/build/extract/$(PKG_SOURCE_DIR) $(PKG_ROOT)/opt/node20
	rm -rf $(CURDIR)/build/extract
	rm -rf $(PKG_ROOT)/opt/node20/include
	rm -rf $(PKG_ROOT)/opt/node20/lib/node_modules/npm
	rm -rf $(PKG_ROOT)/opt/node20/lib/node_modules/corepack
	rm -f $(PKG_ROOT)/opt/node20/bin/npm
	rm -f $(PKG_ROOT)/opt/node20/bin/npx
	rm -f $(PKG_ROOT)/opt/node20/bin/corepack
	chmod -R u=rwX,go=rX $(PKG_ROOT)

$(IPK): $(PKG_ROOT)/opt/node20/bin/node
	rm -rf $(PKG_IPK_DIR)
	mkdir -p $(PKG_IPK_DIR)/CONTROL $(DIST_DIR)
	cp -a $(PKG_ROOT)/. $(PKG_IPK_DIR)/
	sed -e 's|@VERSION@|$(PKG_VERSION)|g' \
	    -e 's|@ARCH@|$(PKG_ARCH)|g' \
	    files/control > $(PKG_IPK_DIR)/CONTROL/control
	chmod 0644 $(PKG_IPK_DIR)/CONTROL/control
	# `-c` = gzip-tar outer container.  The device's opkg (1bf042dd, 2021-06-13)
	# only understands that form: an `ar` ipk is rejected as "Malformed" (small
	# packages) or crashes it with SIGSEGV (large ones).
	$(OPKG_BUILD) -c -o root -g root $(PKG_IPK_DIR) $(DIST_DIR)
	@echo "==> $(IPK)"

verify: $(IPK)
	./verify.sh $(IPK)

clean:
	rm -rf $(CURDIR)/build

distclean: clean
	rm -f $(IPK)

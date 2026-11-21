# Top-level entry point: `pixi run build` == `make`.
#
# Every package lives in its own directory with a self-contained Makefile,
# so packages can also be built individually with `make -C node20`.

PACKAGES := node20 uptime-kuma

.PHONY: all $(PACKAGES) clean distclean verify

all: $(PACKAGES)

$(PACKAGES):
	$(MAKE) -C $@

clean:
	@for pkg in $(PACKAGES); do $(MAKE) -C $$pkg clean || exit 1; done

distclean:
	@for pkg in $(PACKAGES); do $(MAKE) -C $$pkg distclean || exit 1; done
	rm -rf dist

verify:
	@for pkg in $(PACKAGES); do $(MAKE) -C $$pkg verify || exit 1; done

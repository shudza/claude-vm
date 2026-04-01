PREFIX ?= /usr/local
BINDIR  = $(PREFIX)/bin
LIBDIR  = $(PREFIX)/lib/claude-vm

.PHONY: install uninstall

install:
	install -d $(DESTDIR)$(BINDIR)
	install -d $(DESTDIR)$(LIBDIR)
	install -m 755 claude-vm $(DESTDIR)$(BINDIR)/claude-vm
	install -m 644 lib/*.sh $(DESTDIR)$(LIBDIR)/
	@# Patch LIB_DIR to point to installed location
	sed -i 's|LIB_DIR="$$SCRIPT_DIR/lib"|LIB_DIR="$(LIBDIR)"|' $(DESTDIR)$(BINDIR)/claude-vm
	@echo "Installed to $(BINDIR)/claude-vm"

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/claude-vm
	rm -rf $(DESTDIR)$(LIBDIR)
	@echo "Uninstalled claude-vm"

.PHONY: test test-unit test-e2e test-checksum

test: test-unit test-e2e

test-unit:
	@for t in tests/test_*.sh; do \
		case "$$(basename $$t)" in test_e2e.sh|test_first_launch_timing.sh|test_image_checksum.sh) continue;; esac; \
		echo "--- $$t ---"; bash "$$t" || exit 1; \
	done

test-e2e:
	bash tests/test_e2e.sh

test-checksum:
	bash tests/test_image_checksum.sh

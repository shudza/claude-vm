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

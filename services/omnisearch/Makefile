CC      := cc
UNAME_S := $(shell uname -s)
PKG_CONFIG ?= pkg-config
PKG_DEPS   := libxml-2.0 libcurl openssl

GIT_HASH  := $(shell git rev-parse --short HEAD)
GIT_DATE  := $(shell git log -1 --format='%ad' --date='format:%y.%m.%d')
GIT_BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
GIT_REMOTE := $(shell git remote get-url origin)

VERSION := $(GIT_DATE)+$(GIT_HASH)_$(GIT_BRANCH)

CFLAGS  := -Wall -Wextra -O2 -Isrc -DVERSION='"$(VERSION)"' -DGIT_REMOTE='"$(GIT_REMOTE)"'

ifeq ($(UNAME_S),Darwin)
DEP_CFLAGS := $(shell $(PKG_CONFIG) --cflags $(PKG_DEPS) 2>/dev/null)
DEP_LIBS   := $(shell $(PKG_CONFIG) --libs $(PKG_DEPS) 2>/dev/null)
CFLAGS  += $(DEP_CFLAGS)
LIBS    := -lbeaker $(DEP_LIBS) -lpthread -lm
else
CFLAGS  += -I/usr/include/libxml2
LIBS    := -lbeaker -lcurl -lxml2 -lpthread -lm -lssl -lcrypto
endif

LDFLAGS :=

SRC_DIR := src
BIN_DIR := bin
OBJ_DIR := obj

SRCS := $(shell find $(SRC_DIR) -name '*.c')
OBJS := $(SRCS:$(SRC_DIR)/%.c=$(OBJ_DIR)/%.o)

TARGET := $(BIN_DIR)/omnisearch

all: $(TARGET)

$(TARGET): $(OBJS)
	@mkdir -p $(BIN_DIR)
	$(CC) $(OBJS) -o $@ $(LDFLAGS) $(LIBS)
	@echo "Build complete: $(TARGET)"

$(OBJ_DIR)/%.o: $(SRC_DIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@
	@echo "Compiled: $<"

run: $(TARGET)
	./$(TARGET)

clean:
	rm -rf $(OBJ_DIR) $(BIN_DIR)
	@echo "Cleaned build artifacts"

rebuild: clean all

info:
	@echo "Compiler:    $(CC)"
	@echo "CFlags:      $(CFLAGS)"
	@echo ""
	@echo "Sources to compile:"
	@echo "$(SRCS)" | tr ' ' '\n'
	@echo ""
	@echo "Object files to generate:"
	@echo "$(OBJS)" | tr ' ' '\n'

ifeq ($(UNAME_S),Darwin)
PREFIX      ?= /usr/local
DATA_DIR    ?= $(PREFIX)/etc/omnisearch
CONF_DIR    ?= $(DATA_DIR)
VAR_DIR     ?= $(PREFIX)/var/lib/omnisearch
LOG_DIR     ?= $(PREFIX)/var/log/omnisearch
CACHE_DIR   ?= $(PREFIX)/var/cache/omnisearch
else
PREFIX      ?= /usr
DATA_DIR    ?= /etc/omnisearch
CONF_DIR    ?= /etc/omnisearch
VAR_DIR     ?= /var/lib/omnisearch
LOG_DIR     ?= /var/log/omnisearch
CACHE_DIR   ?= /var/cache/omnisearch
endif

INSTALL_BIN_DIR := $(PREFIX)/bin
USER        := omnisearch
GROUP       := omnisearch

SYSTEMD_DIR := /etc/systemd/system
RUNIT_DIR ?= $(error Please set RUNIT_DIR to your services directory)
OPENRC_DIR  := /etc/init.d
DINIT_DIR   := /etc/dinit.d
LAUNCHD_DIR ?= /Library/LaunchDaemons
LAUNCHD_LABEL ?= monster.bwaaa.omnisearch
LAUNCHD_PLIST := $(LAUNCHD_DIR)/$(LAUNCHD_LABEL).plist

install:
	@echo "Available install targets:"
	@echo "  make install-systemd"
	@echo "  make install-openrc"
	@echo "  make install-runit"
	@echo "  make install-s6"
	@echo "  make install-dinit"
	@if [ "$(UNAME_S)" = "Darwin" ]; then echo "  make install-launchd"; fi
	@echo ""
	@echo "Example: doas/sudo make install-openrc"

install-launchd: $(TARGET)
	@mkdir -p $(DATA_DIR)/templates $(DATA_DIR)/static $(DATA_DIR)/locales $(INSTALL_BIN_DIR) $(LOG_DIR)
	@cp -rf templates/* $(DATA_DIR)/templates/
	@cp -rf static/* $(DATA_DIR)/static/
	@cp -rf locales/* $(DATA_DIR)/locales/
	@cp -n example-config.ini $(DATA_DIR)/config.ini || true
	install -m 755 $(TARGET) $(INSTALL_BIN_DIR)/omnisearch
	@mkdir -p $(LAUNCHD_DIR)
	@sed \
		-e 's|@INSTALL_BIN_DIR@|$(INSTALL_BIN_DIR)|g' \
		-e 's|@DATA_DIR@|$(DATA_DIR)|g' \
		-e 's|@LOG_DIR@|$(LOG_DIR)|g' \
		-e 's|@LAUNCHD_LABEL@|$(LAUNCHD_LABEL)|g' \
		init/launchd/omnisearch.plist.in > $(LAUNCHD_PLIST)
	@chmod 644 $(LAUNCHD_PLIST)
	@echo ""
	@echo "Config: $(DATA_DIR)/config.ini"
	@echo "Installed launchd plist to $(LAUNCHD_PLIST)"
	@echo "Load with: sudo launchctl bootstrap system $(LAUNCHD_PLIST)"
	@echo "Enable with: sudo launchctl enable system/$(LAUNCHD_LABEL)"
	@echo "Start with: sudo launchctl kickstart -k system/$(LAUNCHD_LABEL)"

install-systemd: $(TARGET)
	@mkdir -p $(DATA_DIR)/templates $(DATA_DIR)/static $(DATA_DIR)/locales $(LOG_DIR) $(CACHE_DIR)
	@cp -rf templates/* $(DATA_DIR)/templates/
	@cp -rf static/* $(DATA_DIR)/static/
	@cp -rf locales/* $(DATA_DIR)/locales/
	@cp -n example-config.ini $(DATA_DIR)/config.ini || true
	install -m 755 $(TARGET) $(INSTALL_BIN_DIR)/omnisearch
	@echo "Setting up user '$(USER)'..."
	@(grep -q '^$(GROUP):' /etc/group || groupadd $(GROUP)) 2>/dev/null || true
	@id -u $(USER) >/dev/null 2>&1 || useradd --system --home $(DATA_DIR) --shell /usr/sbin/nologin -g $(GROUP) $(USER)
	@chown -R $(USER):$(GROUP) $(LOG_DIR) $(CACHE_DIR) $(VAR_DIR) $(DATA_DIR) 2>/dev/null || true
	@chown $(USER):$(GROUP) $(DATA_DIR)/config.ini 2>/dev/null || true
	install -m 644 init/systemd/omnisearch.service $(SYSTEMD_DIR)/omnisearch.service
	@echo ""
	@echo "Config: $(DATA_DIR)/config.ini"
	@echo "Edit config with: nano $(DATA_DIR)/config.ini"
	@echo "Installed systemd service to $(SYSTEMD_DIR)/omnisearch.service"
	@echo "Run 'systemctl enable --now omnisearch' to start"

install-openrc: $(TARGET)
	@mkdir -p $(DATA_DIR)/templates $(DATA_DIR)/static $(DATA_DIR)/locales $(LOG_DIR) $(CACHE_DIR)
	@cp -rf templates/* $(DATA_DIR)/templates/
	@cp -rf static/* $(DATA_DIR)/static/
	@cp -rf locales/* $(DATA_DIR)/locales/
	@cp -n example-config.ini $(DATA_DIR)/config.ini || true
	install -m 755 $(TARGET) $(INSTALL_BIN_DIR)/omnisearch
	@echo "Setting up user '$(USER)'..."
	@(grep -q '^$(GROUP):' /etc/group || groupadd $(GROUP)) 2>/dev/null || true
	@id -u $(USER) >/dev/null 2>&1 || useradd --system --home $(DATA_DIR) --shell /usr/sbin/nologin -g $(GROUP) $(USER)
	@chown -R $(USER):$(GROUP) $(LOG_DIR) $(CACHE_DIR) $(VAR_DIR) $(DATA_DIR) 2>/dev/null || true
	@chown $(USER):$(GROUP) $(DATA_DIR)/config.ini 2>/dev/null || true
	install -m 755 init/openrc/omnisearch $(OPENRC_DIR)/omnisearch
	@echo ""
	@echo "Config: $(DATA_DIR)/config.ini"
	@echo "Edit config with: nano $(DATA_DIR)/config.ini"
	@echo "Installed openrc service to $(OPENRC_DIR)/omnisearch"
	@echo "Run 'rc-update add omnisearch default' to enable"

install-runit: $(TARGET)
	@mkdir -p $(DATA_DIR)/templates $(DATA_DIR)/static $(DATA_DIR)/locales $(LOG_DIR) $(CACHE_DIR) $(RUNIT_DIR)/omnisearch/log/
	@cp -rf templates/* $(DATA_DIR)/templates/
	@cp -rf static/* $(DATA_DIR)/static/
	@cp -rf locales/* $(DATA_DIR)/locales/
	@cp -n example-config.ini $(DATA_DIR)/config.ini || true
	install -m 755 $(TARGET) $(INSTALL_BIN_DIR)/omnisearch
	@echo "Setting up user '$(USER)'..."
	@(grep -q '^$(GROUP):' /etc/group || groupadd $(GROUP)) 2>/dev/null || true
	@id -u $(USER) >/dev/null 2>&1 || useradd --system --home $(DATA_DIR) --shell /usr/sbin/nologin -g $(GROUP) $(USER)
	@chown -R $(USER):$(GROUP) $(LOG_DIR) $(CACHE_DIR) $(VAR_DIR) $(DATA_DIR) 2>/dev/null || true
	@chown $(USER):$(GROUP) $(DATA_DIR)/config.ini 2>/dev/null || true
	install -m 755 init/runit/run $(RUNIT_DIR)/omnisearch/run
	install -m 755 init/runit/log/run $(RUNIT_DIR)/omnisearch/log/run
	@echo ""
	@echo "Config: $(DATA_DIR)/config.ini"
	@echo "Edit config with: nano $(DATA_DIR)/config.ini"
	@echo "Installed runit service to $(RUNIT_DIR)/omnisearch"
	@echo "You need to start the service manually"
	@echo "Void: ln -s $(RUNIT_DIR)/omnisearch/ /var/service/"
	@echo "Artix: ln -s $(RUNIT_DIR)/omnisearch/ /run/runit/"

install-s6: $(TARGET)
	@mkdir -p $(DATA_DIR)/templates $(DATA_DIR)/static $(DATA_DIR)/locales $(LOG_DIR) $(CACHE_DIR)
	@cp -rf templates/* $(DATA_DIR)/templates/
	@cp -rf static/* $(DATA_DIR)/static/
	@cp -rf locales/* $(DATA_DIR)/locales/
	@cp -n example-config.ini $(DATA_DIR)/config.ini || true
	install -m 755 $(TARGET) $(INSTALL_BIN_DIR)/omnisearch
	@echo "Setting up user '$(USER)'..."
	@(grep -q '^$(GROUP):' /etc/group || groupadd $(GROUP)) 2>/dev/null || true
	@id -u $(USER) >/dev/null 2>&1 || useradd --system --home $(DATA_DIR) --shell /usr/sbin/nologin -g $(GROUP) $(USER)
	@chown -R $(USER):$(GROUP) $(LOG_DIR) $(CACHE_DIR) $(VAR_DIR) $(DATA_DIR) 2>/dev/null || true
	@chown $(USER):$(GROUP) $(DATA_DIR)/config.ini 2>/dev/null || true
	@mkdir -p /var/service/omnisearch/log/supervise/control
	install -m 755 init/s6/run /var/service/omnisearch/run
	install -m 755 init/s6/log/run /var/service/omnisearch/log/run
	install -m 755 init/s6/log/run /var/service/omnisearch/log/supervise/control
	@echo ""
	@echo "Config: $(DATA_DIR)/config.ini"
	@echo "Edit config with: nano $(DATA_DIR)/config.ini"
	@echo "Installed s6 service to /var/service/omnisearch"
	@echo "Service will start automatically"

install-dinit: $(TARGET)
	@mkdir -p $(DATA_DIR)/templates $(DATA_DIR)/static $(DATA_DIR)/locales $(LOG_DIR) $(CACHE_DIR)
	@cp -rf templates/* $(DATA_DIR)/templates/
	@cp -rf static/* $(DATA_DIR)/static/
	@cp -rf locales/* $(DATA_DIR)/locales/
	@cp -n example-config.ini $(DATA_DIR)/config.ini || true
	install -m 755 $(TARGET) $(INSTALL_BIN_DIR)/omnisearch
	@echo "Setting up user '$(USER)'..."
	@(grep -q '^$(GROUP):' /etc/group || groupadd $(GROUP)) 2>/dev/null || true
	@id -u $(USER) >/dev/null 2>&1 || useradd --system --home $(DATA_DIR) --shell /usr/sbin/nologin -g $(GROUP) $(USER)
	@chown -R $(USER):$(GROUP) $(LOG_DIR) $(CACHE_DIR) $(VAR_DIR) $(DATA_DIR) 2>/dev/null || true
	@chown $(USER):$(GROUP) $(DATA_DIR)/config.ini 2>/dev/null || true
	install -m 644 init/dinit/omnisearch $(DINIT_DIR)/omnisearch
	@echo ""
	@echo "Config: $(DATA_DIR)/config.ini"
	@echo "Edit config with: nano $(DATA_DIR)/config.ini"
	@echo "Installed dinit service to $(DINIT_DIR)/omnisearch"
	@echo "Run 'dinitctl enable omnisearch' to start"

uninstall:
	rm -f $(INSTALL_BIN_DIR)/omnisearch
	rm -rf $(DATA_DIR)
	rm -f $(SYSTEMD_DIR)/omnisearch.service
	rm -f $(OPENRC_DIR)/omnisearch
	rm -f $(DINIT_DIR)/omnisearch
	rm -rf /etc/service/omnisearch
	rm -rf /var/service/omnisearch
	@echo "You might need to unlink omnisearch if you're using runit"
	@id -u $(USER) >/dev/null 2>&1 && userdel $(USER) 2>/dev/null || true
	@grep -q '^$(GROUP):' /etc/group 2>/dev/null && groupdel $(GROUP) 2>/dev/null || true
	@echo "Uninstalled omnisearch"

.PHONY: all run clean rebuild info install install-launchd install-systemd install-openrc install-runit install-s6 install-dinit uninstall

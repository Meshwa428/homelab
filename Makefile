# =============================================================================
# Makefile — Homelab Service Manager
# =============================================================================
# Services are auto-discovered from compose.yml files.
# Dependencies and boot order are handled entirely by manage.sh + services.dep.
# You never need to edit this file when adding a new service.
# =============================================================================

SHELL := /bin/bash

# Auto-discover all services by finding compose.yml files.
# Errors (permission denied on root-owned dirs) are suppressed.
SERVICES := $(shell find . -not -path "*/.git/*" -type d \
              \( -exec test -f "{}/compose.yml" \; -print -prune \) \
              2>/dev/null \
              | xargs -I{} basename {} \
              | sort)

# Generate per-service targets for every discovered service
define service_targets
.PHONY: $(1) $(1)-down $(1)-restart $(1)-logs $(1)-pull $(1)-remove $(1)-delete

$(1):
	@./scripts/manage.sh up $(1)

$(1)-down:
	@./scripts/manage.sh down $(1)

$(1)-restart:
	@./scripts/manage.sh restart $(1)

$(1)-logs:
	@./scripts/manage.sh logs $(1) -f

$(1)-pull:
	@./scripts/manage.sh pull $(1)

$(1)-remove:
	@./scripts/manage.sh remove $(1)

$(1)-delete:
	@./scripts/manage.sh delete $(1)
endef

MANAGED_SERVICES := $(filter-out kiwix,$(SERVICES))
$(foreach svc,$(MANAGED_SERVICES),$(eval $(call service_targets,$(svc))))

# --- Kiwix -------------------------------------------------------------------
.PHONY: kiwix kiwix-down kiwix-restart kiwix-logs kiwix-pull-img kiwix-remove kiwix-delete kiwix-list kiwix-pull

kiwix:
	@./scripts/manage.sh up kiwix
kiwix-down:
	@./scripts/manage.sh down kiwix
kiwix-restart:
	@./scripts/manage.sh restart kiwix
kiwix-logs:
	@./scripts/manage.sh logs kiwix -f
kiwix-pull-img:
	@./scripts/manage.sh pull kiwix
kiwix-remove:
	@./scripts/manage.sh remove kiwix
kiwix-delete:
	@./scripts/manage.sh delete kiwix
kiwix-list:
	@./scripts/kiwix-pull.sh --list

# Usage: make kiwix-pull ARGS="devdocs freecodecamp --dry-run"
kiwix-pull:
	@./scripts/kiwix-pull.sh $(ARGS)

# --- Global commands ---------------------------------------------------------
.PHONY: up down heal status list help network

# Create the shared proxy network if it doesn't already exist
network:
	@docker network inspect proxy >/dev/null 2>&1 \
		&& echo "  proxy network already exists" \
		|| (docker network create proxy && echo "  proxy network created")

# Always ensure the proxy network exists before starting anything
up: network
	@./scripts/manage.sh up

down:
	@./scripts/manage.sh down

heal:
	@./scripts/manage.sh heal

status:
	@./scripts/manage.sh status

list:
	@./scripts/manage.sh list

help:
	@./scripts/manage.sh help

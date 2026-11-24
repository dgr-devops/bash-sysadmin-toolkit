# Makefile — instala el toolkit como enlaces simbólicos y lanza lint y tests.
#
#   make install                  # enlaces en ~/.local/bin
#   make install PREFIX=/usr/local  # enlaces en /usr/local/bin (necesita permisos)
#   make uninstall                # quita solo los enlaces que apuntan a este repositorio
#   make lint | make test | make check

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

PREFIX  ?= $(HOME)/.local
BINDIR  := $(DESTDIR)$(PREFIX)/bin
ROOT    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SCRIPTS := $(sort $(wildcard $(ROOT)/scripts/*.sh))

.DEFAULT_GOAL := help
.PHONY: help install uninstall lint test check

help: ## Muestra esta ayuda
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

install: ## Enlaza los scripts en $(PREFIX)/bin (sin la extensión .sh)
	@mkdir -p "$(BINDIR)"
	@for script in $(SCRIPTS); do \
	  name="$$(basename "$$script" .sh)"; \
	  ln -sfn "$$script" "$(BINDIR)/$$name"; \
	  echo "enlazado  $(BINDIR)/$$name -> $$script"; \
	done
	@case ":$$PATH:" in *":$(PREFIX)/bin:"*) ;; \
	  *) echo "aviso: $(PREFIX)/bin no está en tu PATH" ;; esac

uninstall: ## Quita los enlaces creados por install
	@for script in $(SCRIPTS); do \
	  name="$$(basename "$$script" .sh)"; \
	  link="$(BINDIR)/$$name"; \
	  if [[ -L "$$link" && "$$(readlink "$$link")" == "$$script" ]]; then \
	    rm -- "$$link"; echo "eliminado $$link"; \
	  elif [[ -e "$$link" || -L "$$link" ]]; then \
	    echo "omitido   $$link (no apunta a este repositorio)"; \
	  fi; \
	done

lint: ## Pasa shellcheck a scripts y librería
	shellcheck $(SCRIPTS) $(ROOT)/lib/common.sh

test: ## Ejecuta los tests con bats
	bats $(ROOT)/tests/

check: lint test ## lint + test

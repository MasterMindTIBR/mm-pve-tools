SHELL := /bin/bash

PERL_INC   = -Ilib -Iperl
PROVE      = prove $(PERL_INC)

JS_SRC     = js/src/core.js js/src/renumber.js js/src/restore.js js/src/branding.js js/src/ui.js js/src/updates.js
JS_OUT     = build/mm-tools.js

.PHONY: all js test test-api test-gateway test-gui lint build build-dir check-anchors clean

all: js

$(JS_OUT): $(JS_SRC) | build-dir
	@printf '/* mm-tools.js — gerado por "make js"; NÃO EDITAR */\n' > $@
	@for f in $(JS_SRC); do \
	    printf '\n/* ===== %s ===== */\n' "$$f" >> $@; cat "$$f" >> $@; \
	done
	@echo "gerado $@"

js: $(JS_OUT)

build-dir:
	mkdir -p build

test:
	$(PROVE) -r t/core t/renumber t/restore t/branding t/ui t/updates t/contract

test-api:
	./scripts/test-pve-env.sh

test-gateway:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s t/gateway -v

test-gui:
	t/gui/run.sh

lint:
	@rc=0; \
	while IFS= read -r f; do \
	    perl -Ilib -Iperl -It/lib-stubs -c "$$f" >/dev/null 2>&1 \
	      || { echo "perl -c FALHOU: $$f"; perl -Ilib -Iperl -It/lib-stubs -c "$$f"; rc=1; }; \
	done < <(find bin lib perl -type f ! -name '*.py' ! -name '*.pod' ! -path '*/t/*' | sort); \
	if command -v shellcheck >/dev/null 2>&1; then \
	    find . -path ./.git -prune -o -name '*.sh' -print0 | xargs -0 -r shellcheck || rc=1; \
	else echo "shellcheck ausente (CI roda)"; fi; \
	if command -v perlcritic >/dev/null 2>&1; then \
	    find lib perl -name '*.pm' | xargs perlcritic --gentle || rc=1; \
	else echo "perlcritic ausente (CI roda)"; fi; \
	if command -v node >/dev/null 2>&1; then \
	    node --check t/gui/browser.js || rc=1; \
	    node t/gui/browser-smoke.js || rc=1; \
	else echo "node ausente (lint GUI falhou)"; rc=1; fi; \
	exit $$rc

build:
	./scripts/build-deb.sh

# Valida as âncoras contra o fixture upstream: antes (espera 3=aplicável),
# aplica (espera 0), depois (espera 0=aplicado). 4=âncora quebrada=falha.
check-anchors: js
	@set -e; \
	fixture_root=$$(mktemp -d); \
	owned_newest=; \
	newest_root='$(NEWEST_PVE_ROOT)'; \
	cleanup() { rm -rf -- "$$fixture_root"; if [ -n "$$owned_newest" ]; then rm -rf -- "$$owned_newest"; fi; }; \
	trap cleanup EXIT HUP INT TERM; \
	mkdir -p "$$fixture_root/usr/share/pve-manager" "$$fixture_root/usr/share/perl5/PVE/API2"; \
	cp t/fixtures/pve-manager/index.html.tpl "$$fixture_root/usr/share/pve-manager/"; \
	cp t/fixtures/pve-manager/Nodes.pm "$$fixture_root/usr/share/perl5/PVE/API2/"; \
	rc=0; perl $(PERL_INC) lib/mm-pve-tools/apply-patches --check --root "$$fixture_root" >/dev/null || rc=$$?; \
	[ $$rc -eq 3 ] || { echo "esperava 3 (aplicável), veio $$rc"; exit 1; }; \
	perl $(PERL_INC) lib/mm-pve-tools/apply-patches --no-restart --root "$$fixture_root" >/dev/null; \
	rc=0; perl $(PERL_INC) lib/mm-pve-tools/apply-patches --check --root "$$fixture_root" >/dev/null || rc=$$?; \
	if [ $$rc -eq 0 ]; then echo "ÂNCORAS PVE MANAGER OK (aplicou e verificou no fixture upstream)"; \
	elif [ $$rc -eq 4 ]; then echo "ÂNCORA QUEBROU no upstream"; exit 1; \
	else exit 1; fi; \
	if [ -z "$$newest_root" ]; then \
		owned_newest=$$(mktemp -d); newest_root="$$owned_newest"; \
		scripts/fetch-pve-debs.sh "$$newest_root" pve-manager=latest proxmox-widget-toolkit=latest; \
	fi; \
	grep -Fq "MM.Ui" build/mm-tools.js; \
	grep -Fq "MM.panel.Updates" build/mm-tools.js; \
	grep -Fq "checked_command" build/mm-tools.js; \
	scripts/check-ui-bundles.sh refs/upstream/pve-9.2.24/pvemanagerlib.js refs/upstream/pve-9.2.24/proxmoxlib.js \
		"$$newest_root/x/pve-manager/usr/share/pve-manager/js/pvemanagerlib.js" \
		"$$newest_root/x/proxmox-widget-toolkit/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

clean:
	rm -rf build
	find . -name '*.pyc' -delete
	find . -name __pycache__ -type d -exec rm -rf {} +

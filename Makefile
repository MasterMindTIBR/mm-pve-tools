SHELL := /bin/bash

PERL_INC   = -Ilib -Iperl
PROVE      = prove $(PERL_INC)

JS_SRC     = js/src/core.js js/src/renumber.js js/src/restore.js js/src/branding.js js/src/ui.js js/src/poollimits.js js/src/updates.js
JS_OUT     = build/mm-tools.js
PVE_PACKAGE_VERSIONS = ci/pve-package-versions

pve_package_version = $(shell awk -F= -v package="$(1)" '$$1 == package { print $$2 }' $(PVE_PACKAGE_VERSIONS))

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
	$(PROVE) -r t/core t/renumber t/restore t/branding t/ui t/updates t/poollimits t/contract

test-api:
	./scripts/test-pve-env.sh

test-gateway:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s t/gateway -v

test-gui:
	t/gui/run.sh

lint:
	@rc=0; \
	while IFS= read -r f; do \
	    extra=''; case "$$f" in perl/PVE/MMTools/*) extra='-It/lib-autostub -MMMAutoStub';; esac; \
	    perl -Ilib -Iperl -It/lib-stubs $$extra -c "$$f" >/dev/null 2>&1 \
	      || { echo "perl -c FALHOU: $$f"; perl -Ilib -Iperl -It/lib-stubs $$extra -c "$$f"; rc=1; }; \
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

# Valida o fixture upstream e cada set da matriz de owners contra pacotes reais:
# apply, static module checks, module call checks, apply/revert e anchors da UI.
check-anchors: js
	@set -e; \
	fixture_root=$$(mktemp -d); \
	matrix='ci/pve-anchor-matrix'; roots=(); \
	cleanup() { rm -rf -- "$$fixture_root" "$${roots[@]}"; }; \
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
	grep -Fq "MM.Ui" build/mm-tools.js; \
	grep -Fq "MM.PoolLimits" build/mm-tools.js; \
	grep -Fq "MM.panel.Updates" build/mm-tools.js; \
	grep -Fq "checked_command" build/mm-tools.js; \
	pinned_root=$$(mktemp -d); roots+=("$$pinned_root"); \
	pinned_specs="pve-manager=$$(cat ci/pve-manager.version) $$(awk -F= '/^[a-z0-9]/{print $$1 "=" $$2}' ci/pve-package-versions | grep -E '^(libpve-guest-common-perl|libpve-access-control|libpve-storage-perl|qemu-server|pve-container|proxmox-widget-toolkit)=')"; \
	check_bundle() { \
		label=$$1; root=$$2; bundle="$$root/x"; combined=$$(mktemp -d); \
		if ! apply_out=$$(perl $(PERL_INC) lib/mm-pve-tools/apply-patches --json --no-restart --root "$$bundle/pve-manager" 2>&1); then \
			echo "ANCHOR SET=$$label target=__core__ reason=apply-patches command failed" >&2; echo "$$apply_out" >&2; return 1; fi; \
		if ! printf '%s' "$$apply_out" | perl -MJSON::PP -0777 -ne 'my $$d=decode_json($$_); for my $$id (keys %{$$d->{targets}||{}}) { my $$s=$$d->{targets}{$$id}{status}||""; die "$$id: $$s\n" unless $$s eq "applied" || $$s eq "version_current"; }'; then \
			echo "ANCHOR SET=$$label target=__core__ reason=apply-patches target failed" >&2; echo "$$apply_out" >&2; return 1; fi; \
		if ! perl -Ilib -Iperl -It/lib-stubs -It/lib-autostub -MMMAutoStub -c "$$bundle/pve-manager/usr/share/perl5/PVE/API2/Nodes.pm"; then \
			echo "ANCHOR SET=$$label target=nodes_pm reason=staged compile failed" >&2; return 1; fi; \
		if grep -R -q "Ext.define('PMX.image.LogoSVG'" "$$bundle/proxmox-widget-toolkit" \
			&& grep -R -q 'proxmox_logo.svg' "$$bundle/proxmox-widget-toolkit"; then :; \
		elif [ "$$label" = oldest ]; then \
			echo "ANCHOR SET=$$label target=branding_logo WARNING: no PMX.image.LogoSVG in this toolkit; the branding logo is not replaced on this version" >&2; \
		else echo "ANCHOR SET=$$label target=branding_logo reason=LogoSVG/logo asset anchor missing" >&2; return 1; fi; \
		for package in pve-manager libpve-guest-common-perl libpve-access-control libpve-storage-perl qemu-server pve-container; do cp -a "$$bundle/$$package/." "$$combined/"; done; \
		if ! MM_PVE_UPSTREAM_ROOT="$$bundle" $(PROVE) t/poollimits/02_patch_calls.t; then \
			echo "ANCHOR SET=$$label target=poollimits reason=02_patch_calls.t failed" >&2; return 1; fi; \
		if ! MM_PVE_ANCHOR_SET="$$label" PERL5LIB="$$PWD/lib:$$PWD/perl:$$PWD/t/lib-stubs:$$PWD/t/lib-autostub:$$combined/usr/share/perl5" perl -Ilib -Iperl -It/lib t/anchors/module-patches-check.pl "$$combined"; then \
			echo "ANCHOR SET=$$label target=poollimits reason=module staged compile/apply/revert failed" >&2; return 1; fi; \
		if ! scripts/check-ui-bundles.sh "$$bundle/pve-manager/usr/share/pve-manager/js/pvemanagerlib.js" "$$bundle/proxmox-widget-toolkit/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"; then \
			echo "ANCHOR SET=$$label target=ui_bundle reason=UI anchors failed" >&2; return 1; fi; \
		rm -rf -- "$$combined"; echo "ANCHOR SET=$$label OK"; \
	}; \
	if ! scripts/fetch-pve-debs.sh "$$pinned_root" $$pinned_specs; then echo 'ANCHOR SET=pinned target=packages reason=fetch failed' >&2; exit 1; fi; \
	check_bundle pinned "$$pinned_root"; \
	while read -r label specs; do \
		case "$$label" in ''|\#*) continue;; esac; \
		root=$$(mktemp -d); roots+=("$$root"); \
		if ! scripts/fetch-pve-debs.sh "$$root" $$specs; then echo "ANCHOR SET=$$label target=packages reason=fetch failed" >&2; exit 1; fi; \
		check_bundle "$$label" "$$root"; \
	done < "$$matrix"

clean:
	rm -rf build
	find . -name '*.pyc' -delete
	find . -name __pycache__ -type d -exec rm -rf {} +

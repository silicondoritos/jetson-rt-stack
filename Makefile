.PHONY: help all extract build bake flash clean distclean \
        docker-build docker-shell \
        doctor audit verify headers versions logs \
        ignite ignite-no-flash post-flash-validate \
        release flash-one flash-batch fleet-status fleet-init \
        clone-golden flash-golden list-goldens \
        menuconfig defconfig savedefconfig alldefconfig check-config \
        list-targets

# =============================================================================
# Jetson Orin NX AV Firmware   Build & Deploy Automation
# =============================================================================
# All Makefile targets are thin wrappers around scripts/. Run `make help`
# (default) for the menu, `make list-targets` for everything, `make versions`
# for the pin manifest.
# =============================================================================

# Default target prints help
.DEFAULT_GOAL := help

# Project root (the directory containing this Makefile)
REPO_ROOT := $(CURDIR)

# Docker invocation   auto-detect whether `docker` is callable as the user
# or needs sudo. Override with: make build DOCKER=podman
DOCKER ?= $(shell if docker ps >/dev/null 2>&1; then echo docker; else echo "sudo docker"; fi)

# =============================================================================
# Help / discovery
# =============================================================================

help:
	@echo "Jetson Orin NX AV Firmware   Make targets"
	@echo "------------------------------------------"
	@echo ""
	@echo "Configuration (run first)"
	@echo "  menuconfig        Interactive TUI   configure all build options"
	@echo "  defconfig         Apply committed defaults from ./defconfig"
	@echo "  savedefconfig     Write current .config back to ./defconfig (commit this)"
	@echo "  alldefconfig      Apply all Kconfig defaults non-interactively"
	@echo ""
	@echo "Discovery"
	@echo "  versions          Print pinned versions (L4T, CUDA, ZED, etc.)"
	@echo "  doctor            Preflight check: tarballs, vendor trees, host packages"
	@echo "  list-targets      Show all available targets"
	@echo ""
	@echo "Build pipeline (host)"
	@echo "  docker-build      Build the cross-compile container (one-time)"
	@echo "  docker-shell      Drop into the container interactively"
	@echo "  extract           Phase 1: extract L4T + apply all patches + plugin hooks"
	@echo "  build             Phase 2: cross-compile kernel + modules + headers .deb"
	@echo "  bake              Phase 3: stage payloads (SDKs, services, overlays) into rootfs"
	@echo "  audit             Run pre-flash audit gate (vermagic + RT + DTBO)"
	@echo "  flash             Phase 4: write to NVMe (Jetson must be in recovery mode)"
	@echo ""
	@echo "Composition"
	@echo "  all               extract → build → bake (no flash)"
	@echo "  ignite-no-flash   doctor → all → audit (full pipeline minus flashing)"
	@echo "  ignite            doctor → all → audit → flash → post-flash-validate"
	@echo ""
	@echo "Validation & support"
	@echo "  verify            Host-side post-flash check (SSH to Jetson, run gauntlet)"
	@echo "  post-flash-validate  Full validator (vermagic + hardware + venv + ZED SDK)"
	@echo "  headers           Just rebuild and stage the linux-headers .deb"
	@echo "  logs              Bundle all logs into support-bundle-*.tar.gz"
	@echo ""
	@echo "Fleet manufacturing (Phase 6)"
	@echo "  release VERSION=v1.0.0   Package built workspace into release-vX.Y.Z.tar.gz"
	@echo "  fleet-init               Create a starter fleet.csv from fleet.csv.example"
	@echo "  flash-one DEVICE=av-07  Flash one device with full pre/post verify"
	@echo "  flash-batch FLEET=fleet.csv   Loop over a fleet manifest, flash each"
	@echo "  fleet-status             Summarize fleet_log.csv (per-device PASS/FAIL)"
	@echo ""
	@echo "Golden image (clone & redeploy)"
	@echo "  clone-golden TAG=v1.0    Capture golden image from a Jetson in recovery mode"
	@echo "  flash-golden GOLDEN=NAME Flash a saved golden to a target Jetson"
	@echo "    DEVICE=av-07          (optional fleet label)"
	@echo "  list-goldens             Show every saved golden under golden-images/"
	@echo ""
	@echo "Cleaning"
	@echo "  clean             Remove latest_jetson/ workspace"
	@echo "  distclean         clean + remove Docker image + remove logs/manifests"

list-targets:
	@$(MAKE) -pRrq -f $(lastword $(MAKEFILE_LIST)) : 2>/dev/null \
	    | awk -v RS= -F: '/^# File/,/^# Finished Make data base/ { \
	        if ($$1 !~ "^[#.]") {print $$1}}' \
	    | sort -u | grep -v -E '^(Makefile|\.DEFAULT_GOAL)$$'

# =============================================================================
# Configuration (kconfiglib)
# =============================================================================
# Install: pip install kconfiglib
# Or:      sudo apt install python3-kconfiglib

KCONFIG_PY ?= python3 -m

menuconfig:
	@$(KCONFIG_PY) menuconfig Kconfig

defconfig:
	@$(KCONFIG_PY) defconfig --kconfig Kconfig defconfig
	@echo "[config] .config written from defconfig"

savedefconfig:
	@$(KCONFIG_PY) savedefconfig --kconfig Kconfig --out defconfig
	@echo "[config] defconfig updated   commit this file"

alldefconfig:
	@$(KCONFIG_PY) alldefconfig Kconfig
	@echo "[config] .config written with all-defaults"

check-config:
	@if [ ! -f "$(REPO_ROOT)/.config" ]; then \
	    echo ""; \
	    echo "[!] No .config found. Run one of:"; \
	    echo "    make defconfig      # apply committed defaults"; \
	    echo "    make menuconfig     # interactive configuration"; \
	    echo ""; \
	    exit 1; \
	fi

# =============================================================================
# Discovery
# =============================================================================

versions:
	@./scripts/show_versions.sh

doctor:
	@bash scripts/check_docs_consistency.sh
	@./scripts/00_doctor.sh

# =============================================================================
# Build pipeline (host commands)
# =============================================================================

extract:
	@./scripts/01_extract_and_patch.sh

build:
	@if [ -f /.dockerenv ]; then \
	    ./scripts/02_build_kernel.sh; \
	else \
	    echo "[*] Host detected. Launching The Forge (Docker)..."; \
	    $(DOCKER) run --rm \
	        -v $(REPO_ROOT):/home/j/dev/custom_kernel \
	        -w /home/j/dev/custom_kernel \
	        --user $$(id -u):$$(id -g) \
	        --env HOME=/home/j \
	        --env SOURCE_DATE_EPOCH=$$(git log -1 --format=%ct 2>/dev/null || date +%s) \
	        $(DOCKER_IMAGE_TAG_OVERRIDE) jetson-av-builder bash ./scripts/02_build_kernel.sh; \
	fi

bake:
	@./scripts/03_bake_rootfs.sh

audit:
	@./scripts/pre_flash_audit.sh

flash:
	@./scripts/04_flash_nvme.sh

all: extract build bake

# =============================================================================
# Just-the-headers target   useful when you change CONFIG_* slightly and only
# need to refresh the .deb without redoing modules_install.
# =============================================================================

headers:
	@if [ -f /.dockerenv ]; then \
	    cd latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src && \
	    make -j$$(nproc) bindeb-pkg LOCALVERSION=-tegra KDEB_PKGVERSION="1-tegra"; \
	else \
	    echo "[*] Routing through Docker..."; \
	    $(DOCKER) run --rm \
	        -v $(REPO_ROOT):/home/j/dev/custom_kernel \
	        -w /home/j/dev/custom_kernel \
	        --user $$(id -u):$$(id -g) \
	        --env HOME=/home/j \
	        jetson-av-builder bash -c \
	        'cd latest_jetson/Linux_for_Tegra/source/kernel/kernel-jammy-src && \
	         make -j$$(nproc) bindeb-pkg LOCALVERSION=-tegra KDEB_PKGVERSION="1-tegra"'; \
	fi

# =============================================================================
# Composition: end-to-end orchestration
# =============================================================================

# Full pipeline minus the destructive flash step. Useful for CI / PR builds.
ignite-no-flash: doctor all audit
	@echo ""
	@echo "==========================================="
	@echo "  IGNITE-NO-FLASH complete."
	@echo "  Image is built, baked, and audit-clean."
	@echo "  Run 'make flash' with Jetson in recovery mode."
	@echo "==========================================="

# Full end-to-end. Pauses for human confirmation before flashing.
ignite: doctor all audit
	@echo ""
	@echo "==========================================="
	@echo "  Build & audit OK. Ready to flash."
	@echo "  Put Jetson in FORCE RECOVERY MODE now."
	@echo "==========================================="
	@./scripts/04_flash_nvme.sh
	@echo ""
	@echo "[*] Waiting 90s for first boot to complete before validating..."
	@sleep 90
	@./scripts/05_post_flash_validate.sh

# =============================================================================
# Validation & support
# =============================================================================

verify: post-flash-validate

post-flash-validate:
	@./scripts/05_post_flash_validate.sh

logs:
	@./scripts/gather_logs.sh

# =============================================================================
# Docker management
# =============================================================================

docker-build:
	@$(DOCKER) build -t jetson-av-builder .

docker-shell:
	@$(DOCKER) run -it --rm \
	    -v $(REPO_ROOT):/home/j/dev/custom_kernel \
	    -w /home/j/dev/custom_kernel \
	    --user $$(id -u):$$(id -g) \
	    --env HOME=/home/j \
	    jetson-av-builder bash

# =============================================================================
# Cleaning
# =============================================================================

clean:
	@echo "[*] Removing latest_jetson/..."
	@sudo rm -rf latest_jetson

distclean: clean
	@echo "[*] Removing Docker image..."
	@$(DOCKER) image rm -f jetson-av-builder 2>/dev/null || true
	@echo "[*] Removing logs and manifests..."
	@rm -f BUILD_LOG.md FLASH_LOG.txt IGNITION_*.log support-bundle-*.tar.gz
	@rm -rf logs/ releases/
	@echo "[*] Done. Workspace pristine."

# =============================================================================
# Fleet manufacturing (Phase 6)
# =============================================================================

release:
	@if [ -z "$(VERSION)" ]; then \
	    echo "Usage: make release VERSION=v1.0.0"; exit 1; \
	fi
	@./scripts/release.sh $(VERSION)

fleet-init:
	@if [ -f fleet.csv ]; then \
	    echo "[!] fleet.csv already exists   refusing to overwrite"; exit 1; \
	fi
	@cp fleet.csv.example fleet.csv && echo "Created fleet.csv from example. Edit then 'make flash-batch'."

flash-one:
	@if [ -z "$(DEVICE)" ]; then \
	    echo "Usage: make flash-one DEVICE=<label>"; exit 1; \
	fi
	@./scripts/flash_one.sh $(DEVICE)

flash-batch:
	@FLEET_FILE="$${FLEET:-fleet.csv}"; \
	if [ ! -f "$$FLEET_FILE" ]; then \
	    echo "[!] $$FLEET_FILE not found. Run 'make fleet-init' to create from template."; exit 1; \
	fi; \
	./scripts/flash_batch.sh "$$FLEET_FILE"

fleet-status:
	@if [ ! -f fleet_log.csv ]; then echo "No fleet_log.csv yet."; exit 0; fi
	@echo "Fleet log summary (fleet_log.csv):"; \
	echo "----------------------------------"; \
	awk -F, 'NR==1 {next} \
	         {result[$$NF]++; total++} \
	         END { \
	           printf "  Total flashes: %d\n", total; \
	           for (r in result) printf "  %-20s %d\n", r":", result[r]; \
	         }' fleet_log.csv; \
	echo; \
	echo "Last 10 entries:"; \
	tail -10 fleet_log.csv | column -t -s,

# =============================================================================
# Golden image   clone & redeploy (see docs/GOLDEN_IMAGE.md)
# =============================================================================

clone-golden:
	@if [ -z "$(TAG)" ]; then \
	    echo "Usage: make clone-golden TAG=v1.0-validated [STAGED=1]"; exit 1; \
	fi; \
	if [ "$(STAGED)" = "1" ]; then \
	    ./scripts/clone_golden.sh $(TAG) --from-staged; \
	else \
	    ./scripts/clone_golden.sh $(TAG); \
	fi

flash-golden:
	@if [ -z "$(GOLDEN)" ]; then \
	    echo "Usage: make flash-golden GOLDEN=<name> [DEVICE=<label>]"; \
	    echo "       (run 'make list-goldens' to see available)"; exit 1; \
	fi
	@./scripts/flash_golden.sh $(GOLDEN) $(if $(DEVICE),--device $(DEVICE),)

list-goldens:
	@if [ ! -d golden-images ]; then \
	    echo "No golden-images/ directory yet."; exit 0; \
	fi
	@echo "Golden images under golden-images/:"; \
	echo "------------------------------------"; \
	for d in golden-images/golden-*; do \
	    [ -d "$$d" ] || continue; \
	    sz=$$(du -sh "$$d" 2>/dev/null | awk '{print $$1}'); \
	    if [ -f "$$d/golden.manifest.json" ]; then \
	        tag=$$(grep -oE '"tag" *: *"[^"]+"' "$$d/golden.manifest.json" \
	               | sed 's/.*"\([^"]*\)"/\1/'); \
	        cap=$$(grep -oE '"captured_at_iso" *: *"[^"]+"' "$$d/golden.manifest.json" \
	               | sed 's/.*"\([^"]*\)"/\1/'); \
	        mode=$$(grep -oE '"capture_mode" *: *"[^"]+"' "$$d/golden.manifest.json" \
	                | sed 's/.*"\([^"]*\)"/\1/'); \
	        printf '  %-50s %-8s [%s] %s\n' "$$(basename $$d)" "$$sz" "$$mode" "$$cap (tag: $$tag)"; \
	    else \
	        printf '  %-50s %-8s [no manifest]\n' "$$(basename $$d)" "$$sz"; \
	    fi; \
	done

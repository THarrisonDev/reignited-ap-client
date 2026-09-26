# Reignited AP client — build, test, package.
#
# Player-facing binaries target Windows x64 (the game is Win64; on Linux it
# runs through Proton). The launcher itself is cross-platform and is also
# built natively for dev use.

GO      := go
GOFLAGS :=
DIST    := dist

WINDOWS_TARGETS := GOOS=windows GOARCH=amd64

.PHONY: all vet lint test build build-windows package-mod dist regen audit lua-tests clean

LUA_TESTS := $(wildcard tests/lua/*.lua)

all: vet test build

# Lint (requires golangci-lint: https://golangci-lint.run; config in
# .golangci.yml). Falls back to go vet when golangci-lint is unavailable.
lint:
	@if command -v golangci-lint >/dev/null 2>&1; then \
		golangci-lint run -C checkd ./...; \
		golangci-lint run -C launcher ./...; \
	else \
		echo "golangci-lint not found; running go vet only" >&2; \
		$(MAKE) --no-print-directory vet; \
	fi

vet:
	$(MAKE) --no-print-directory -C checkd vet GOFLAGS="$(GOFLAGS)"
	$(MAKE) --no-print-directory -C launcher vet GOFLAGS="$(GOFLAGS)"

test:
	$(MAKE) --no-print-directory -C checkd test GOFLAGS="$(GOFLAGS)"
	$(MAKE) --no-print-directory -C launcher test GOFLAGS="$(GOFLAGS)"
	$(MAKE) --no-print-directory lua-tests

# Stub-based specs for the UE4SS mod's Lua modules (needs lua + luac 5.4).
lua-tests: $(LUA_TESTS) $(wildcard ue4ss_mod/srt_bridge/Scripts/*.lua) $(wildcard ue4ss_mod/srt_bridge/Scripts/spyro*/*.lua)
	@for t in tests/lua/*.lua; do \
		echo "== $$t"; \
		lua $$t || exit 1; \
	done

# Native builds for the host OS (dev sanity check).
build:
	mkdir -p $(DIST)/native
	$(MAKE) --no-print-directory -C checkd   build GOFLAGS="$(GOFLAGS)" OUT=$(abspath $(DIST))/native/checkd
	$(MAKE) --no-print-directory -C launcher build GOFLAGS="$(GOFLAGS)" OUT=$(abspath $(DIST))/native/launcher

# Player-facing Windows x64 builds:
#   dist/windows/srtap_checkd.exe  -> copy into the bridge folder (C:\srtap_bridge
#                                     or the Proton prefix's drive_c\srtap_bridge)
#   dist/windows/srtap_launcher.exe-> run anywhere; opens the setup UI
build-windows: checkd/srtap_checkd.exe launcher/srtap_launcher.exe
	mkdir -p $(DIST)/windows
	cp -f checkd/srtap_checkd.exe    $(DIST)/windows/
	cp -f launcher/srtap_launcher.exe $(DIST)/windows/

checkd/srtap_checkd.exe: $(wildcard checkd/*.go) checkd/locations.json
	$(MAKE) --no-print-directory -C checkd build-windows GOFLAGS="$(GOFLAGS)"

launcher/srtap_launcher.exe: $(wildcard launcher/*.go) launcher/index.html launcher/htmx.min.js
	$(MAKE) --no-print-directory -C launcher build-windows GOFLAGS="$(GOFLAGS)"

# Package the UE4SS mod as ready-to-copy tree + zip:
#   dist/srt_bridge/  -> copy into <game>/Falcon/Binaries/Win64/Mods/
#   dist/srt_bridge.zip
# Per the Acknowledgments section of the client README, ue4ss_mod/api/ never
# ships — only srt_bridge/Scripts does. lua-apclientpp.dll is gitignored, so
# it is picked up from ue4ss_mod/ when present and the build FAILS otherwise
# (a zip without the DLL cannot connect).
package-mod: $(DIST)/srt_bridge.zip

$(DIST)/srt_bridge.zip: $(shell find ue4ss_mod/srt_bridge -type f)
	@if [ ! -f ue4ss_mod/lua-apclientpp.dll ]; then \
		echo "ERROR: ue4ss_mod/lua-apclientpp.dll not found — place it beside srt_bridge/Scripts (gitignored, see README Acknowledgments)." >&2; \
		exit 1; \
	fi
	@if ! command -v zip >/dev/null 2>&1; then echo "ERROR: zip not found (install it to package the mod)" >&2; exit 1; fi
	rm -rf $(DIST)/srt_bridge
	mkdir -p $(DIST)/srt_bridge/Mods
	cp -R ue4ss_mod/srt_bridge $(DIST)/srt_bridge/Mods/
	cp -f ue4ss_mod/lua-apclientpp.dll $(DIST)/srt_bridge/Mods/srt_bridge/Scripts/
	cd $(DIST)/srt_bridge && zip -q -r ../srt_bridge.zip Mods
	@echo "packaged $(DIST)/srt_bridge.zip"

# Full release bundle (see ../world/RELEASE.md for the release order).
dist: build-windows package-mod
	@echo "dist ready: $(abspath $(DIST))"

# Regenerate the generated client files (locations.json + regions.lua) from
# world/data/*.json. Run after editing any data source, and before building
# checkd (it embeds locations.json).
regen:
	python3 checkd/scripts/gen_locations.py

# CI guard: the checked-in generated files match the data sources.
audit:
	python3 checkd/scripts/audit_locations.py

clean:
	rm -rf $(DIST) checkd/srtap_checkd.exe launcher/srtap_launcher.exe launcher/launcher
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
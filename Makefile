# Reignited AP client — build, test, package.
#
# Player-facing binaries target Windows x64 (the game is Win64; on Linux it
# runs through Proton). The launcher itself is cross-platform and is also
# built natively for dev use.

GO      := go
GOFLAGS :=
DIST    := dist

WINDOWS_TARGETS := GOOS=windows GOARCH=amd64

.PHONY: all vet lint luacheck deadcode test build build-windows build-linux package-mod package-client deploy deploy-mod deploy-checkd dist regen audit lua-tests clean

# Paths the deploy target writes into, defaulted for a standard Steam install
# on this Linux/Proton box. `make deploy` needs no arguments; override a path
# only if your install lives elsewhere.
GAME_WIN64 ?= $(HOME)/.local/share/Steam/steamapps/common/Spyro Reignited Trilogy/Falcon/Binaries/Win64
BRIDGE_DIR ?= $(HOME)/.local/share/Steam/steamapps/compatdata/996580/pfx/drive_c/srtap_bridge
MOD_DEST   := $(GAME_WIN64)/Mods/srt_bridge

LUA_TESTS := $(wildcard tests/lua/*.lua)

all: vet test build

# Lint (requires golangci-lint: https://golangci-lint.run; config in
# .golangci.yml). Falls back to go vet when golangci-lint is unavailable.
# golangci-lint discovers .golangci.yml by walking up from the module dir, so
# run each module from inside it (its own `-C` flag is gone in v2).
lint:
	@if command -v golangci-lint >/dev/null 2>&1; then \
		(cd checkd && golangci-lint run ./...) && \
		(cd launcher && golangci-lint run ./...); \
	else \
		echo "golangci-lint not found; running go vet only" >&2; \
		$(MAKE) --no-print-directory vet; \
	fi
	$(MAKE) --no-print-directory luacheck

# Unused locals, arguments and dead branches in the UE4SS mod. Config in
# .luacheckrc (requires luacheck: https://github.com/lunarmodules/luacheck).
luacheck:
	@if command -v luacheck >/dev/null 2>&1; then \
		luacheck ue4ss_mod/srt_bridge/Scripts --codes --no-color; \
	else \
		echo "ERROR: luacheck not installed (luarocks install luacheck)" >&2; exit 1; \
	fi

# Dead code: module functions nothing in the mod calls (Go side is covered by
# the `unused` linter in make lint).
deadcode:
	python3 scripts/audit_dead_lua.py

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

# Linux x64 launcher — Proton players run this natively; it carries the same
# built-in installer as the Windows build.
build-linux: launcher/srtap_launcher

launcher/srtap_launcher: $(wildcard launcher/*.go) launcher/index.html launcher/htmx.min.js
	$(MAKE) --no-print-directory -C launcher build-linux GOFLAGS="$(GOFLAGS)"

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

# Assemble the player-facing client download: both launchers, the checkd
# daemon, the packaged mod, the install wrappers, INSTALL.md, and the
# third-party notices — one folder plus a zip. Players extract it and run
# install.bat / install.sh.
package-client: build-windows build-linux package-mod
	rm -rf $(DIST)/client
	mkdir -p $(DIST)/client
	cp -f checkd/srtap_checkd.exe     $(DIST)/client/
	cp -f launcher/srtap_launcher.exe $(DIST)/client/
	cp -f launcher/srtap_launcher     $(DIST)/client/srtap_launcher
	cp -f $(DIST)/srt_bridge.zip      $(DIST)/client/
	cp -f install/install.bat install/install.sh $(DIST)/client/
	cp -f ../INSTALL.md               $(DIST)/client/
	cp -f ../THIRD-PARTY-NOTICES.md   $(DIST)/client/
	chmod +x $(DIST)/client/install.sh $(DIST)/client/srtap_launcher
	cd $(DIST) && rm -f reignited-ap-client.zip && zip -q -r reignited-ap-client.zip client
	@echo "packaged $(DIST)/reignited-ap-client.zip"

# Install everything for a game session: build the Windows checkd, drop it
# into the bridge folder (backing up the old one), and copy the Lua mod into
# the game's Mods folder. Run `make deploy` after changing Lua or checkd.
deploy: deploy-mod deploy-checkd

# Lua mod -> <game>/Mods/srt_bridge. Copies over the installed tree and leaves
# unrelated files alone (the player's config.txt, logs). Adds the AP client DLL
# and its license when present in ue4ss_mod/.
deploy-mod:
	@test -d "$(GAME_WIN64)" || { echo "ERROR: game not found at $(GAME_WIN64) (override GAME_WIN64=...)" >&2; exit 1; }
	mkdir -p "$(MOD_DEST)"
	cp -R ue4ss_mod/srt_bridge/. "$(MOD_DEST)/"
	@if [ -f ue4ss_mod/lua-apclientpp.dll ]; then \
		cp -f ue4ss_mod/lua-apclientpp.dll "$(MOD_DEST)/Scripts/"; \
		cp -f ue4ss_mod/api/LICENSE "$(MOD_DEST)/Scripts/lua-apclientpp-license.txt"; \
		echo "mod    -> $(MOD_DEST)"; \
	else \
		echo "mod    -> $(MOD_DEST) (no DLL; add ue4ss_mod/lua-apclientpp.dll to ship it)"; \
	fi

# Windows checkd -> the bridge folder the mod spawns it from. Keeps a
# timestamped backup of the previous srtap_checkd.exe, matching the .bak-*
# files already there.
deploy-checkd: checkd/srtap_checkd.exe
	@test -d "$(BRIDGE_DIR)" || { echo "ERROR: bridge folder not found at $(BRIDGE_DIR) (override BRIDGE_DIR=...)" >&2; exit 1; }
	mkdir -p "$(BRIDGE_DIR)"
	@if [ -f "$(BRIDGE_DIR)/srtap_checkd.exe" ]; then \
		bak="$(BRIDGE_DIR)/srtap_checkd.exe.bak-$$(date +%Y%m%d-%H%M%S)"; \
		cp -f "$(BRIDGE_DIR)/srtap_checkd.exe" "$$bak"; \
		echo "backup -> $$bak"; \
	fi
	cp -f checkd/srtap_checkd.exe "$(BRIDGE_DIR)/srtap_checkd.exe"
	@echo "checkd -> $(BRIDGE_DIR)/srtap_checkd.exe"

# Full release bundle (see ../world/RELEASE.md for the release order).
dist: package-client
	@echo "dist ready: $(abspath $(DIST))"

# Regenerate the generated client files (locations.json + regions.lua) from
# world/data/*.json. Run after editing any data source, and before building
# checkd (it embeds locations.json).
regen:
	python3 checkd/scripts/gen_locations.py

# CI guard: the checked-in generated files match the data sources.
audit:
	python3 checkd/scripts/audit_locations.py
	python3 scripts/audit_client_version.py

clean:
	rm -rf $(DIST) checkd/srtap_checkd.exe launcher/srtap_launcher.exe launcher/srtap_launcher launcher/launcher
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
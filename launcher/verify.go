// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

package main

import (
	"os"
	"path/filepath"
	"strings"
)

// Check is one setup verification result. Fix is shown only when !OK, and is
// phrased as guidance for the user (the launcher verifies & guides; it does not
// install anything itself).
type Check struct {
	Name   string
	OK     bool
	Detail string
	Fix    string
}

func fileExists(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && !fi.IsDir()
}

func dirExists(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.IsDir()
}

// modEnabled reports whether mods.txt has an uncommented `srt_bridge : 1` line.
func modEnabled(modsTxt string) (enabled bool, found bool) {
	err := scanLines(modsTxt, ';', func(line string) bool {
		name, val, ok := strings.Cut(line, ":")
		if !ok || strings.TrimSpace(name) != "srt_bridge" {
			return true
		}
		enabled, found = strings.TrimSpace(val) == "1", true
		return false
	})
	return err == nil && enabled, found
}

// Verify runs the setup checks against the resolved paths and returns them in
// display order. It never mutates anything on disk.
func Verify(p Paths) []Check {
	var checks []Check

	checks = append(checks, Check{
		Name:   "Bridge folder",
		OK:     dirExists(p.ConfigDir),
		Detail: p.ConfigDir,
		Fix:    "The launcher creates this when you save the config. If it stays missing, check the path override points at the game's Proton prefix (Linux) or C:\\srtap_bridge (Windows).",
	})

	checkd := filepath.Join(p.ConfigDir, "srtap_checkd.exe")
	checks = append(checks, Check{
		Name:   "Check daemon (srtap_checkd.exe)",
		OK:     fileExists(checkd),
		Detail: checkd,
		Fix:    "Copy srtap_checkd.exe from dist/ into the bridge folder (build it with `make build-windows` in the client repo).",
	})

	checks = append(checks, Check{
		Name:   "Game folder (Falcon/Binaries/Win64)",
		OK:     dirExists(p.GameWin64),
		Detail: p.GameWin64,
		Fix:    "Point the Game folder override at your Spyro Reignited Trilogy install's Falcon\\Binaries\\Win64 (it may be on a different Steam library drive).",
	})

	dwmapi := filepath.Join(p.GameWin64, "dwmapi.dll")
	ue4ss := filepath.Join(p.GameWin64, "UE4SS.dll")
	checks = append(checks, Check{
		Name:   "UE4SS installed",
		OK:     fileExists(dwmapi) && fileExists(ue4ss),
		Detail: "dwmapi.dll + UE4SS.dll",
		Fix:    "Install UE4SS (v3.0.1) into the game's Win64 folder — the dwmapi.dll proxy + UE4SS.dll.",
	})

	modMain := filepath.Join(p.GameWin64, "Mods", "srt_bridge", "Scripts", "main.lua")
	checks = append(checks, Check{
		Name:   "srt_bridge mod present",
		OK:     fileExists(modMain),
		Detail: modMain,
		Fix:    "Copy client/ue4ss_mod/srt_bridge into the game's Mods folder.",
	})

	apDLL := filepath.Join(p.GameWin64, "Mods", "srt_bridge", "Scripts", "lua-apclientpp.dll")
	checks = append(checks, Check{
		Name:   "lua-apclientpp.dll present",
		OK:     fileExists(apDLL),
		Detail: apDLL,
		Fix:    "The Archipelago client DLL must sit beside the mod's main.lua in Scripts/.",
	})

	modsTxt := filepath.Join(p.GameWin64, "Mods", "mods.txt")
	enabled, found := modEnabled(modsTxt)
	detail := modsTxt
	fix := "Add a line `srt_bridge : 1` to Mods/mods.txt."
	if found && !enabled {
		fix = "Change the srt_bridge line in Mods/mods.txt to `srt_bridge : 1`."
	}
	checks = append(checks, Check{
		Name:   "srt_bridge enabled in mods.txt",
		OK:     found && enabled,
		Detail: detail,
		Fix:    fix,
	})

	return checks
}

// AllOK reports whether every check passed.
func AllOK(checks []Check) bool {
	for _, c := range checks {
		if !c.OK {
			return false
		}
	}
	return true
}

// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-31

package main

import (
	"os"
	"path/filepath"
	"runtime"
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
// display order. It never leaves a change on disk (the writability probe
// creates and removes one temp file).
func Verify(p Paths) []Check {
	if p.ConfigDir == "" || p.GameWin64 == "" {
		return []Check{{
			Name:   "Folder locations",
			OK:     false,
			Detail: "both folders are required",
			Fix:    "Set the Bridge folder and Game folder override under Folder locations, then save.",
		}}
	}

	checks := bridgeChecks(p)

	checkd := filepath.Join(p.ConfigDir, "srtap_checkd.exe")
	checks = append(checks, Check{
		Name:   "Check daemon (srtap_checkd.exe)",
		OK:     fileExists(checkd),
		Detail: checkd,
		Fix:    "Click Install / update setup above, or copy srtap_checkd.exe from the release folder into the bridge folder.",
	})

	checks = append(checks, Check{
		Name:   "Game folder (Falcon/Binaries/Win64)",
		OK:     dirExists(p.GameWin64),
		Detail: p.GameWin64,
		Fix:    "Point the Game folder override at your Spyro Reignited Trilogy install's Falcon\\Binaries\\Win64 (it may be on a different Steam library drive).",
	})
	if check, ok := writableCheck(p); ok {
		checks = append(checks, check)
	}

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
		Fix:    "Click Install / update setup above, or extract srt_bridge.zip into the game's ...\\Win64\\Mods\\ folder.",
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

// bridgeChecks returns the bridge-folder checks: the folder itself plus, on
// Linux, whether another prefix holds newer bridge activity than it.
func bridgeChecks(p Paths) []Check {
	fix := "The launcher creates this when you save the config. If it stays missing, check the path override points at the game's Proton prefix (Linux) or C:\\srtap_bridge (Windows)."
	if runtime.GOOS != "windows" && !p.PrefixReady {
		fix = "Launch the game once through Steam so it creates the Proton prefix, then click Install / update setup."
	}
	checks := []Check{{
		Name:   "Bridge folder",
		OK:     dirExists(p.ConfigDir),
		Detail: p.ConfigDir,
		Fix:    fix,
	}}
	if match, ok := bridgeMatchesGame(p); ok {
		checks = append(checks, match)
	}
	return checks
}

// writableCheck returns the game-folder permission check and whether it applies
// (only when the folder exists).
func writableCheck(p Paths) (Check, bool) {
	if !dirExists(p.GameWin64) {
		return Check{}, false
	}
	return Check{
		Name:   "Game folder writable",
		OK:     probeWritable(p.GameWin64) == nil,
		Detail: p.GameWin64,
		Fix:    "Run install.bat as administrator (Steam is under Program Files), or move the Steam library to a user-writable drive.",
	}, true
}

// bridgeMatchesGame reports whether another Proton prefix has newer bridge
// activity than the selected folder. It runs only for a Linux layout backed by
// a real prefix that actually sits inside a prefix, so a temp or test layout
// never consults the developer's Steam install. ok is false when the check does
// not apply; with no bridge log anywhere it passes, so a fresh install is not a
// false red.
func bridgeMatchesGame(p Paths) (Check, bool) {
	if runtime.GOOS == "windows" || !p.PrefixReady || !insidePrefix(p.ConfigDir) {
		return Check{}, false
	}
	best := bestEvidencePrefix(discover().Prefixes)
	check := Check{Name: "Bridge folder matches the game", OK: true, Detail: p.ConfigDir}
	if best == nil || best.LogTime == 0 {
		return check, true
	}
	if best.LogTime <= fileModTime(filepath.Join(p.ConfigDir, "bridge.log")) {
		return check, true
	}
	check.OK = false
	check.Detail = "newer bridge activity in " + best.Bridge
	check.Fix = "Set the Bridge folder to " + best.Bridge + " and save (or click Reset to auto-detected)."
	return check, true
}

// insidePrefix reports whether dir sits inside a Proton prefix: one of its
// ancestors holds a drive_c directory.
func insidePrefix(dir string) bool {
	d := filepath.Clean(dir)
	for {
		if dirExists(filepath.Join(d, "drive_c")) {
			return true
		}
		parent := filepath.Dir(d)
		if parent == d {
			return false
		}
		d = parent
	}
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

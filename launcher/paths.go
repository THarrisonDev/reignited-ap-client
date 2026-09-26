package main

import (
	"os"
	"path/filepath"
	"runtime"
)

// appID is Spyro Reignited Trilogy's Steam appid — used for the Proton
// compatdata prefix on Linux and the game launch URL.
const appID = "996580"

// Paths holds every filesystem location the launcher touches. All fields are
// resolved best-effort by defaultPaths() and are meant to be overridable from
// the UI, because Steam libraries can live on any drive and the config dir
// differs between a native Windows install and a Proton prefix on Linux.
//
//   - ConfigDir: where the mod reads config.txt and checks.json and where
//     srtap_checkd.exe lives (the mod's "C:/srtap_bridge"). On Linux this is
//     inside the Proton prefix's drive_c; on Windows it's literally C:\.
//   - GameWin64: <game>/Falcon/Binaries/Win64 — where UE4SS and the Mods/ tree
//     live; used only by the setup verifier.
type Paths struct {
	ConfigDir string
	GameWin64 string
}

// steamRoot returns the default Steam install root for the host OS. Both the
// game (steamapps/common) and the Proton prefix (steamapps/compatdata) hang
// off it.
func steamRoot() string {
	if runtime.GOOS == "windows" {
		// Steam's own default; libraries on other drives are handled by the
		// UI override, not guessed here.
		if pf := os.Getenv("ProgramFiles(x86)"); pf != "" {
			return filepath.Join(pf, "Steam")
		}
		return `C:\Program Files (x86)\Steam`
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "Steam")
}

// protonPrefixDriveC is the drive_c of the game's Proton compatdata prefix
// (Linux only). This is where the in-Proton "C:/..." paths actually land on
// the host filesystem.
func protonPrefixDriveC() string {
	return filepath.Join(steamRoot(), "steamapps", "compatdata", appID,
		"pfx", "drive_c")
}

// gameWin64 returns the default Falcon/Binaries/Win64 directory under the
// standard Steam library. Games installed to a secondary Steam library folder
// need the UI override.
func gameWin64() string {
	return filepath.Join(steamRoot(), "steamapps", "common",
		"Spyro Reignited Trilogy", "Falcon", "Binaries", "Win64")
}

// defaultPaths resolves the best-guess locations for the host OS.
func defaultPaths() Paths {
	if runtime.GOOS == "windows" {
		return Paths{
			ConfigDir: `C:\srtap_bridge`,
			GameWin64: gameWin64(),
		}
	}
	// Linux (Proton): the mod's "C:/..." paths live inside the prefix's drive_c.
	driveC := protonPrefixDriveC()
	return Paths{
		ConfigDir: filepath.Join(driveC, "srtap_bridge"),
		GameWin64: gameWin64(),
	}
}

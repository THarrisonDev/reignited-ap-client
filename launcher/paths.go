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

// appID is Spyro Reignited Trilogy's Steam appid — used for the Proton
// compatdata prefix on Linux and the game launch URL.
const appID = "996580"

// Connection defaults shared by the config view and the feed. A host with no
// scheme is completed by normalizeHost/feedURLs; the port matches Archipelago's.
const (
	defaultHost = "127.0.0.1:38281"
	defaultPort = "38281"
	defaultSlot = "SRTPlayer"
)

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
// off it. On Linux, $STEAM_ROOT overrides for a non-standard native install.
func steamRoot() string {
	if runtime.GOOS == "windows" {
		// Steam's own default; libraries on other drives are handled by the
		// UI override, not guessed here.
		if pf := os.Getenv("ProgramFiles(x86)"); pf != "" {
			return filepath.Join(pf, "Steam")
		}
		return `C:\Program Files (x86)\Steam`
	}
	if root := os.Getenv("STEAM_ROOT"); root != "" {
		return root
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".local", "share", "Steam")
}

// flatpakSteamRoot is where Flatpak Steam keeps its data. It is a separate
// root, not a library under the native one, so it must be searched as well.
func flatpakSteamRoot() string {
	if runtime.GOOS == "windows" {
		return ""
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".var", "app", "com.valvesoftware.Steam",
		".local", "share", "Steam")
}

// gameWin64 returns the default Falcon/Binaries/Win64 directory under the
// standard Steam library, used as a fallback when game detection fails.
func gameWin64() string {
	return filepath.Join(steamRoot(), "steamapps", "common",
		"Spyro Reignited Trilogy", "Falcon", "Binaries", "Win64")
}

// compatdataDriveC is the drive_c of the game's Proton compatdata prefix under
// a given Steam library root (Linux only). Steam creates the prefix in the
// same library that holds the game, so this must be derived per-library, not
// from the default root.
func compatdataDriveC(lib string) string {
	return filepath.Join(lib, "steamapps", "compatdata", appID, "pfx", "drive_c")
}

// gameRel is the game's Win64 path relative to a Steam library root.
func gameRel() string {
	return filepath.Join("steamapps", "common", "Spyro Reignited Trilogy",
		"Falcon", "Binaries", "Win64")
}

// steamLibraries returns every Steam library root the launcher should search:
// the base root, the Flatpak root when present, and any extra libraries listed
// in their libraryfolders.vdf files. Best-effort — a missing or unreadable file
// just yields fewer candidates, so callers always have at least one.
func steamLibraries() []string {
	roots := []string{steamRoot()}
	if fp := flatpakSteamRoot(); fp != "" && fp != roots[0] && dirExists(fp) {
		roots = append(roots, fp)
	}
	libs := append([]string(nil), roots...)
	for _, root := range roots {
		data, err := os.ReadFile(filepath.Join(root, "steamapps", "libraryfolders.vdf"))
		if err != nil {
			continue
		}
		libs = append(libs, parseLibraryFolders(data)...)
	}
	return libs
}

// parseLibraryFolders extracts library roots from a libraryfolders.vdf body.
// It handles both the modern `"path" "<dir>"` form and the legacy
// `"<n>" "<dir>"` map, ignoring anything that is not an absolute path.
func parseLibraryFolders(data []byte) []string {
	var out []string
	seen := map[string]bool{}
	for _, line := range strings.Split(string(data), "\n") {
		key, val, ok := vdfPair(line)
		if !ok || !isAbsPath(val) {
			continue
		}
		if !strings.EqualFold(key, "path") && !isNumeric(key) {
			continue
		}
		p := filepath.Clean(filepath.FromSlash(strings.ReplaceAll(val, `\\`, `\`)))
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	return out
}

// vdfPair returns the first two double-quoted tokens on a line, treating them
// as a key/value pair. Lines with fewer than two tokens (braces, bare keys)
// report ok=false.
func vdfPair(line string) (key, val string, ok bool) {
	var toks []string
	for {
		i := strings.IndexByte(line, '"')
		if i < 0 {
			break
		}
		rest := line[i+1:]
		j := strings.IndexByte(rest, '"')
		if j < 0 {
			break
		}
		toks = append(toks, rest[:j])
		line = rest[j+1:]
	}
	if len(toks) < 2 {
		return "", "", false
	}
	return toks[0], toks[1], true
}

// isNumeric reports whether s is non-empty and all digits.
func isNumeric(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// isAbsPath reports whether s looks like an absolute filesystem path on either
// OS (leading "/" or a drive letter like "C:\").
func isAbsPath(s string) bool {
	if strings.HasPrefix(s, "/") {
		return true
	}
	return len(s) >= 3 && s[1] == ':' && (s[2] == '\\' || s[2] == '/')
}

// findGameWin64 returns the game's Falcon/Binaries/Win64 under the first Steam
// library that has it, along with that library root. ok is false when no
// library contains the game.
func findGameWin64(libs []string) (win64, lib string, ok bool) {
	for _, l := range libs {
		p := filepath.Join(l, gameRel())
		if dirExists(p) {
			return p, l, true
		}
	}
	return "", "", false
}

// defaultPaths resolves the best-guess locations for the host OS, searching
// every Steam library for the game before falling back to the default root.
func defaultPaths() Paths {
	// No home directory means no non-relative guess: leave both folders empty
	// so the launcher asks for an override instead of creating a tree in the
	// process working directory.
	if steamRoot() == "" {
		return Paths{}
	}
	libs := steamLibraries()
	game, lib, found := findGameWin64(libs)
	if !found {
		game, lib = gameWin64(), steamRoot()
	}
	if runtime.GOOS == "windows" {
		return Paths{
			ConfigDir: `C:\srtap_bridge`,
			GameWin64: game,
		}
	}
	// Linux (Proton): the mod's "C:/..." paths live inside the prefix's drive_c.
	return Paths{
		ConfigDir: filepath.Join(compatdataDriveC(lib), "srtap_bridge"),
		GameWin64: game,
	}
}

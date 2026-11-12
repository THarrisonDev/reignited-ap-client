// Author: Tim Harrison
// Created: 2026-11-09
// Updated: 2026-11-09

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"
)

// steamHome isolates the host environment to a temp home and clears every
// Steam root variable, so tests never read the real install. It returns the
// temp home.
func steamHome(t *testing.T) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("Linux Steam root layout")
	}
	home := t.TempDir()
	for _, key := range []string{"HOME", "USERPROFILE", "XDG_DATA_HOME",
		"STEAM_ROOT", "ProgramFiles(x86)", "ProgramFiles"} {
		t.Setenv(key, "")
	}
	t.Setenv("HOME", home)
	t.Setenv("USERPROFILE", home)
	return home
}

// steamTree creates the default Steam root and returns the temp home plus the
// root path.
func steamTree(t *testing.T) (home, root string) {
	t.Helper()
	home = steamHome(t)
	root = filepath.Join(home, ".local", "share", "Steam")
	if err := os.MkdirAll(filepath.Join(root, "steamapps"), 0755); err != nil {
		t.Fatal(err)
	}
	return home, root
}

// libraryVDF renders a libraryfolders.vdf listing libs in order.
func libraryVDF(libs ...string) string {
	var b strings.Builder
	b.WriteString("\"libraryfolders\"\n{\n")
	for i, lib := range libs {
		fmt.Fprintf(&b, "\t\"%d\"\n\t{\n\t\t\"path\"\t\t\"%s\"\n\t}\n", i, lib)
	}
	b.WriteString("}\n")
	return b.String()
}

// writeText writes body to path, creating parents.
func writeText(t *testing.T, path, body string) {
	t.Helper()
	mkfile(t, path)
	if err := os.WriteFile(path, []byte(body), 0644); err != nil {
		t.Fatal(err)
	}
}

// listLibraries writes a libraryfolders.vdf under root listing libs.
func listLibraries(t *testing.T, root string, libs ...string) {
	t.Helper()
	writeText(t, filepath.Join(root, "steamapps", "libraryfolders.vdf"), libraryVDF(libs...))
}

// setMtime pins a file's modification time so evidence ordering is explicit.
func setMtime(t *testing.T, path string, unix int64) {
	t.Helper()
	ts := time.Unix(unix, 0)
	if err := os.Chtimes(path, ts, ts); err != nil {
		t.Fatal(err)
	}
}

// prefixTree creates and returns a library's pfx/drive_c.
func prefixTree(t *testing.T, lib string) string {
	t.Helper()
	driveC := compatdataDriveC(lib)
	if err := os.MkdirAll(driveC, 0755); err != nil {
		t.Fatal(err)
	}
	return driveC
}

// bridgeIn creates the new bridge folder inside drive_c and returns it.
func bridgeIn(t *testing.T, driveC string) string {
	t.Helper()
	bridge := newBridgeForDriveC(driveC)
	if err := os.MkdirAll(bridge, 0755); err != nil {
		t.Fatal(err)
	}
	return bridge
}

// addSave writes a FalconSave fixture for user and pins its mtime.
func addSave(t *testing.T, driveC, user string, unix int64) {
	t.Helper()
	path := filepath.Join(driveC, "users", user, "AppData", "Local", "Falcon",
		"Saved", "SaveGames", "FalconSave.1.sav")
	mkfile(t, path)
	setMtime(t, path, unix)
}

// libraryPair returns a temp home and two library roots listed in the default
// Steam root's libraryfolders.vdf.
func libraryPair(t *testing.T) (home, root, libA, libB string) {
	t.Helper()
	home, root = steamTree(t)
	libA = filepath.Join(home, "LibraryA")
	libB = filepath.Join(home, "LibraryB")
	listLibraries(t, root, libA, libB)
	return home, root, libA, libB
}

// seedPrefix creates lib's Proton prefix with a new-location bridge and a
// config file, plus a bridge.log at logTime and a save at saveTime (zero skips
// that piece). It returns the drive_c and the bridge folder it used.
func seedPrefix(t *testing.T, lib string, logTime, saveTime int64) (driveC, bridge string) {
	t.Helper()
	driveC = prefixTree(t, lib)
	bridge = bridgeIn(t, driveC)
	mkfile(t, filepath.Join(bridge, "config.txt"))
	if logTime != 0 {
		logPath := filepath.Join(bridge, "bridge.log")
		mkfile(t, logPath)
		setMtime(t, logPath, logTime)
	}
	if saveTime != 0 {
		addSave(t, driveC, "steamuser", saveTime)
	}
	return driveC, bridge
}

// TestProtonUserPrefersSteamUser: the bridge follows the account Steam runs the
// game as, even when another profile holds the newest save.
func TestProtonUserPrefersSteamUser(t *testing.T) {
	driveC := filepath.Join(t.TempDir(), "pfx", "drive_c")
	for _, user := range []string{"steamuser", "Public"} {
		if err := os.MkdirAll(filepath.Join(driveC, "users", user, "AppData", "Local"), 0755); err != nil {
			t.Fatal(err)
		}
	}
	addSave(t, driveC, "Public", 9000)

	if got := protonUser(driveC); got != "steamuser" {
		t.Fatalf("protonUser = %s, want steamuser", got)
	}
}

// TestProtonUserFallsBackToNewestSave: a prefix without steamuser uses the
// profile with the newest save.
func TestProtonUserFallsBackToNewestSave(t *testing.T) {
	driveC := filepath.Join(t.TempDir(), "pfx", "drive_c")
	addSave(t, driveC, "mom", 1000)
	addSave(t, driveC, "dad", 2000)

	if got := protonUser(driveC); got != "dad" {
		t.Fatalf("protonUser = %s, want dad", got)
	}
}

func TestDiscoverFindsGameInSecondLibrary(t *testing.T) {
	home, root := steamTree(t)
	lib2 := filepath.Join(home, "Games", "Library2")
	listLibraries(t, root, lib2)
	mkfile(t, filepath.Join(lib2, gameRel(), "Spyro-Win64-Shipping.exe"))

	d := discover()
	if d.Roots[0] != root {
		t.Fatalf("first root = %s, want %s", d.Roots[0], root)
	}
	if !slices.Contains(d.Libraries, lib2) {
		t.Fatalf("second library missing from %v", d.Libraries)
	}
	if d.GameLib != lib2 || d.GameWin64 != filepath.Join(lib2, gameRel()) {
		t.Fatalf("game = %s in %s", d.GameWin64, d.GameLib)
	}
	if d.Prefix != "" || d.Note == "" {
		t.Fatalf("no prefix expected, got %q note %q", d.Prefix, d.Note)
	}
}

func TestDiscoverSteamRootOverride(t *testing.T) {
	home := steamHome(t)
	alt := filepath.Join(home, "altsteam")
	mkfile(t, filepath.Join(alt, "steamapps", "common", "keep"))
	mkfile(t, filepath.Join(alt, gameRel(), "Spyro-Win64-Shipping.exe"))
	t.Setenv("STEAM_ROOT", alt)

	d := discover()
	if d.Roots[0] != alt {
		t.Fatalf("STEAM_ROOT must come first: %v", d.Roots)
	}
	if d.GameLib != alt {
		t.Fatalf("game library = %s, want %s", d.GameLib, alt)
	}
	defaultRoot := filepath.Join(home, ".local", "share", "Steam")
	if !slices.Contains(d.Roots, defaultRoot) {
		t.Fatalf("default root missing after override: %v", d.Roots)
	}
}

func TestDiscoverSnapAndFlatpakRoots(t *testing.T) {
	home := steamHome(t)
	flatpak := filepath.Join(home, ".var", "app", "com.valvesoftware.Steam",
		".local", "share", "Steam")
	snap := filepath.Join(home, "snap", "steam", "common", ".local", "share", "Steam")
	for _, dir := range []string{flatpak, snap} {
		if err := os.MkdirAll(filepath.Join(dir, "steamapps"), 0755); err != nil {
			t.Fatal(err)
		}
	}
	mkfile(t, filepath.Join(snap, gameRel(), "Spyro-Win64-Shipping.exe"))

	d := discover()
	for _, want := range []string{flatpak, snap} {
		if !slices.Contains(d.Roots, want) {
			t.Fatalf("%s missing from roots %v", want, d.Roots)
		}
	}
	if d.GameLib != snap {
		t.Fatalf("game library = %s, want snap %s", d.GameLib, snap)
	}
}

func TestFindGameWin64PrefersAppmanifest(t *testing.T) {
	root := t.TempDir()
	libA := filepath.Join(root, "A")
	libB := filepath.Join(root, "B")
	mkfile(t, filepath.Join(libA, gameRel(), "Spyro-Win64-Shipping.exe"))
	mkfile(t, filepath.Join(libB, gameRel(), "Spyro-Win64-Shipping.exe"))
	mkfile(t, filepath.Join(libB, appmanifestRel()))

	_, lib, ok := findGameWin64([]string{libA, libB})
	if !ok || lib != libB {
		t.Fatalf("appmanifest library must win: lib=%s ok=%v", lib, ok)
	}

	mkfile(t, filepath.Join(libA, appmanifestRel()))
	_, lib, ok = findGameWin64([]string{libA, libB})
	if !ok || lib != libA {
		t.Fatalf("input order must break a manifest tie: lib=%s ok=%v", lib, ok)
	}
}

func TestSelectPrefixLogBeatsNewerSave(t *testing.T) {
	_, _, libA, libB := libraryPair(t)

	seedPrefix(t, libA, 1000, 9000)
	driveB, _ := seedPrefix(t, libB, 5000, 1000)

	d := discover()
	if d.Prefix != filepath.Dir(driveB) {
		t.Fatalf("newer log must win over a newer save: prefix = %s", d.Prefix)
	}
	if len(d.Prefixes) != 2 {
		t.Fatalf("prefixes = %d", len(d.Prefixes))
	}
	for _, p := range d.Prefixes {
		if p.BridgeLog == "" || p.LogTime == 0 || p.SaveTime == 0 {
			t.Fatalf("incomplete prefix info: %+v", p)
		}
	}
}

func TestSelectPrefixNewestSaveWithoutLogs(t *testing.T) {
	_, _, libA, libB := libraryPair(t)

	driveA, _ := seedPrefix(t, libA, 0, 7000)
	prefixTree(t, libB)

	d := discover()
	if d.Prefix != filepath.Dir(driveA) {
		t.Fatalf("newest save must win: prefix = %s", d.Prefix)
	}
}

func TestPrefixLegacyBridgeSelected(t *testing.T) {
	home, root := steamTree(t)
	lib := filepath.Join(home, "Library")
	listLibraries(t, root, lib)
	driveC := prefixTree(t, lib)
	legacy := legacyBridgeForDriveC(driveC)
	mkfile(t, filepath.Join(legacy, "srtap_checkd.exe"))

	d := discover()
	if len(d.Prefixes) != 1 || d.Prefixes[0].Bridge != legacy {
		t.Fatalf("legacy bridge must be selected when it is the only one: %+v", d.Prefixes)
	}
	p := defaultPaths()
	if !p.PrefixReady || p.ConfigDir != legacy {
		t.Fatalf("defaultPaths = %+v, want legacy %s", p, legacy)
	}
}

func TestDefaultPathsNoPrefixCreatesNothing(t *testing.T) {
	home, root := steamTree(t)

	p := defaultPaths()
	if p.PrefixReady {
		t.Fatalf("PrefixReady without a prefix: %+v", p)
	}
	want := newBridgeForDriveC(compatdataDriveC(root))
	if p.ConfigDir != want {
		t.Fatalf("ConfigDir = %s, want intended %s", p.ConfigDir, want)
	}
	if !strings.Contains(p.ConfigDir, "compatdata") || !strings.Contains(p.ConfigDir, appID) {
		t.Fatalf("ConfigDir should stay in the prefix tree: %s", p.ConfigDir)
	}
	if dirExists(p.ConfigDir) {
		t.Fatalf("must not create the bridge folder: %s", p.ConfigDir)
	}
	if dirExists(filepath.Join(root, "steamapps", "compatdata")) {
		t.Fatal("must not create compatdata")
	}
	if dirExists(filepath.Join(home, ".steam")) {
		t.Fatal("must not create ~/.steam")
	}
}

func TestBridgeSelection(t *testing.T) {
	cases := []struct {
		name       string
		newFile    string
		legacyFile string
		wantLegacy bool
	}{
		{"neither", "", "", false},
		{"new config", "config.txt", "", false},
		{"legacy checkd", "", "srtap_checkd.exe", true},
		{"both", "config.txt", "srtap_checkd.exe", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			newDir := filepath.Join(t.TempDir(), "new")
			legacyDir := filepath.Join(t.TempDir(), "legacy")
			for _, d := range []string{newDir, legacyDir} {
				if err := os.MkdirAll(d, 0755); err != nil {
					t.Fatal(err)
				}
			}
			if tc.newFile != "" {
				mkfile(t, filepath.Join(newDir, tc.newFile))
			}
			if tc.legacyFile != "" {
				mkfile(t, filepath.Join(legacyDir, tc.legacyFile))
			}
			want := newDir
			if tc.wantLegacy {
				want = legacyDir
			}
			if got := bridgeSelection(newDir, legacyDir); got != want {
				t.Fatalf("got %s, want %s", got, want)
			}
		})
	}
}

func TestLocalAppDataBridge(t *testing.T) {
	old := getenv
	t.Cleanup(func() { getenv = old })

	t.Run("localappdata new folder", func(t *testing.T) {
		local := t.TempDir()
		env := map[string]string{"LOCALAPPDATA": local}
		getenv = func(k string) string { return env[k] }
		mkfile(t, filepath.Join(local, bridgeDirName, "config.txt"))
		if got, want := localAppDataBridge(), filepath.Join(local, bridgeDirName); got != want {
			t.Fatalf("got %s, want %s", got, want)
		}
	})

	t.Run("profile fallback", func(t *testing.T) {
		profile := t.TempDir()
		env := map[string]string{"USERPROFILE": profile}
		getenv = func(k string) string { return env[k] }
		want := filepath.Join(profile, "AppData", "Local", bridgeDirName)
		if got := localAppDataBridge(); got != want {
			t.Fatalf("got %s, want %s", got, want)
		}
	})

	t.Run("no environment", func(t *testing.T) {
		getenv = func(string) string { return "" }
		if got := localAppDataBridge(); got != windowsLegacyBridge {
			t.Fatalf("got %s, want legacy %s", got, windowsLegacyBridge)
		}
	})
}

func TestDedupePathsResolvesSymlinks(t *testing.T) {
	real := t.TempDir()
	alias := filepath.Join(t.TempDir(), "alias")
	if err := os.Symlink(real, alias); err != nil {
		t.Fatal(err)
	}
	got := dedupePaths([]string{real, alias, real + string(filepath.Separator),
		filepath.Join(real, "sub")})
	want := []string{real, filepath.Join(real, "sub")}
	if !slices.Equal(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestWindowsSteamRootsRegistryFirst(t *testing.T) {
	oldRegistry := readSteamRegistryRoots
	oldGetenv := getenv
	t.Cleanup(func() {
		readSteamRegistryRoots = oldRegistry
		getenv = oldGetenv
	})
	readSteamRegistryRoots = func() []string {
		return []string{`D:\Steam`, `D:\Steam`}
	}
	env := map[string]string{"ProgramFiles(x86)": `C:\Program Files (x86)`}
	getenv = func(k string) string { return env[k] }

	got := windowsSteamRoots()
	want := []string{`D:\Steam`, filepath.Join(`C:\Program Files (x86)`, "Steam")}
	if !slices.Equal(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestBridgeForGameWin64PrefersOwnLibrary(t *testing.T) {
	home, _, libA, libB := libraryPair(t)
	mkfile(t, filepath.Join(libA, gameRel(), "Spyro-Win64-Shipping.exe"))

	_, bridgeA := seedPrefix(t, libA, 0, 0)
	_, bridgeB := seedPrefix(t, libB, 5000, 0)
	logB := filepath.Join(bridgeB, "bridge.log")

	bridge, ready := bridgeForGameWin64(filepath.Join(libA, gameRel()))
	if !ready || bridge != bridgeB {
		t.Fatalf("newer evidence elsewhere must win: %s ready=%v", bridge, ready)
	}

	if err := os.Remove(logB); err != nil {
		t.Fatal(err)
	}
	bridge, ready = bridgeForGameWin64(filepath.Join(libA, gameRel()))
	if !ready || bridge != bridgeA {
		t.Fatalf("own library must be preferred: %s ready=%v", bridge, ready)
	}

	libC := filepath.Join(home, "LibraryC")
	bridge, ready = bridgeForGameWin64(filepath.Join(libC, gameRel()))
	want := newBridgeForDriveC(compatdataDriveC(libC))
	if ready || bridge != want {
		t.Fatalf("no prefix: got %s ready=%v, want %s ready=false", bridge, ready, want)
	}
}

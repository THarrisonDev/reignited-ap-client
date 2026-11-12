// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-11-09

package main

import (
	"os"
	"path/filepath"
	"runtime"
	"sort"
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

// bridgeDirName is the bridge folder's name on both sides of the path rules.
const bridgeDirName = "srtap_bridge"

// windowsLegacyBridge is the pre-2026 bridge folder on a native Windows
// install, kept as a fallback so an existing bridge is still found.
const windowsLegacyBridge = `C:\srtap_bridge`

// protonUserFallback is the account name Wine runs games as, and the user
// folder the bridge path assumes before a save has been written.
const protonUserFallback = "steamuser"

// getenv is os.Getenv behind a variable so tests can inject a Windows-like
// environment on Linux.
var getenv = os.Getenv

// Paths holds every filesystem location the launcher touches. All fields are
// resolved best-effort by defaultPaths() and are meant to be overridable from
// the UI, because Steam libraries can live on any drive and the config dir
// differs between a native Windows install and a Proton prefix on Linux.
//
//   - ConfigDir: where the mod reads config.txt and checks.json and where
//     srtap_checkd.exe lives (the mod's bridge folder).
//   - GameWin64: <game>/Falcon/Binaries/Win64 — where UE4SS and the Mods/ tree
//     live; used only by the setup verifier.
//   - PrefixReady: whether a usable Proton prefix (pfx/drive_c) backs
//     ConfigDir. Windows uses %LOCALAPPDATA%, which needs no prefix.
type Paths struct {
	ConfigDir   string
	GameWin64   string
	PrefixReady bool
}

// homeDir returns the user's home directory, preferring the environment so a
// test can point it at a temporary tree.
func homeDir() string {
	for _, key := range []string{"HOME", "USERPROFILE"} {
		if h := getenv(key); h != "" {
			return h
		}
	}
	h, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return h
}

// steamRoots returns the Steam install roots to search, $STEAM_ROOT first and
// then the host OS's known locations. Roots need not exist; libraries are
// filtered later.
func steamRoots() []string {
	var roots []string
	if r := getenv("STEAM_ROOT"); r != "" {
		roots = append(roots, r)
	}
	if runtime.GOOS == "windows" {
		roots = append(roots, windowsSteamRoots()...)
	} else {
		roots = append(roots, linuxSteamRoots()...)
	}
	return dedupePaths(roots)
}

// windowsSteamRoots returns the Windows roots: the registry entries, then the
// default installs under Program Files. A Linux test substitutes
// readSteamRegistryRoots to exercise this without Windows.
func windowsSteamRoots() []string {
	roots := append([]string(nil), readSteamRegistryRoots()...)
	for _, key := range []string{"ProgramFiles(x86)", "ProgramFiles"} {
		if pf := getenv(key); pf != "" {
			roots = append(roots, filepath.Join(pf, "Steam"))
		}
	}
	return dedupePaths(roots)
}

// linuxSteamRoots returns the Linux roots: the native install under
// XDG_DATA_HOME, ~/.steam/steam, and the Flatpak and Snap containers.
func linuxSteamRoots() []string {
	home := homeDir()
	data := getenv("XDG_DATA_HOME")
	if data == "" && home != "" {
		data = filepath.Join(home, ".local", "share")
	}
	var roots []string
	if data != "" {
		roots = append(roots, filepath.Join(data, "Steam"))
	}
	if home != "" {
		roots = append(roots,
			filepath.Join(home, ".steam", "steam"),
			filepath.Join(home, ".var", "app", "com.valvesoftware.Steam",
				".local", "share", "Steam"),
			filepath.Join(home, "snap", "steam", "common",
				".local", "share", "Steam"))
	}
	return roots
}

// steamRoot returns the first Steam install root for the host OS, or "" when
// no home directory is available to derive one from.
func steamRoot() string {
	roots := steamRoots()
	if len(roots) == 0 {
		return ""
	}
	return roots[0]
}

// dedupePaths keeps the first occurrence of each path, comparing after
// EvalSymlinks (or Clean when that fails) and, on Windows, ignoring case.
func dedupePaths(paths []string) []string {
	var out []string
	seen := map[string]bool{}
	for _, p := range paths {
		if p == "" {
			continue
		}
		key := canonicalPath(p)
		if runtime.GOOS == "windows" {
			key = strings.ToLower(key)
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, filepath.Clean(p))
	}
	return out
}

// canonicalPath returns the symlink-resolved form of p, falling back to Clean
// when the path cannot be resolved (it does not exist yet).
func canonicalPath(p string) string {
	p = filepath.Clean(p)
	if resolved, err := filepath.EvalSymlinks(p); err == nil {
		return resolved
	}
	return p
}

// localAppDataBridge returns the Windows bridge folder: the new location under
// %LOCALAPPDATA%, unless only the legacy C:\srtap_bridge holds bridge files. A
// missing LOCALAPPDATA falls back to the profile's AppData\Local, then to the
// legacy folder alone.
func localAppDataBridge() string {
	local := localAppDataDir()
	if local == "" {
		return windowsLegacyBridge
	}
	return bridgeSelection(filepath.Join(local, bridgeDirName), windowsLegacyBridge)
}

// localAppDataDir returns %LOCALAPPDATA%, falling back to the profile's
// AppData\Local, or "" when the environment names neither.
func localAppDataDir() string {
	if local := getenv("LOCALAPPDATA"); local != "" {
		return local
	}
	if profile := getenv("USERPROFILE"); profile != "" {
		return filepath.Join(profile, "AppData", "Local")
	}
	return ""
}

// newBridgeForConfig returns the new-location bridge folder a legacy bridge
// folder should migrate into, without applying the selection rule: the folder
// under %LOCALAPPDATA% on Windows, or the new folder in the same Proton prefix
// on Linux. It returns "" when the location cannot be derived.
func newBridgeForConfig(configDir string) string {
	if runtime.GOOS == "windows" {
		local := localAppDataDir()
		if local == "" {
			return ""
		}
		return filepath.Join(local, bridgeDirName)
	}
	if filepath.Base(configDir) != bridgeDirName {
		return ""
	}
	return newBridgeForDriveC(filepath.Dir(configDir))
}

// isLegacyBridge reports whether dir is a pre-2026 bridge folder: the fixed
// C:\srtap_bridge on Windows, or <pfx>/drive_c/srtap_bridge in a Proton prefix.
func isLegacyBridge(dir string) bool {
	if dir == "" {
		return false
	}
	if runtime.GOOS == "windows" {
		return samePath(dir, windowsLegacyBridge)
	}
	return filepath.Base(dir) == bridgeDirName &&
		filepath.Base(filepath.Dir(dir)) == "drive_c"
}

// newBridgeForDriveC returns the new bridge folder inside a Proton prefix's
// drive_c, under the user account the contract selects.
func newBridgeForDriveC(driveC string) string {
	return filepath.Join(driveC, "users", protonUser(driveC),
		"AppData", "Local", bridgeDirName)
}

// legacyBridgeForDriveC returns the pre-2026 bridge folder inside a Proton
// prefix's drive_c.
func legacyBridgeForDriveC(driveC string) string {
	return filepath.Join(driveC, bridgeDirName)
}

// protonUser returns the drive_c user folder whose bridge the mod uses. Steam
// creates and runs games as steamuser, so that account wins whenever it exists;
// a prefix without it falls back to the user with the newest save, then the
// first name in lexical order. With no user folders yet it reports steamuser
// without creating it.
func protonUser(driveC string) string {
	users := userDirs(driveC)
	for _, name := range users {
		if name == protonUserFallback {
			return name
		}
	}
	var best string
	var bestTime int64
	for _, name := range users {
		saveTime := newestSaveTime(filepath.Join(driveC, "users", name))
		if saveTime > bestTime {
			best, bestTime = name, saveTime
		}
	}
	if best != "" {
		return best
	}
	if len(users) > 0 {
		return users[0]
	}
	return protonUserFallback
}

// userDirs returns the sorted directory names under a prefix's drive_c/users.
func userDirs(driveC string) []string {
	entries, err := os.ReadDir(filepath.Join(driveC, "users"))
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out
}

// bridgeSelection applies the bridge folder rule: the first of [new, legacy]
// that holds bridge files, else new.
func bridgeSelection(newDir, legacyDir string) string {
	for _, dir := range []string{newDir, legacyDir} {
		if hasBridgeFiles(dir) {
			return dir
		}
	}
	return newDir
}

// hasBridgeFiles reports whether dir contains config.txt or srtap_checkd.exe.
func hasBridgeFiles(dir string) bool {
	for _, name := range []string{"config.txt", "srtap_checkd.exe"} {
		if fileExists(filepath.Join(dir, name)) {
			return true
		}
	}
	return false
}

// gameWin64 returns the default Falcon/Binaries/Win64 directory under the
// standard Steam library, used as a fallback when game detection fails.
func gameWin64() string {
	return filepath.Join(steamRoot(), gameRel())
}

// compatdataDriveC is the drive_c of the game's Proton compatdata prefix under
// a given Steam library root. Steam creates the prefix in the same library
// that holds the game, so this must be derived per-library, not from the
// default root.
func compatdataDriveC(lib string) string {
	return filepath.Join(lib, "steamapps", "compatdata", appID, "pfx", "drive_c")
}

// gameRel is the game's Win64 path relative to a Steam library root.
func gameRel() string {
	return filepath.Join("steamapps", "common", "Spyro Reignited Trilogy",
		"Falcon", "Binaries", "Win64")
}

// appmanifestRel is Steam's install manifest for the game, relative to a
// library root. Its presence marks the library Steam considers installed.
func appmanifestRel() string {
	return filepath.Join("steamapps", "appmanifest_"+appID+".acf")
}

// librariesFor returns each root plus the libraries its libraryfolders.vdf
// lists, deduped and limited to existing directories.
func librariesFor(roots []string) []string {
	libs := append([]string(nil), roots...)
	for _, root := range roots {
		data, err := os.ReadFile(filepath.Join(root, "steamapps", "libraryfolders.vdf"))
		if err != nil {
			continue
		}
		libs = append(libs, parseLibraryFolders(data)...)
	}
	var out []string
	for _, lib := range dedupePaths(libs) {
		if dirExists(lib) {
			out = append(out, lib)
		}
	}
	return out
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
// library that has it, along with that library root. Libraries holding the
// install manifest win over libraries with only the game folder; within each
// group input order is kept. ok is false when no library contains the game.
func findGameWin64(libs []string) (win64, lib string, ok bool) {
	var fallbackWin64, fallbackLib string
	for _, candidate := range libs {
		p := filepath.Join(candidate, gameRel())
		if !dirExists(p) {
			continue
		}
		if fileExists(filepath.Join(candidate, appmanifestRel())) {
			return p, candidate, true
		}
		if fallbackWin64 == "" {
			fallbackWin64, fallbackLib = p, candidate
		}
	}
	if fallbackWin64 != "" {
		return fallbackWin64, fallbackLib, true
	}
	return "", "", false
}

// prefixInfo describes one Proton prefix found in a Steam library.
type prefixInfo struct {
	DriveC       string
	NewBridge    string
	LegacyBridge string
	Bridge       string
	BridgeLog    string
	LogTime      int64
	SaveTime     int64
	InGameLib    bool
}

// prefixDir returns the pfx directory the prefix was found under.
func (p prefixInfo) prefixDir() string {
	return filepath.Dir(p.DriveC)
}

// discovery is the evidence gathered from the host: the Steam roots and
// libraries searched, the game found there, and every usable Proton prefix.
type discovery struct {
	Roots     []string
	Libraries []string
	GameWin64 string
	GameLib   string
	Prefix    string
	Prefixes  []prefixInfo
	Note      string
}

// discover resolves Steam, the game and the Proton prefixes from the
// filesystem without creating anything. Prefix is empty when no usable prefix
// exists, and Note then carries the deferred-install guidance.
func discover() discovery {
	d := discovery{Roots: steamRoots()}
	d.Libraries = librariesFor(d.Roots)
	if win64, lib, ok := findGameWin64(d.Libraries); ok {
		d.GameWin64, d.GameLib = win64, lib
	}
	d.Prefixes = prefixesFor(d.Libraries, d.GameLib)
	if p := selectPrefix(d.Prefixes); p != nil {
		d.Prefix = p.prefixDir()
	} else {
		d.Note = "Launch the game once through Steam, then click Install again."
	}
	return d
}

// prefixesFor returns a prefixInfo for each library whose compatdata prefix has
// a drive_c, in library order.
func prefixesFor(libs []string, gameLib string) []prefixInfo {
	var out []prefixInfo
	for _, lib := range libs {
		if p, ok := prefixAt(lib, gameLib); ok {
			out = append(out, p)
		}
	}
	return out
}

// prefixAt describes the prefix under one library, ok=false when the library
// has no usable pfx/drive_c.
func prefixAt(lib, gameLib string) (prefixInfo, bool) {
	if lib == "" {
		return prefixInfo{}, false
	}
	driveC := compatdataDriveC(lib)
	if !dirExists(driveC) {
		return prefixInfo{}, false
	}
	p := prefixInfo{
		DriveC:       driveC,
		NewBridge:    newBridgeForDriveC(driveC),
		LegacyBridge: legacyBridgeForDriveC(driveC),
		InGameLib:    samePath(lib, gameLib),
	}
	p.Bridge = bridgeSelection(p.NewBridge, p.LegacyBridge)
	p.BridgeLog = filepath.Join(p.Bridge, "bridge.log")
	p.LogTime = fileModTime(p.BridgeLog)
	p.SaveTime = newestPrefixSaveTime(driveC)
	return p, true
}

// selectPrefix applies the contract's order: newest bridge log, then newest
// save, then the game library's prefix, then the only prefix.
func selectPrefix(prefixes []prefixInfo) *prefixInfo {
	if best := bestEvidencePrefix(prefixes); best != nil {
		return best
	}
	for i := range prefixes {
		if prefixes[i].InGameLib {
			return &prefixes[i]
		}
	}
	if len(prefixes) == 1 {
		return &prefixes[0]
	}
	return nil
}

// bestEvidencePrefix returns the prefix with the strongest evidence, or nil
// when no prefix has a bridge log or a save.
func bestEvidencePrefix(prefixes []prefixInfo) *prefixInfo {
	var best *prefixInfo
	for i := range prefixes {
		p := &prefixes[i]
		if p.LogTime == 0 && p.SaveTime == 0 {
			continue
		}
		if best == nil || evidenceNewer(*p, *best) {
			best = p
		}
	}
	return best
}

// evidenceNewer reports whether a's evidence is newer than b's, a bridge log
// outranking a save.
func evidenceNewer(a, b prefixInfo) bool {
	if a.LogTime != b.LogTime {
		return a.LogTime > b.LogTime
	}
	return a.SaveTime > b.SaveTime
}

// fileModTime returns path's modification time in Unix seconds, or 0 when the
// file is absent.
func fileModTime(path string) int64 {
	st, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return st.ModTime().Unix()
}

// newestPrefixSaveTime returns the newest FalconSave.*.sav time across a
// prefix's user folders, or 0 when it holds no saves.
func newestPrefixSaveTime(driveC string) int64 {
	var newest int64
	for _, user := range userDirs(driveC) {
		saveTime := newestSaveTime(filepath.Join(driveC, "users", user))
		if saveTime > newest {
			newest = saveTime
		}
	}
	return newest
}

// newestSaveTime returns the newest FalconSave.*.sav time under a drive_c user
// folder, or 0 when it holds no saves.
func newestSaveTime(userDir string) int64 {
	pattern := filepath.Join(userDir, "AppData", "Local", "Falcon", "Saved",
		"SaveGames", "FalconSave.*.sav")
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return 0
	}
	var newest int64
	for _, match := range matches {
		if t := fileModTime(match); t > newest {
			newest = t
		}
	}
	return newest
}

// samePath reports whether two paths name the same location, tolerating case
// differences only where the filesystem does (a user-typed Windows path).
func samePath(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	a, b = filepath.Clean(a), filepath.Clean(b)
	if runtime.GOOS == "windows" {
		return strings.EqualFold(a, b)
	}
	return a == b
}

// fallbackLibrary returns the first discovered library, or the first root when
// no library exists — the best guess for where a prefix would be created.
func fallbackLibrary(d discovery) string {
	if n := len(d.Libraries); n > 0 {
		return d.Libraries[0]
	}
	if n := len(d.Roots); n > 0 {
		return d.Roots[0]
	}
	return ""
}

// gameOrGuess returns the discovered game folder, or the default-root guess.
func gameOrGuess(d discovery) string {
	if d.GameWin64 != "" {
		return d.GameWin64
	}
	return gameWin64()
}

// defaultPaths resolves the best-guess locations for the host OS by running
// discovery, falling back to the default Steam root when nothing is installed.
func defaultPaths() Paths {
	if steamRoot() == "" {
		return Paths{}
	}
	d := discover()
	game := gameOrGuess(d)
	if runtime.GOOS == "windows" {
		return Paths{ConfigDir: localAppDataBridge(), GameWin64: game, PrefixReady: true}
	}
	if d.Prefix != "" {
		for _, p := range d.Prefixes {
			if samePath(p.prefixDir(), d.Prefix) {
				return Paths{ConfigDir: p.Bridge, GameWin64: game, PrefixReady: true}
			}
		}
	}
	lib := d.GameLib
	if lib == "" {
		lib = fallbackLibrary(d)
	}
	return Paths{ConfigDir: newBridgeForDriveC(compatdataDriveC(lib)), GameWin64: game}
}

// bridgeForGameWin64 maps an override game folder back to its Steam library and
// returns the bridge folder for it plus whether a usable prefix backs it.
//
// On Windows the bridge is %LOCALAPPDATA%\srtap_bridge and needs no prefix. On
// Linux the mod and its saves live in the prefix of the library that runs the
// game, so the given library's own prefix is preferred; a prefix from another
// library only wins when it carries strictly newer evidence (a later
// bridge.log, then a later save), because that is where the game actually ran.
func bridgeForGameWin64(win64 string) (bridge string, prefixReady bool) {
	if runtime.GOOS == "windows" {
		return localAppDataBridge(), true
	}
	d := discover()
	lib := libraryForWin64(win64)
	if lib == "" {
		lib = d.GameLib
	}
	if p := choosePrefix(d, lib); p != nil {
		return p.Bridge, true
	}
	if lib == "" {
		lib = fallbackLibrary(d)
	}
	if lib == "" {
		return "", false
	}
	return newBridgeForDriveC(compatdataDriveC(lib)), false
}

// choosePrefix returns the prefix that should back lib: the library's own
// prefix when it has one, unless another prefix carries newer evidence. A
// library outside the discovered set is still considered, so an overridden
// game folder in an unlisted library keeps its prefix.
func choosePrefix(d discovery, lib string) *prefixInfo {
	prefixes := append([]prefixInfo(nil), d.Prefixes...)
	chosen := ownPrefix(prefixes, lib)
	if chosen == nil {
		if p, ok := prefixAt(lib, d.GameLib); ok {
			prefixes = append(prefixes, p)
			chosen = &prefixes[len(prefixes)-1]
		}
	}
	if other := bestEvidencePrefix(prefixes); other != nil {
		if chosen == nil || evidenceNewer(*other, *chosen) {
			chosen = other
		}
	}
	return chosen
}

// ownPrefix returns the prefix belonging to lib, or nil when lib has none.
func ownPrefix(prefixes []prefixInfo, lib string) *prefixInfo {
	if lib == "" {
		return nil
	}
	for i := range prefixes {
		if samePath(prefixes[i].DriveC, compatdataDriveC(lib)) {
			return &prefixes[i]
		}
	}
	return nil
}

// libraryForWin64 returns the Steam library root that a game's Win64 folder
// sits under, or "" when the path does not follow the steamapps layout.
func libraryForWin64(win64 string) string {
	if win64 == "" {
		return ""
	}
	dir := filepath.Clean(win64)
	for {
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
		if strings.EqualFold(filepath.Base(dir), "steamapps") {
			return filepath.Dir(dir)
		}
	}
}
